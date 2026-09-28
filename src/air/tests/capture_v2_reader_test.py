#!/usr/bin/env python3
"""Corruption checks against the native offline fixture; no UI or input capture."""

import pathlib
import struct
import sys
import tempfile

from capture_v2_reader import NATIVE_TYPES, read_capture, summarize


def rejected(data):
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "corrupt.bin"
        path.write_bytes(data)
        try:
            read_capture(path)
        except ValueError:
            return
        raise AssertionError("reader accepted malformed capture")


def main(path):
    source = bytearray(pathlib.Path(path).read_bytes())
    result = summarize(read_capture(path))
    assert {key: result["counts"][key] for key in ("CG22", "CG29", "CG30", "MT")} == {"CG22": 2, "CG29": 1, "CG30": 2, "MT": 3}
    assert sum(result["counts"].values()) == 8
    assert len(result["native_spans"]) == 3 and len(result["raw_spans"]) == 1
    assert result["raw_spans"][0]["ended_with_zero"]

    rejected(source[:-1])
    rejected(source + b"x")
    changed = source.copy()
    struct.pack_into("<I", changed, 12, 16385)
    rejected(changed)
    changed = source.copy()
    struct.pack_into("<H", changed, 64 + 6, 10)  # Keyboard must never enter the file.
    rejected(changed)
    for event_type in NATIVE_TYPES:
        changed = source.copy()
        struct.pack_into("<H", changed, 64 + 6, event_type)
        with tempfile.TemporaryDirectory() as directory:
            accepted = pathlib.Path(directory) / "allowed.bin"
            accepted.write_bytes(changed)
            assert read_capture(accepted)["records"][0]["type"] == event_type
    second = 64 + struct.unpack_from("<I", source, 64)[0]
    changed = source.copy()
    struct.pack_into("<Q", changed, second + 8, 1)
    rejected(changed)
    changed = source.copy()
    changed[second + 48] = 0  # Break the raw frame magic.
    rejected(changed)
    print("capture v2 reader: valid fixture and six corruption cases passed")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: capture_v2_reader_test.py FIXTURE.bin")
    main(sys.argv[1])
