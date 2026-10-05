#!/usr/bin/env python3
"""Regenerate six-second synthetic tones for the native AudioStreaming decoder tests.

Requires ffmpeg. These files contain generated signals, not recordings or music.
"""
from pathlib import Path
import subprocess

destination = Path(__file__).resolve().parents[2] / "MinidiscTests" / "AudioFixtures"
destination.mkdir(parents=True, exist_ok=True)
formats = [
    ("stream-cbr.mp3", 44100, ["-c:a", "libmp3lame", "-b:a", "128k"]),
    ("stream-vbr.mp3", 44100, ["-c:a", "libmp3lame", "-q:a", "4"]),
    ("stream-aac.m4a", 48000, ["-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart"]),
    ("stream-flac44.flac", 44100, ["-c:a", "flac"]),
    ("stream-flac96.flac", 96000, ["-c:a", "flac"]),
]
for filename, rate, codec in formats:
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"sine=frequency=440:sample_rate={rate}:duration=6",
        "-ac", "2", "-map_metadata", "-1", *codec, str(destination / filename),
    ], check=True)
    print(f"{filename}: {(destination / filename).stat().st_size} bytes")
