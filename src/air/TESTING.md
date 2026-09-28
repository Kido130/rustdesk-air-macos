# Native video tests

`rustdesk-air --self-test` exercises a real Metal device, uploads a full image and
a small patch, reads back the GPU desktop in the test only, and compares every
byte including pixels outside the patch. It also runs real hardware H.264 and
HEVC encode/decode sessions and requires IOSurface-backed NV12 output mapped to
Metal. Offscreen tests do not establish onscreen presentation or Air CPU usage.

The dependency-free `rustdesk-air-protocol` tests cover random changed pixels,
row padding, unchanged-frame suppression, dropped deltas, full recovery, resize,
truncation, oversized coordinates, invalid source buffers and untrusted bytes.
It also checks idle resynchronization and rejects stale full frames. The native
GPU test verifies that an aborted invalid update preserves the existing image,
and that the upload buffer can be reused afterwards.
On macOS, three additional tests cover Apple's LZ4 envelope: exact round trips,
raw small patches, incompressible data, truncation, corrupted headers, expanded
size limits, and trailing bytes. The system compression library is linked only
on macOS; no package dependency was added.

Use `tools/air/live-local.py --binary /absolute/path/to/rustdesk-air --work-dir
/absolute/path/to/test-evidence` for bounded real ScreenCaptureKit → encrypted
RustDesk → native Metal sessions in all three modes. This opens ordinary
closable windows. It stores logs and aggregate metrics, never captured video.
The pairing file is private and must not be committed or shared publicly.
The live scripts use a separate `RustDeskAirTest` profile. Do not run different
host tests concurrently: each owns port 21128 and the test profile's password.

`tools/air/test-pairing.py` uses real sockets and client sessions to reject the
wrong pinned key, wrong host identity, wrong password and a plaintext downgrade.

These local tests run both endpoints on the same Mac. They are functional
checks, not a substitute for Intel Air performance or LAN measurements.

`presented` counts Metal drawable presentation callbacks with a nonzero actual
presentation time. It is not a network frame rate or latency metric. The
`decoded_cpu_pixel_bytes` zero is a structural application-path assertion, not an
instrumentation measurement of copies inside Apple's drivers or frameworks.
`submitted`, `dropped` and `drawable_misses` distinguish GPU submission from
visible output; never substitute them for `presented` in a passing result.
`received_video_bytes` counts native video payload bytes before decompression;
it excludes transport framing, encryption overhead and other protocol messages.

## Target Air measurements

`tools/air/measure-client.py` runs a real paired client for 10–120 seconds, samples
process CPU time and resident memory, and requires positive actual presentations
(plus a hardware session in video modes). The first five seconds are excluded
from the reported CPU mean. 100% equals one logical core. These numbers exclude
WindowServer, VideoToolbox helper processes and other system work; they do not
measure total device power or CPU. A failed run's idle CPU is not a streaming
performance result.
Bundled apps launch through Launch Services so the test uses the user's normal
graphical session and app-specific LAN permission. A temporary sleep assertion
lasts only for the tested client process. Direct executables use a separate launch
path; background SSH launch is not interchangeable with a normal app launch.

Compile `tools/air/workload.swift` with `swiftc -O` on the Pro. Run it with
`idle`, `small`, `scroll` or `motion` and a 10–120 second duration. It opens an
ordinary 800×500-point test window on the built-in display and closes itself.
Start it before each client measurement and let it last longer than the client.
This supplies repeatable desktop content through real ScreenCaptureKit and LAN
transport. Record workload, scaling, network and client version with results.
Keep remote-view mirrors off the captured display to avoid recursive motion.

The final hardware gate is a real Pro → Intel Air session: measure idle, scrolling
and motion CPU, resident memory, delivered/presented frames, and response latency
on the target Air. Check hardware availability/failure behavior on that machine.

On the three-display Pro, compile `src/air/capture.mm` with
`src/air/tests/capture_builtin_boundary_test.mm` and link Foundation,
CoreGraphics, ScreenCaptureKit, VideoToolbox, CoreMedia and CoreVideo. The test
calls the actual capture entry point with each external display ID and zero;
each must be rejected before a ScreenCaptureKit stream starts. Pair this
negative gate with a real built-in session because it does not itself capture
or identify the positive stream.

## Exact display matching

`--self-test-renderer` runs the Metal tests without requiring an encoder (useful
on the Intel Air). The GPU test now also renders the captured texture through
the actual fragment shader into a same-size target and compares every RGB byte.
The display is opaque, so output alpha is checked against 255.

Build `tools/air/test-display.mm` with `src/air/display.mm`, C++17, ARC and AppKit.
Its `restore 1024 640 2048 1280` test rejects malformed/unsupported modes, applies
an exact supported mode, and compares all original monitor modes and origins
after restoration. Run its bounded `crash` variant in a child process and
terminate that child after `MATCH_APPLIED`; verify the OS restores the original
configuration independently of cleanup code. These tests change the real
built-in resolution temporarily.

The real Air gate uses `measure-client.py --match-display`. It additionally
requires positive `pixel_matched_presentations`: actual displayed frames whose
source and drawable dimensions are identical. Record `source_width/height` and
`drawable_width/height`. Change the Air's scaling during a bounded session and
verify a new Pro mode/capture raster, then verify restoration on disconnect.
Do not confuse framebuffer-to-drawable identity with macOS panel scaling.

## Adaptive motion and frame overlap

Protocol tests exercise motion entry, keyframes when video resumes, quiet-time
hysteresis, full exact recovery after skipped lossless deltas, pixel identity of
the recovered frame, resize, and idle refresh. The native self-test additionally
cycles hardware HEVC → exact Metal surfaces three times and compares all restored
BGRA bytes on the GPU readback path used only by tests.

The isolated `src/air/flow.rs` test verifies per-peer acknowledgement accounting,
multiple replies in one receive batch, disconnect release, and missing-reply
timeout. Compile it with `rustc --test --edition=2021 src/air/flow.rs` if running
outside the full application test harness.

Live adaptive tests must include sustained movement followed by a still desktop.
Require hardware decoding during motion, more than one `exact_commits`, and
`last_surface_kind: 1` (exact) after settling. A successful idle session alone
does not demonstrate switching. `last_surface_kind: 2` denotes hardware video.
Compare actual presentations, not just decoded frames, with the previous build
on the same Air, resolution and workload. Use an unrestricted direct connection.
