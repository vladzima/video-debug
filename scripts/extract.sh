#!/usr/bin/env bash
# extract.sh — video-debug skill extractor
#
# Usage:
#   bash extract.sh <video-path> [--strategy=a|b|c|d] [--range=START-END]
#
# Exit codes:
#   0  success — last stdout line is the absolute path to timeline.md
#   2  video file not found
#   3  unsupported container (allowed: mp4 mov webm mkv gif)
#   4  ffmpeg install missing or declined (from ensure-ffmpeg.sh)
#   10 large video — JSON gate; agent should pick a strategy and re-run

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ensure-ffmpeg.sh
. "$SCRIPT_DIR/ensure-ffmpeg.sh"

VIDEO=""
STRATEGY=""
RANGE=""

for arg in "$@"; do
    case "$arg" in
        --strategy=*) STRATEGY="${arg#--strategy=}" ;;
        --range=*)    RANGE="${arg#--range=}" ;;
        --*)
            echo "video-debug: unknown flag: $arg" >&2
            exit 1
            ;;
        *)
            if [ -z "$VIDEO" ]; then
                VIDEO="$arg"
            else
                echo "video-debug: unexpected extra argument: $arg" >&2
                exit 1
            fi
            ;;
    esac
done

if [ -z "$VIDEO" ]; then
    echo "video-debug: missing video path." >&2
    echo "Usage: bash extract.sh <video-path> [--strategy=a|b|c|d] [--range=START-END]" >&2
    exit 1
fi

if [ ! -f "$VIDEO" ]; then
    echo "video-debug: file not found: $VIDEO" >&2
    exit 2
fi

# Normalize to absolute path.
if command -v realpath >/dev/null 2>&1; then
    VIDEO="$(realpath "$VIDEO")"
else
    VIDEO="$(cd "$(dirname "$VIDEO")" && pwd)/$(basename "$VIDEO")"
fi

EXT="${VIDEO##*.}"
case "$(echo "$EXT" | tr '[:upper:]' '[:lower:]')" in
    mp4|mov|webm|mkv|gif) ;;
    *)
        echo "video-debug: unsupported extension '.$EXT'. Allowed: mp4 mov webm mkv gif" >&2
        exit 3
        ;;
esac

ensure_ffmpeg

# --- Phase 1: probe (fast: ffprobe only) ---
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" 2>/dev/null | head -n1)
RESOLUTION=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=s=x:p=0 "$VIDEO" 2>/dev/null | head -n1)

if [ -z "$DURATION" ]; then
    echo "video-debug: could not probe video duration. Is the file a valid video?" >&2
    exit 3
fi

# Round duration to one decimal for the JSON payload.
DURATION_FMT=$(awk -v d="$DURATION" 'BEGIN { printf "%.1f", d }')

# --- Phase 2: large-video gate ---
LARGE_THRESHOLD_SEC=60
IS_LARGE=$(awk -v d="$DURATION" -v t="$LARGE_THRESHOLD_SEC" \
    'BEGIN { print (d > t) ? 1 : 0 }')

if [ "$IS_LARGE" = "1" ] && [ -z "$STRATEGY" ]; then
    printf '{"large":true,"duration_seconds":%s,"resolution":"%s"}\n' \
        "$DURATION_FMT" "${RESOLUTION:-unknown}"
    exit 10
fi

# --- Phase 3: extract ---

# Per-strategy parameters.
THRESHOLD="0.03"
case "$STRATEGY" in
    ""|a|b|c) THRESHOLD="0.03" ;;
    d)        THRESHOLD="0.08" ;;
    *)
        echo "video-debug: unknown strategy: $STRATEGY (expected a, b, c, or d)" >&2
        exit 1
        ;;
esac

WIDTH="${VIDEO_DEBUG_WIDTH:-960}"

# Output directory: /tmp/video-debug-<8-char-hash>-<unix-ts>/
hash_path() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 1 | cut -c1-8
    elif command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha1sum | cut -c1-8
    else
        printf '%s' "$1" | openssl sha1 2>/dev/null | awk '{print substr($NF,1,8)}'
    fi
}

PATH_HASH=$(hash_path "$VIDEO")
TS=$(date +%s)
OUT_DIR="${TMPDIR:-/tmp}/video-debug-${PATH_HASH}-${TS}"
mkdir -p "$OUT_DIR"

# Build the ffmpeg input options (trim if --range was passed).
INPUT_OPTS=()
if [ -n "$RANGE" ]; then
    case "$RANGE" in
        *-*)
            R_START="${RANGE%%-*}"
            R_END="${RANGE#*-}"
            INPUT_OPTS=(-ss "$R_START" -to "$R_END")
            ;;
        *)
            echo "video-debug: --range must be START-END (e.g. 10-25 or 00:10-00:25)" >&2
            exit 1
            ;;
    esac
fi

# Run scene detection + downscale. Capture showinfo lines to parse timestamps.
LOG_FILE="$OUT_DIR/ffmpeg.log"

# Note: ffmpeg may exit non-zero when the scene filter selects zero frames
# (genuinely static video). That's not a real failure — we fall through to
# the static-video fallback below, which catches both the "zero frames" case
# and any real ffmpeg crash.
ffmpeg -nostdin -y -hide_banner -loglevel info \
    "${INPUT_OPTS[@]}" \
    -i "$VIDEO" \
    -vf "select='gt(scene,${THRESHOLD})',scale=${WIDTH}:-2,showinfo" \
    -vsync vfr \
    -q:v 4 \
    "$OUT_DIR/frame_%03d.jpg" \
    >"$LOG_FILE" 2>&1 || true

# Parse showinfo lines. Each looks like:
#   [Parsed_showinfo_2 @ 0x...] n:0 pts:... pts_time:1.234 ...
TS_FILE="$OUT_DIR/timestamps.txt"
grep -E "Parsed_showinfo.* pts_time:" "$LOG_FILE" \
    | sed -E 's/.* pts_time:([0-9.]+).*/\1/' > "$TS_FILE" || true

FRAME_COUNT=$(find "$OUT_DIR" -maxdepth 1 -name 'frame_*.jpg' | wc -l | tr -d ' ')

# --- Fallback: video (or range) appears static (no scene changes detected) ---
if [ "$FRAME_COUNT" = "0" ]; then
    if [ -n "$RANGE" ]; then
        # Midpoint of the user-specified range.
        MIDPOINT=$(awk -v s="$R_START" -v e="$R_END" 'BEGIN {
            # Accept either MM:SS or raw seconds.
            split(s, a, ":"); split(e, b, ":");
            ss = (length(a) > 1) ? a[1]*60 + a[2] : s;
            ee = (length(b) > 1) ? b[1]*60 + b[2] : e;
            printf "%.2f", (ss + ee) / 2
        }')
    else
        MIDPOINT=$(awk -v d="$DURATION" 'BEGIN { printf "%.2f", d/2 }')
    fi
    ffmpeg -nostdin -y -hide_banner -loglevel error \
        -ss "$MIDPOINT" \
        -i "$VIDEO" \
        -frames:v 1 \
        -vf "scale=${WIDTH}:-2" \
        -q:v 4 \
        "$OUT_DIR/frame_001.jpg" || {
            echo "video-debug: failed to extract fallback frame." >&2
            exit 5
        }
    echo "$MIDPOINT" > "$TS_FILE"
    FRAME_COUNT=1
    STATIC_VIDEO=1
else
    STATIC_VIDEO=0
fi

# --- Strategy b: sample down to ~30 evenly-distributed frames ---
TARGET_FRAMES=30
if [ "$STRATEGY" = "b" ] && [ "$FRAME_COUNT" -gt "$TARGET_FRAMES" ]; then
    # Build a list of indices (1-based) to keep, evenly spaced.
    KEEP_LIST=$(awk -v n="$FRAME_COUNT" -v t="$TARGET_FRAMES" '
        BEGIN {
            for (i = 0; i < t; i++) {
                idx = int(i * n / t) + 1
                print idx
            }
        }
    ' | sort -u)

    NEW_TS_FILE="$OUT_DIR/timestamps.new.txt"
    : > "$NEW_TS_FILE"
    NEW_IDX=1

    for i in $(seq 1 "$FRAME_COUNT"); do
        FRAME_FILE=$(printf "$OUT_DIR/frame_%03d.jpg" "$i")
        if echo "$KEEP_LIST" | grep -qx "$i"; then
            NEW_FILE=$(printf "$OUT_DIR/keep_%03d.jpg" "$NEW_IDX")
            mv "$FRAME_FILE" "$NEW_FILE"
            sed -n "${i}p" "$TS_FILE" >> "$NEW_TS_FILE"
            NEW_IDX=$((NEW_IDX + 1))
        else
            rm -f "$FRAME_FILE"
        fi
    done

    # Rename keep_*.jpg back to frame_*.jpg.
    for f in "$OUT_DIR"/keep_*.jpg; do
        [ -f "$f" ] || continue
        mv "$f" "${f/keep_/frame_}"
    done

    mv "$NEW_TS_FILE" "$TS_FILE"
    FRAME_COUNT=$((NEW_IDX - 1))
fi

# --- Build timeline.md ---
TIMELINE="$OUT_DIR/timeline.md"
VIDEO_BASENAME=$(basename "$VIDEO")

{
    echo "# Video Analysis Timeline: $VIDEO_BASENAME"
    echo ""
    echo "- Source: \`$VIDEO\`"
    echo "- Duration: ${DURATION_FMT}s"
    echo "- Resolution: ${RESOLUTION:-unknown}"
    echo "- Frames extracted: $FRAME_COUNT"
    if [ -n "$STRATEGY" ]; then
        echo "- Strategy: $STRATEGY"
    fi
    if [ -n "$RANGE" ]; then
        echo "- Range: $RANGE"
    fi
    if [ "$STATIC_VIDEO" = "1" ]; then
        echo ""
        echo "> No scene changes detected. Showing a single representative frame from the video's midpoint."
    fi
    echo ""
    echo "## Frames"
    echo ""

    i=1
    while IFS= read -r ts; do
        [ -z "$ts" ] && continue
        FRAME_FILE=$(printf "frame_%03d.jpg" "$i")
        MMSS=$(awk -v t="$ts" 'BEGIN { m=int(t/60); s=t-m*60; printf "%02d:%05.2f", m, s }')
        echo "- **${MMSS}** — \`${FRAME_FILE}\`"
        i=$((i + 1))
    done < "$TS_FILE"
} > "$TIMELINE"

# Final stdout: the absolute timeline path.
echo "$TIMELINE"
exit 0
