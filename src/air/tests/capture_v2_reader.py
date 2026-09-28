#!/usr/bin/env python3
"""Validate and summarize a passive RDAICAP2 file without printing input payloads."""

import argparse
import bisect
import collections
import json
import math
import pathlib
import struct

HEADER = struct.Struct("<8sIIQIIQQIIII")
RECORD = struct.Struct("<IHHQQQIIII")
MAX_CG = 65_536
MAX_MT = 336
NATIVE_TYPES = (18, 19, 20, 22, 29, 30, 31, 32, 34)
PHASE_BEGIN = 1
PHASE_END = 8 | 16


def read_capture(path):
    data = pathlib.Path(path).read_bytes()
    if len(data) < HEADER.size:
        raise ValueError("short header")
    (magic, header_size, count, dropped, record_limit, byte_limit,
     first_ns, last_ns, cg_total, mt_total, disabled, reserved) = HEADER.unpack_from(data)
    if magic != b"RDAICAP2" or header_size != HEADER.size or reserved:
        raise ValueError("invalid v2 header")
    if not (0 < record_limit <= 16384 and 0 < byte_limit <= 16 * 1024 * 1024):
        raise ValueError("invalid capture limits")
    if count > record_limit or len(data) > header_size + byte_limit:
        raise ValueError("capture exceeds declared limits")
    if cg_total + mt_total < count:
        raise ValueError("captured counters below retained count")
    if cg_total + mt_total != count + dropped:
        # Oversized or invalid events can be dropped before entering the ring.
        if cg_total + mt_total > count + dropped:
            raise ValueError("capture counters disagree")
    offset = header_size
    records = []
    previous_ns = 0
    for index in range(count):
        if offset + RECORD.size > len(data):
            raise ValueError(f"truncated record header {index}")
        (size, kind, event_type, monotonic_ns, source_timestamp, sender,
         phase, subtype, touches, payload_size) = RECORD.unpack_from(data, offset)
        cap = MAX_CG if kind == 1 else MAX_MT if kind == 2 else 0
        if (not cap or size != RECORD.size + payload_size or
                not 0 < payload_size <= cap or offset + size > len(data)):
            raise ValueError(f"invalid record size/type {index}")
        if monotonic_ns <= 0 or monotonic_ns < previous_ns:
            raise ValueError(f"nonmonotonic record {index}")
        if kind == 1 and (event_type not in NATIVE_TYPES or touches > 16):
            raise ValueError(f"invalid native event {index}")
        if kind == 2:
            payload = memoryview(data)[offset + RECORD.size:offset + size]
            if (event_type or phase or subtype or touches > 16 or
                    payload_size != 16 + touches * 20 or
                    payload[:5].tobytes() != b"RDAF\x01" or
                    payload[5] != touches or payload[6:8].tobytes() != b"\0\0" or
                    struct.unpack_from("<Q", payload, 8)[0] != sender):
                raise ValueError(f"invalid raw frame {index}")
            states = []
            for contact in range(touches):
                finger, state, x, y, pressure = struct.unpack_from("<IIfff", payload, 16 + 20 * contact)
                if finger > 0x7fffffff or state > 7 or not all(map(math.isfinite, (x, y, pressure))):
                    raise ValueError(f"invalid contact {index}/{contact}")
                if not (-0.25 <= x <= 1.25 and -0.25 <= y <= 1.25 and 0 <= pressure <= 10000):
                    raise ValueError(f"contact outside allowed range {index}/{contact}")
                states.append(state)
        records.append({"kind": kind, "type": event_type, "ns": monotonic_ns,
                        "source_timestamp": source_timestamp, "sender": sender,
                        "phase": phase, "subtype": subtype, "touches": touches,
                        "bytes": payload_size, "states": states if kind == 2 else []})
        offset += size
        previous_ns = monotonic_ns
    if offset != len(data) or ((records[0]["ns"], records[-1]["ns"]) if records else (0, 0)) != (first_ns, last_ns):
        raise ValueError("trailing bytes or time range mismatch")
    return {"records": records, "dropped": dropped, "tap_disabled": disabled,
            "cg_captured": cg_total, "mt_captured": mt_total}


def _spans(records, event_type, gap_ns=250_000_000):
    """Contiguous activity spans, including unphased native gesture events."""
    spans = []
    active = {}
    for record in records:
        if record["type"] != event_type or record["kind"] != 1:
            continue
        sender = record["sender"]
        previous = active.get(sender)
        if previous and record["ns"] - previous["end_ns"] > gap_ns:
            spans.append(previous)
            previous = None
        if not previous or record["phase"] & PHASE_BEGIN:
            if previous:
                spans.append(previous)
            previous = {"type": event_type, "sender": sender, "start_ns": record["ns"],
                        "end_ns": record["ns"], "events": 0, "touch_samples": 0,
                        "began": False, "ended": False}
            active[sender] = previous
        previous["events"] += 1
        previous["touch_samples"] += record["touches"]
        previous["end_ns"] = record["ns"]
        previous["began"] |= bool(record["phase"] & PHASE_BEGIN)
        previous["ended"] |= bool(record["phase"] & PHASE_END)
        if record["phase"] & PHASE_END:
            spans.append(previous)
            active.pop(sender, None)
    spans.extend(active.values())
    return sorted(spans, key=lambda item: item["start_ns"])


def _raw_spans(records, gap_ns=250_000_000):
    spans = []
    active = {}
    for record in records:
        if record["kind"] != 2:
            continue
        sender = record["sender"]
        previous = active.get(sender)
        if previous and record["ns"] - previous["end_ns"] > gap_ns:
            spans.append(previous)
            previous = None
            active.pop(sender, None)
        if not previous and record["touches"]:
            previous = {"device": sender, "start_ns": record["ns"], "end_ns": record["ns"],
                        "frames": 0, "contact_samples": 0, "states": {}, "ended_with_zero": False}
            active[sender] = previous
        if previous:
            previous["frames"] += 1
            previous["contact_samples"] += record["touches"]
            previous["end_ns"] = record["ns"]
            for state in record["states"]:
                key = str(state)
                previous["states"][key] = previous["states"].get(key, 0) + 1
            if not record["touches"]:
                previous["ended_with_zero"] = True
                spans.append(previous)
                active.pop(sender, None)
    spans.extend(active.values())
    return sorted(spans, key=lambda item: item["start_ns"])


def summarize(capture):
    records = capture["records"]
    counts = collections.Counter((r["kind"], r["type"]) for r in records)
    phases = collections.defaultdict(collections.Counter)
    senders = collections.defaultdict(set)
    for r in records:
        phases[str(r["type"])][str(r["phase"])] += 1
        senders[str(r["type"])].add(r["sender"])
    raw = [r for r in records if r["kind"] == 2]
    raw_times = [r["ns"] for r in raw]
    native_spans = [span for event_type in NATIVE_TYPES for span in _spans(records, event_type)]
    for span in native_spans:
        first = bisect.bisect_left(raw_times, span["start_ns"] - 20_000_000)
        last = bisect.bisect_right(raw_times, span["end_ns"] + 20_000_000)
        near = raw[first:last]
        span["near_raw_frames"] = len(near)
        span["near_raw_contacts"] = sum(r["touches"] for r in near)
        span["complete_phase_pair"] = span["began"] and span["ended"]
    raw_spans = _raw_spans(records)
    native = [r for r in records if r["kind"] == 1]
    native_times = [r["ns"] for r in native]
    for span in raw_spans:
        first = bisect.bisect_left(native_times, span["start_ns"] - 20_000_000)
        last = bisect.bisect_right(native_times, span["end_ns"] + 20_000_000)
        near = native[first:last]
        span["near_native"] = {str(t): sum(r["type"] == t for r in near) for t in NATIVE_TYPES}
    return {"records": len(records), "duration_ms": round((records[-1]["ns"] - records[0]["ns"]) / 1e6, 3) if records else 0,
            "dropped": capture["dropped"], "tap_disabled": capture["tap_disabled"],
            "counts": {**{f"CG{event_type}": counts[1, event_type] for event_type in NATIVE_TYPES}, "MT": counts[2, 0]},
            "phase_counts": {kind: dict(values) for kind, values in phases.items()},
            "senders": {kind: sorted(values) for kind, values in senders.items()},
            "raw_contacts": sum(r["touches"] for r in raw),
            "native_spans": native_spans,
            "raw_spans": raw_spans,
            "warning": "Dropped records can cut off begin/end sequences." if capture["dropped"] else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", help="path to RDAICAP2 file")
    parser.add_argument("--spans", action="store_true", help="include per-gesture spans in JSON")
    args = parser.parse_args()
    result = summarize(read_capture(args.capture))
    if not args.spans:
        result.pop("native_spans")
        result.pop("raw_spans")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
