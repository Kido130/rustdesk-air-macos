# Passive native gesture capture v2

`capture_v2.mm` is linked into the private Air app but stays inactive unless a client is launched with an explicit diagnostic flag. It listens for native CGEvent types 18, 19, 20, 22, 29, 30, 31, 32, and 34, and records the existing input module's MultitouchSupport contact frames. Its separate listen-only tap is inserted ahead of the normal consuming tap. It never records keyboard, media, or mouse button events, posts input, creates a window, or changes app focus. The normal native input path has no diagnostic tap, file, or MT capture work when the flag is absent.

For a coordinated physical pass, launch the signed **Air client** in Remote Mode with `--capture-native-session /absolute/new-file.bin --capture-native-seconds 60`. Duration defaults to 60 seconds and must be 1–60. `--capture-input-test` cannot be combined with this mode. The capture starts only after the host's authenticated native-input ready message, and its queued start is cancelled if that connection generation changes. It stops on disconnect, app shutdown, or its deadline. The file is reserved at start with `O_EXCL|O_NOFOLLOW` and mode `0600`; an existing path is rejected without replacement. Only the capture's original inode can be removed on error.

Wait for stderr `air_native_session_capture_started=1` before requesting physical gestures; that line includes `duration_seconds`, `started_unix_ms`, and `started_uptime_ns` for deadline coordination. A setup failure prints `air_native_session_capture_start_error=N` immediately. Stop prints `air_native_session_capture_status=N records=… dropped=… tap_disabled=…`; process exit prints `air_native_session_capture_final_status=N`. Status 0 means not started, 1 active, 2 saved, and negatives mean bad arguments/thread (`-1`), Input Monitoring unavailable (`-2`), tap setup failure (`-3`), write failure (`-4`), exclusive file reservation failure (`-5`), stale connection or inactive window (`-6`), or no registered MT device (`-7`). The recorder reuses the production MT callback registration and device start/stop owner, so ending a diagnostic does not unregister a separate callback or stop another owner's device.

## Binary format

All integers are little endian. The file begins with a 64-byte header:

| Offset | Value |
|---:|---|
| 0 | `RDAICAP2` (8 bytes) |
| 8 | Header length, `64` (u32) |
| 12 | Retained record count (u32) |
| 16 | Dropped record count (u64) |
| 24 | Maximum records, `16384` (u32) |
| 28 | Maximum record bytes, `16777216` (u32) |
| 32 | First retained monotonic timestamp (u64 nanoseconds) |
| 40 | Last retained monotonic timestamp (u64 nanoseconds) |
| 48 | Cumulative accepted CG records (u32) |
| 52 | Cumulative accepted raw MT records (u32) |
| 56 | Tap disable notifications (u32) |
| 60 | Reserved zero (u32) |

Each record has a 48-byte header followed by its payload:

| Record offset | Value |
|---:|---|
| 0 | Total record bytes (u32) |
| 4 | Kind: 1 CG, 2 raw MT (u16) |
| 6 | CG type 18/19/20/22/29/30/31/32/34, or zero for MT (u16) |
| 8 | Shared capture clock: `CLOCK_UPTIME_RAW`, nanoseconds (u64) |
| 16 | Original CG event timestamp, or the original MT callback `double` bits (u64) |
| 24 | Embedded IOHID sender ID, or MT device ID (u64) |
| 32 | AppKit event phase; zero for MT (u32) |
| 36 | AppKit event subtype; zero for MT (u32) |
| 40 | AppKit touch count or raw contact count (u32) |
| 44 | Payload bytes (u32) |

CG payloads are exact `CGEventCreateData` bytes, up to 65,536 per event. MT payloads are `RDAF` v1 packets with one device ID and up to 16 records of finger ID, state, normalized x/y, and pressure (maximum 336 bytes). The MT callback's original `double` timestamp is preserved as bits without assuming its time units. The common monotonic timestamp is taken while appending the record, so CG and MT records are chronologically ordered in one ring. Sender/device IDs are **not** remapped. The capture holds at most 16,384 records and 16 MiB of records; older records are evicted when either limit is reached. A dropped count or tap-disable notification means a complete gesture may be missing. Type-29 `allTouches` comes from an NSEvent bridge and can be zero even when the embedded HID event has finger children; app delivery requires a separate receiver test.

The reader checks bounds, allowed event types, chronological order, and raw packet shape. It reports phase begin/end spans and raw contact runs, plus counts of nearby records from the other source within 20 ms. Those proximity counts show possible correspondence; they do not prove the streams are duplicates or that a Pro app accepts playback. Type-29 events often have phase zero, so its reader spans use a 250 ms idle gap. A raw run ends only when an empty frame arrives; otherwise the reader reports an open run. It prints no finger coordinates or packet bytes.

```sh
python3 src/air/tests/capture_v2_reader.py /absolute/capture-v2.bin --spans
```

## Offline checks

The native fixture creates a synthetic typed sequence in memory, checks both ring limits and private output permissions, and writes a small file for the Python reader. It does not start a tap or post any event. Build each architecture with Command Line Tools:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools clang++ -std=c++17 -fobjc-arc -fblocks -arch arm64 src/air/tests/capture_v2_offline_test.mm -o /tmp/capture_v2_offline_arm64 -framework AppKit -framework ApplicationServices -framework IOKit
DEVELOPER_DIR=/Library/Developer/CommandLineTools clang++ -std=c++17 -fobjc-arc -fblocks -arch x86_64 src/air/tests/capture_v2_offline_test.mm -o /tmp/capture_v2_offline_x86_64 -framework AppKit -framework ApplicationServices -framework IOKit
/tmp/capture_v2_offline_arm64 /tmp/new-capture-v2-fixture.bin
python3 src/air/tests/capture_v2_reader_test.py /tmp/new-capture-v2-fixture.bin
```

The fixture's CG payload bytes are synthetic placeholders; it tests the container and reader, not Core Graphics deserialization. A new physical Air capture and live Pro receiver test are still required to judge real gesture forwarding. The existing v1 capture selected one CG event and a different-time raw frame, so it cannot establish duplicate source behavior.
