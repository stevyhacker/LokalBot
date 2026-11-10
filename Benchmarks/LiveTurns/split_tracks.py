#!/usr/bin/env python3
"""Split a sample meeting's mixed recording into one track per speaker, the way a call is
recorded (microphone and call audio apart). Each moment goes to whoever is speaking, changing
hands at the middle of the pause between two speakers; the other track is digital silence there.
Needs ffmpeg and numpy.

Usage: split_tracks.py <recording.m4a> <reference.json> <output prefix>
Writes <prefix>.<speaker>.wav for each speaker, in the order they first speak.
"""
import json
import subprocess
import sys
import wave

import numpy as np

RATE = 16000


def main():
    recording, reference, prefix = sys.argv[1:4]
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", recording, "-ac", "1", "-ar", str(RATE), "-f", "f32le", "-"],
        check=True, capture_output=True).stdout
    samples = np.frombuffer(raw, dtype="<f4")
    turns = json.load(open(reference))["turns"]
    speakers = []
    for turn in turns:
        if turn["speaker"] not in speakers:
            speakers.append(turn["speaker"])
    owner = np.zeros(len(samples), dtype=np.int8)
    cursor = 0
    for current, following in zip(turns, turns[1:] + [None]):
        end = len(samples) if following is None else int(RATE * (current["end"] + following["start"]) / 2)
        owner[cursor:end] = speakers.index(current["speaker"])
        cursor = end
    for index, speaker in enumerate(speakers):
        track = np.where(owner == index, samples, 0)
        pcm = (np.clip(track, -1, 1) * 32767).astype("<i2")
        with wave.open(f"{prefix}.{speaker}.wav", "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(pcm.tobytes())
        share = round(float((owner == index).mean()) * 100)
        print(f"{prefix}.{speaker}.wav: {len(pcm) / RATE:.1f} s, this speaker's {share}% of the time")


if __name__ == "__main__":
    main()
