#!/usr/bin/env python3
"""Seed synthetic audio in Files on an explicitly selected, booted test simulator."""
import argparse
from pathlib import Path
import subprocess
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("simulator_id", help="UDID of a disposable simulator without a music server")
args = parser.parse_args()

groups = subprocess.check_output(
    ["rtk", "proxy", "xcrun", "simctl", "get_app_container", args.simulator_id, "com.apple.DocumentsApp", "groups"],
    text=True,
)
roots = dict(line.split("\t", 1) for line in groups.splitlines())
root = Path(roots["group.com.apple.FileProvider.LocalStorage"]) / "File Provider Storage" / "Minidisc Test Music"
root.mkdir(exist_ok=True)
for title in ["Local First", "Local Second", "Local Third"]:
    # Keep this isolated fixture repeatable without overwriting files already present.
    target = root / f"{title}.wav"
    if target.exists():
        continue
    with wave.open(str(target), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(bytes(8000 * 2 * 60))
print(f"Local music fixture ready: {root}")
