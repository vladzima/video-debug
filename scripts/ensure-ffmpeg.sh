#!/usr/bin/env bash
# ensure-ffmpeg.sh — sourced by extract.sh
#
# Verifies ffmpeg + ffprobe are available. If missing, detects the platform's
# package manager and asks the user (via stderr) whether to install. Never runs
# sudo silently. Exits non-zero with exit code 4 on decline or failure.

ensure_ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
        return 0
    fi

    echo "video-debug: ffmpeg is required but not installed." >&2

    local install_cmd=""
    local pm_label=""

    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                install_cmd="brew install ffmpeg"
                pm_label="Homebrew"
            fi
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                install_cmd="sudo apt-get update && sudo apt-get install -y ffmpeg"
                pm_label="apt"
            elif command -v dnf >/dev/null 2>&1; then
                install_cmd="sudo dnf install -y ffmpeg"
                pm_label="dnf"
            elif command -v pacman >/dev/null 2>&1; then
                install_cmd="sudo pacman -S --noconfirm ffmpeg"
                pm_label="pacman"
            elif command -v apk >/dev/null 2>&1; then
                install_cmd="sudo apk add ffmpeg"
                pm_label="apk"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            if command -v winget >/dev/null 2>&1; then
                install_cmd="winget install --id Gyan.FFmpeg -e"
                pm_label="winget"
            elif command -v choco >/dev/null 2>&1; then
                install_cmd="choco install -y ffmpeg"
                pm_label="Chocolatey"
            fi
            ;;
    esac

    if [ -z "$install_cmd" ]; then
        echo "video-debug: no known package manager detected for $(uname -s)." >&2
        echo "video-debug: install ffmpeg manually from https://ffmpeg.org/download.html and re-run." >&2
        exit 4
    fi

    echo "video-debug: Install ffmpeg via $pm_label now?" >&2
    echo "video-debug:   $install_cmd" >&2
    printf "video-debug: Proceed? [y/N] " >&2

    local reply
    if ! IFS= read -r reply </dev/tty 2>/dev/null; then
        IFS= read -r reply || reply=""
    fi

    case "${reply:-}" in
        y|Y|yes|YES)
            ;;
        *)
            echo "video-debug: install declined. See https://ffmpeg.org/download.html for manual setup." >&2
            exit 4
            ;;
    esac

    if ! eval "$install_cmd" >&2; then
        echo "video-debug: install failed. Try running '$install_cmd' manually." >&2
        exit 4
    fi

    if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
        echo "video-debug: install completed but ffmpeg/ffprobe still not on PATH. Restart your shell and retry." >&2
        exit 4
    fi

    echo "video-debug: ffmpeg installed successfully." >&2
}
