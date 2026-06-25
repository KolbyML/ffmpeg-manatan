#!/usr/bin/env bash
set -euo pipefail

FFMPEG_BIN="${1:-${FFMPEG_BIN:-}}"
if [ -z "$FFMPEG_BIN" ]; then
    echo "usage: $0 /path/to/ffmpeg" >&2
    exit 2
fi

if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1; then
    PYTHON=python
else
    echo "python is required for the sentence audio DASH smoke test" >&2
    exit 2
fi

SMOKE_DIR="${TMPDIR:-/tmp}/ffmpeg-manatan-dash-smoke-$$"
mkdir -p "$SMOKE_DIR"
trap 'rm -rf "$SMOKE_DIR"' EXIT

INPUT_WAV="$SMOKE_DIR/input.wav"
MANIFEST="$SMOKE_DIR/manifest.mpd"
CLIP_WAV="$SMOKE_DIR/clip.wav"

"$PYTHON" - "$INPUT_WAV" <<'PY'
import math
import struct
import sys
import wave

path = sys.argv[1]
rate = 44100
seconds = 4

with wave.open(path, "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(rate)
    for sample in range(rate * seconds):
        value = int(12000 * math.sin(2 * math.pi * 440 * sample / rate))
        wav.writeframesraw(struct.pack("<h", value))
PY

"$FFMPEG_BIN" -hide_banner -nostdin -loglevel error -y \
    -i "$INPUT_WAV" \
    -c:a aac \
    -f dash \
    -seg_duration 1 \
    -use_template 1 \
    -use_timeline 1 \
    "$MANIFEST"

test -s "$MANIFEST"

"$FFMPEG_BIN" -hide_banner -nostdin -loglevel error \
    -protocol_whitelist file,http,https,tcp,tls,crypto,data,httpproxy \
    -ss 0.25 \
    -i "$MANIFEST" \
    -t 1.25 \
    -map 0:a:0 \
    -vn \
    -acodec pcm_s16le \
    -f wav \
    "$CLIP_WAV"

"$PYTHON" - "$CLIP_WAV" <<'PY'
from pathlib import Path
import sys

clip = Path(sys.argv[1]).read_bytes()
if not clip.startswith(b"RIFF"):
    raise SystemExit(f"expected WAV RIFF output, got {clip[:16]!r}")
if len(clip) <= 44:
    raise SystemExit(f"expected WAV payload larger than header, got {len(clip)} bytes")
print(f"sentence audio DASH smoke passed: {len(clip)} bytes")
PY
