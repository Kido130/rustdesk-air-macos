#!/usr/bin/env python3
"""Inspect a passive Air input capture without printing event or key payloads."""

import json
import struct
import sys
from pathlib import Path


def inspect(path: Path) -> dict:
    blob = path.read_bytes()
    if len(blob) < 48 or blob[:8] != b"RDAICAP1":
        raise ValueError("not an Air native input capture")
    gesture_size, raw_size, events, frames, contact_count, ns_touches = struct.unpack_from(
        "<IIQQQQ", blob, 8
    )
    if gesture_size > 65536 or raw_size > 336 or len(blob) != 48 + gesture_size + raw_size:
        raise ValueError("invalid capture lengths")
    gesture = blob[48 : 48 + gesture_size]
    raw = blob[48 + gesture_size :]
    result = {
        "gesture_events": events,
        "latest_gesture_bytes": gesture_size,
        "raw_frames": frames,
        "raw_contact_samples": contact_count,
        "nsevent_touch_samples": ns_touches,
        "gesture_hid_field_offsets": [
            i for i in range(2, len(gesture) - 1) if gesture[i : i + 2] == b"\x10\x6d"
        ],
    }
    if raw:
        if len(raw) < 16 or raw[:5] != b"RDAF\x01" or raw[6:8] != b"\0\0":
            raise ValueError("invalid raw frame header")
        count = raw[5]
        if count > 16 or len(raw) != 16 + 20 * count:
            raise ValueError("invalid raw frame length")
        result["latest_raw_frame"] = {
            "device_id": struct.unpack_from("<Q", raw, 8)[0],
            "contacts": [
                dict(zip(("id", "state", "x", "y", "pressure"), struct.unpack_from("<IIfff", raw, 16 + 20 * i)))
                for i in range(count)
            ],
        }
    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: inspect_capture.py CAPTURE.bin")
    try:
        print(json.dumps(inspect(Path(sys.argv[1])), indent=2))
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
