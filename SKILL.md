---
name: video-debug
description: Use when the user references a video, screencast, screen recording, or any path ending in .mp4, .mov, .webm, .mkv, or .gif — especially when asking to debug a UI bug, visual glitch, or reproduction recording. Extracts key frames via ffmpeg scene detection so the agent can visually inspect what went wrong.
allowed-tools:
  - Bash
  - Read
---

# Video Debug Protocol

When the user provides a path to a video file (`.mp4`, `.mov`, `.webm`, `.mkv`, or `.gif`), follow this protocol.

## Step 1: Extract frames

Run the extractor against the video path the user gave you:

```bash
bash scripts/extract.sh <video-path>
```

The script will:

1. Verify `ffmpeg` is installed, and if not, offer to install it (you may need to relay a `[y/N]` prompt to the user).
2. Probe the video's duration, resolution, and estimated scene-change count.
3. Decide whether the video is "small enough to process directly" or "large enough to need a strategy."

## Step 2: Handle large videos

If `extract.sh` exits with code **10**, the video is large (currently: duration > 60 seconds). The script will have printed a single JSON line to stdout with this shape:

```json
{"large": true, "duration_seconds": 248.5, "resolution": "1920x1080"}
```

Surface these numbers to the user and present them with these four options:

- **a)** Process all frames as-is (may use many tokens).
- **b)** Sample down to ~30 evenly-distributed frames.
- **c)** Focus on a specific time range — ask the user for `start–end` in `MM:SS` or seconds.
- **d)** Use a stricter scene threshold (fewer, more distinct frames).

Then re-run with the chosen strategy:

```bash
bash scripts/extract.sh <video-path> --strategy=<a|b|c|d> [--range=START-END]
```

For option **c**, pass `--range=MM:SS-MM:SS` (or `--range=12-30` for raw seconds).

## Step 3: Read the timeline

When `extract.sh` exits with code **0**, its **last stdout line** is the absolute path to a `timeline.md` file.

1. Read `timeline.md`. It lists each extracted frame with its timestamp in the source video.
2. Read each frame `.jpg` in order. Your `Read` tool natively handles images — open them visually.

## Step 4: Correlate with the codebase

- **For UI bugs:** identify which component is on screen at the moment of the glitch. Use `Glob` and `Grep` to locate that component in the user's project. Inspect the relevant CSS, layout, state hooks, or animation logic.
- **For terminal/console errors:** read the error text directly off the frame. Search the codebase for the stack-trace symbols.
- **For state bugs:** look at what differs between consecutive frames. The change between frame N and frame N+1 is usually the bug.

## Step 5: Propose a fix

Always cite the specific frame timestamps that evidenced the problem. For example:

> At **00:04.12** (frame_003.jpg) the sidebar's `transform` jumps from `translateX(0)` to `translateX(-100%)` instantly instead of animating. The issue is the missing `transition-transform` utility on `<Sidebar>` in `components/Sidebar.tsx`.

## Triggering this skill

Trigger automatically whenever the user references a video file path in the contexts described in the frontmatter. The user can also invoke this skill explicitly with:

```
/video-debug <video-path>
```

Treat the explicit invocation identically.

## What this skill does NOT do

- **No audio transcription.** This is a purely visual debugging tool. If the user expects voice-narrated analysis, tell them this skill doesn't transcribe audio.
- **No OCR pre-pass.** Read text directly from frames using your multimodal `Read` capability.
- **No frame editing, annotation, or re-encoding.** Frames are read-only.

## Failure modes to handle

- **Video file doesn't exist** → `extract.sh` exits 2. Ask the user to re-check the path.
- **Unsupported container** → `extract.sh` exits 3. Tell the user which extensions are supported.
- **ffmpeg install declined by user** → `extract.sh` exits 4. Point the user at `https://ffmpeg.org/download.html`.
- **No scene changes detected** → `extract.sh` will emit a single representative frame from the middle of the video and note this in `timeline.md`. Tell the user the video looked static.
