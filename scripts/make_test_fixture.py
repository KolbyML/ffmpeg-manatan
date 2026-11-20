#!/usr/bin/env python3
"""Use a development FFmpeg to generate synthetic input; it is not redistributed."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
destination = root / '.build/validation-fixtures/input.mp4'
destination.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=160x96:rate=24',
                '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100', '-t', '4', '-c:v', 'libx264',
                '-pix_fmt', 'yuv420p', '-c:a', 'aac', str(destination)], check=True)
print(destination)
