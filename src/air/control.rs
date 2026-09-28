use super::{ffi, native_result, SESSION};
use crate::client::{Data, Interface};
use base::message_proto::{AirControl, Message};
use hbb_common::tokio;
use std::{ffi::CString, sync::{atomic::{AtomicBool, AtomicI32, Ordering}, Mutex, OnceLock}, time::Duration};

unsafe extern "C" { fn clock_gettime_nsec_np(clock_id: i32) -> u64; }
fn local_uptime_ns() -> u64 { unsafe { clock_gettime_nsec_np(8) } } // CLOCK_UPTIME_RAW on macOS.

static REQUESTED: AtomicBool = AtomicBool::new(false);
static RAW_REQUIRED: AtomicBool = AtomicBool::new(false);
static CONNECTED: AtomicBool = AtomicBool::new(false);
static RAW_SUPPORTED: AtomicBool = AtomicBool::new(false);
static HOST_INPUT_OWNER: AtomicI32 = AtomicI32::new(0);
static HOST_RAW_OWNER: AtomicI32 = AtomicI32::new(0);
static NATIVE_CAPTURE_REQUESTED: AtomicBool = AtomicBool::new(false);
static NATIVE_CAPTURE: Mutex<Option<(i32, CString)>> = Mutex::new(None);
pub(super) fn input_trace() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var("RUSTDESK_AIR_INPUT_TRACE").as_deref() == Ok("1"))
}
pub(super) fn trace_raw(stage: &str, payload: &[u8], reason: &str) {
    if !input_trace() || payload.len() < 32 || !payload.starts_with(b"RDAF\x02") { return; }
    let Some(sequence) = payload.get(16..24).and_then(|value| value.try_into().ok()) else { return; };
    let Some(source_ns) = payload.get(24..32).and_then(|value| value.try_into().ok()) else { return; };
    let sequence = u64::from_le_bytes(sequence);
    let source_ns = u64::from_le_bytes(source_ns);
    eprintln!("air_input_trace stage={stage} seq={sequence} count={} source_ns={source_ns} local_ns={} reason={reason}", payload[5], local_uptime_ns());
}
pub(super) fn trace_data(stage: &str, data: &Data, reason: &str) {
    use base::message_proto::message;
    if let Data::Message(packet) = data {
        if let Some(message::Union::AirControl(control)) = packet.union.as_ref() {
            if control.kind == 3 { trace_raw(stage, &control.payload, reason); }
        }
    }
}
pub(super) fn configure(enabled: bool) { REQUESTED.store(enabled, Ordering::Relaxed); }
pub(super) fn configure_raw_required(enabled: bool) { RAW_REQUIRED.store(enabled, Ordering::SeqCst); }
pub(super) fn configure_native_capture(request: Option<(i32, CString)>) {
    NATIVE_CAPTURE_REQUESTED.store(request.is_some(), Ordering::Relaxed);
    *NATIVE_CAPTURE.lock().unwrap() = request;
}
pub(super) fn requested() -> bool { REQUESTED.load(Ordering::Relaxed) }
fn raw_required() -> bool { RAW_REQUIRED.load(Ordering::SeqCst) }
fn raw_v2_packet(payload: &[u8]) -> bool {
    payload.len() >= 48 && payload.starts_with(b"RDAF\x02") && payload[5] <= 16
        && payload[6..8] == [0, 0] && payload.len() == 48 + 88 * payload[5] as usize
}
fn packet(kind: u32, payload: Vec<u8>) -> Data {
    let mut message = Message::new();
    message.set_air_control(AirControl { kind, payload: payload.into(), ..Default::default() });
    Data::Message(message)
}
fn send(kind: u32, payload: Vec<u8>) {
    let data = packet(kind, payload);
    if kind == 3 {
        super::shell::send_input(data);
        return;
    }
    if let Some(session) = SESSION.lock().unwrap().clone() {
        session.send(data);
    }
}
pub(super) fn hello() {
    if !requested() || !super::shell::accept_input() { return; }
    let raw = raw_required();
    let mut raw_supported = unsafe { ffi::air_client_raw_supported() } != 0;
    for _ in 0..10 {
        if !raw || raw_supported { break; }
        std::thread::sleep(Duration::from_millis(100));
        raw_supported = unsafe { ffi::air_client_raw_supported() } != 0;
    }
    if raw && (!raw_supported || unsafe { ffi::air_raw_wire_version() } != 2) {
        super::shell::stop_for_input_refusal("Finger contact forwarding is unavailable on this Air. Turn off Forward individual finger contacts in connection options");
        return;
    }
    let generation = unsafe { ffi::air_input_generation() };
    send(1, if raw { vec![1, 1, 2] } else { vec![1, 0] });
    if let Ok(runtime) = tokio::runtime::Handle::try_current() {
        runtime.spawn(async move {
            tokio::time::sleep(Duration::from_secs(5)).await;
            let reason = if raw {
                "The Pro did not confirm finger contact forwarding within five seconds. Turn off Forward individual finger contacts in connection options"
            } else {
                "The Pro did not enable Remote Mode input within five seconds"
            };
            super::shell::stop_for_input_refusal_if(reason, || {
                handshake_pending(raw, raw_required(), CONNECTED.load(Ordering::SeqCst),
                    generation == unsafe { ffi::air_input_generation() },
                    requested() && super::shell::accept_input())
            });
        });
    } else {
        super::shell::stop_for_input_refusal("Cannot wait for Remote Mode input outside the session runtime");
    }
}
fn handshake_pending(sent_raw: bool, required_raw: bool, ready: bool, same_generation: bool, accepting: bool) -> bool {
    sent_raw == required_raw && !ready && same_generation && accepting
}
pub(super) fn raw_supported() -> bool { RAW_SUPPORTED.load(Ordering::Relaxed) }
pub(super) fn host_raw_owner(id: i32) -> bool { id != 0 && HOST_RAW_OWNER.load(Ordering::SeqCst) == id }
pub(super) extern "C" fn input_event(bytes: *const u8, len: usize, generation: u64) {
    if bytes.is_null() || len == 0 || len > 65536 { return; }
    let payload = unsafe { std::slice::from_raw_parts(bytes, len) };
    trace_raw("rust_callback", payload, if CONNECTED.load(Ordering::Relaxed) { "ok" } else { "disconnected" });
    if !CONNECTED.load(Ordering::Relaxed) { return; }
    if payload.starts_with(b"RDAF") && (!raw_supported() || !raw_v2_packet(payload)) {
        trace_raw("rust_callback_drop", payload, "unsupported_or_invalid");
        super::shell::stop_for_input_refusal("Raw contact packet was not negotiated or valid");
        return;
    }
    super::shell::send_native_input(packet(3, payload.to_vec()), generation);
}
pub(super) extern "C" fn release_input() {
    if CONNECTED.load(Ordering::Relaxed) { send(4, Vec::new()); }
}
pub(super) extern "C" fn native_release_input(generation: u64) {
    super::shell::with_input_lock(|| {
        if CONNECTED.load(Ordering::Relaxed)
            && generation == unsafe { ffi::air_input_generation() } {
            send(4, Vec::new());
        }
    });
}
pub(crate) fn client_message(message: AirControl) {
    if super::shell::shutting_down() { return; }
    if message.kind == 51 {
        if message.payload.as_ref() == [1, 0] || message.payload.as_ref() == [1, 1] {
            super::audio::set_demand(message.payload[1] == 1);
        }
        return;
    }
    if matches!(message.kind, 40 | 42) { super::workspace::client_message(message); return; }
    if !requested() { return; }
    match message.kind {
        2 => {
            let raw = raw_required();
            let valid = if raw {
                &message.payload[..] == [1, 1, 2] && unsafe { ffi::air_client_raw_supported() } != 0
                    && unsafe { ffi::air_raw_wire_version() } == 2
            } else {
                &message.payload[..] == [1] || &message.payload[..] == [1, 0]
            };
            if !valid {
                super::shell::stop_for_input_refusal("The Pro cannot forward individual finger contacts. Turn off Forward individual finger contacts in connection options");
                return;
            }
            let connected = super::shell::with_input_lock(|| {
                if !super::shell::accept_input() { return false; }
                RAW_SUPPORTED.store(raw, Ordering::Relaxed);
                CONNECTED.store(true, Ordering::Relaxed);
                unsafe { ffi::air_input_connected(1); }
                unsafe { ffi::air_input_raw_enabled(raw as i32); }
                if NATIVE_CAPTURE_REQUESTED.load(Ordering::Relaxed) {
                    if let Some((seconds, path)) = NATIVE_CAPTURE.lock().unwrap().take() {
                        let generation = unsafe { ffi::air_input_generation() };
                        unsafe { ffi::air_capture_v2_schedule(seconds, path.as_ptr(), generation); }
                    }
                }
                true
            });
            if connected { super::workspace::raw_ready(); }
        }
        5 => {
            let detail = &message.payload[..message.payload.len().min(1024)];
            super::shell::stop_for_input_refusal(&String::from_utf8_lossy(detail));
        }
        _ => {}
    }
}
pub(super) fn disconnected() {
    super::shell::with_input_lock(disconnected_locked);
}
pub(super) fn disconnected_locked() {
    super::audio::reset_demand();
    super::workspace::disconnected();
    if NATIVE_CAPTURE_REQUESTED.load(Ordering::Relaxed) { unsafe { ffi::air_capture_v2_stop(); } }
    CONNECTED.store(false, Ordering::Relaxed);
    RAW_SUPPORTED.store(false, Ordering::Relaxed);
    unsafe { ffi::air_input_raw_enabled(0); }
    unsafe { ffi::air_input_connected(0); }
}
fn host_failure(kind: u32, error: impl ToString, release: impl FnOnce()) -> AirControl {
    if kind == 3 { release(); }
    AirControl { kind: 5, payload: error.to_string().into_bytes().into(), ..Default::default() }
}
fn end_host_input(id: i32) {
    super::workspace::host_disconnected(id);
    let _ = HOST_RAW_OWNER.compare_exchange(id, 0, Ordering::SeqCst, Ordering::SeqCst);
    let _ = HOST_INPUT_OWNER.compare_exchange(id, 0, Ordering::SeqCst, Ordering::SeqCst);
    unsafe { ffi::air_host_input_end(id); }
}
fn raw_request(payload: &[u8]) -> Result<bool, &'static str> {
    if payload == [1] || payload == [1, 0] { return Ok(false); }
    if payload == [1, 1, 2] { return Ok(true); }
    Err("Unsupported raw contact protocol; version 2 is required")
}
pub(crate) fn host_message(id: i32, message: AirControl) -> Option<AirControl> {
    if message.kind == 3 { trace_raw("rust_host_arrived", &message.payload, "ok"); }
    if message.kind == 1 {
        let previous = HOST_INPUT_OWNER.load(Ordering::SeqCst);
        if previous != 0 && previous != id
            && crate::server::air_input_reconnect_can_replace(previous, id) {
            eprintln!("air_input_reconnect_takeover old={previous} new={id}");
            end_host_input(previous);
        }
    }
    let requested_raw = if message.kind == 1 {
        match raw_request(&message.payload) {
            Ok(requested) => requested,
            Err(error) => return Some(host_failure(1, error, || {})),
        }
    } else { false };
    let result = match message.kind {
        1 => native_result(unsafe { ffi::air_host_input_begin(id, requested_raw as i32) }),
        3 => {
            if message.payload.is_empty() || message.payload.len() > 65536 {
                trace_raw("rust_host_drop", &message.payload, "invalid_length");
                return Some(host_failure(3, "Invalid native input packet", || end_host_input(id)));
            }
            native_result(unsafe { ffi::air_host_input_event(id, message.payload.as_ptr(), message.payload.len()) })
        }
        4 => { unsafe { ffi::air_host_input_release(id); } return None; }
        _ => return None,
    };
    match result {
        Ok(()) if message.kind == 1 => {
            HOST_INPUT_OWNER.store(id, Ordering::SeqCst);
            if requested_raw && (unsafe { ffi::air_host_raw_supported() } == 0
                || unsafe { ffi::air_raw_wire_version() } != 2) {
                end_host_input(id);
                return Some(host_failure(1, "Host raw contact protocol version 2 is unavailable", || {}));
            }
            HOST_RAW_OWNER.store(if requested_raw { id } else { 0 }, Ordering::SeqCst);
            Some(AirControl { kind: 2,
                payload: if requested_raw { vec![1, 1, 2] } else { vec![1, 0] }.into(),
                ..Default::default() })
        }
        Ok(()) => None,
        Err(error) => Some(host_failure(message.kind, error, || end_host_input(id))),
    }
}
pub(crate) async fn dispatch_host(id: i32, message: AirControl) -> Option<AirControl> {
    if !matches!(message.kind, 41 | 43 | 44 | 45) { return host_message(id, message); }
    match hbb_common::tokio::task::spawn_blocking(move || super::workspace::host_message(id, message)).await {
        Ok(reply) => reply,
        Err(error) => Some(AirControl {
            kind: 42, payload: format!("Space switch failed: {error}").into_bytes().into(),
            ..Default::default()
        }),
    }
}
pub(crate) fn host_disconnected(id: i32) { end_host_input(id); }

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn hello_timeout_fails_only_an_unanswered_current_round_for_both_modes() {
        for raw in [false, true] {
            assert!(handshake_pending(raw, raw, false, true, true));
            assert!(!handshake_pending(raw, raw, true, true, true));
            assert!(!handshake_pending(raw, raw, false, false, true));
            assert!(!handshake_pending(raw, raw, false, true, false));
            assert!(!handshake_pending(raw, !raw, false, true, true));
        }
    }

    #[test]
    fn rejected_native_event_releases_host_grab_before_failure_reply() {
        let released = Cell::new(false);
        let reply = host_failure(3, "invalid native input", || released.set(true));
        assert!(released.get());
        assert_eq!(reply.kind, 5);
        assert_eq!(&reply.payload[..], b"invalid native input");
        let unrelated_owner = Cell::new(false);
        let reply = host_failure(1, "already owned", || unrelated_owner.set(true));
        assert_eq!(reply.kind, 5);
        assert!(!unrelated_owner.get());
    }
    #[test]
    fn empty_native_event_receives_failure_instead_of_leaving_grab_active() {
        let reply = host_message(12345, AirControl { kind: 3, ..Default::default() })
            .expect("invalid event must get failure reply");
        assert_eq!(reply.kind, 5);
        assert_eq!(&reply.payload[..], b"Invalid native input packet");
    }
    #[test]
    fn raw_hello_requires_version_two_but_legacy_nonraw_remains_valid() {
        assert_eq!(raw_request(&[1]), Ok(false));
        assert_eq!(raw_request(&[1, 0]), Ok(false));
        assert_eq!(raw_request(&[1, 1, 2]), Ok(true));
        for invalid in [&[1, 1][..], &[1, 1, 1], &[1, 0, 2], &[2, 1, 2], &[1, 1, 2, 0]] {
            assert!(raw_request(invalid).is_err());
        }
    }
    #[test]
    fn raw_v2_packet_screen_rejects_old_or_unbounded_frames() {
        let mut packet = vec![0; 48 + 88 * 16];
        packet[..5].copy_from_slice(b"RDAF\x02");
        packet[5] = 16;
        assert!(raw_v2_packet(&packet));
        packet[4] = 1;
        assert!(!raw_v2_packet(&packet));
        packet[4] = 2;
        packet[5] = 17;
        assert!(!raw_v2_packet(&packet));
        packet[5] = 16;
        packet.pop();
        assert!(!raw_v2_packet(&packet));
        packet.push(0);
        packet[6] = 1;
        assert!(!raw_v2_packet(&packet));
    }
}
