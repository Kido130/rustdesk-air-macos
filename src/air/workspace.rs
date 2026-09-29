use super::{ffi, native_result, SESSION};
use crate::client::{Data, Interface};
use base::message_proto::{AirControl, Message};
use hbb_common::{anyhow::anyhow, bail, ResultType};
use std::sync::{atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering}, Mutex};
use std::time::{Duration, Instant};

static REQUESTED: AtomicBool = AtomicBool::new(false);
static HOST_REQUESTED: AtomicBool = AtomicBool::new(false);
static ACTIVE: AtomicBool = AtomicBool::new(false);
static RECONNECTING: AtomicBool = AtomicBool::new(false);
static RECONNECT_REQUESTED: AtomicBool = AtomicBool::new(false);
static CLIENT_COUNT: AtomicU8 = AtomicU8::new(0);
static CLIENT_CURRENT: AtomicU8 = AtomicU8::new(0);
static CLIENT_FLAGS: AtomicU8 = AtomicU8::new(0);
static LOOP_ENABLED: AtomicBool = AtomicBool::new(false);
static NEXT_SWIPE: AtomicU64 = AtomicU64::new(1);
static HOST_LAST_SWIPE: AtomicU64 = AtomicU64::new(0);
static CLIENT_SWIPE: Mutex<Option<(u64, u64)>> = Mutex::new(None);
static HOST_SWIPE: Mutex<Option<HostSwipe>> = Mutex::new(None);
// A raw-contact boundary completion can race the same gesture's native DockSwipe.
const LOOP_AVAILABLE: bool = false;

struct HostSwipe { id: i32, token: u64, starting_slot: i32, started: Instant }

pub(super) fn configure(value: bool) { REQUESTED.store(value, Ordering::SeqCst); }
pub(super) fn requested() -> bool { REQUESTED.load(Ordering::SeqCst) }
pub(crate) fn begin_host_session(requested: bool) {
    HOST_REQUESTED.store(requested, Ordering::SeqCst);
    reset_reconnect();
}
pub(crate) fn end_host_session() {
    HOST_REQUESTED.store(false, Ordering::SeqCst);
    reset_reconnect();
}

// Construct before the display guard so original display modes are restored first.
pub(crate) struct Session { restore_on_drop: bool }
impl Session {
    pub(crate) fn prepare() -> ResultType<Self> {
        native_result(unsafe { ffi::air_spaces_prepare() })
            .map_err(|error| anyhow!("Remote Spaces unavailable: {error}"))?;
        Ok(Self { restore_on_drop: true })
    }
    pub(crate) fn activate(&self) -> ResultType<()> {
        native_result(unsafe { ffi::air_spaces_activate() })
            .map_err(|error| anyhow!("Remote Spaces unavailable: {error}"))?;
        let ids = (1..=3).map(|slot| unsafe { ffi::air_spaces_slot_id(slot) }).collect::<Vec<_>>();
        if ids.contains(&0) || ids[0] == ids[1] || ids[0] == ids[2] || ids[1] == ids[2] {
            bail!("Remote Spaces unavailable: macOS did not provide three distinct remote Spaces");
        }
        let count = unsafe { ffi::air_spaces_slot_count() };
        if !(3..=9).contains(&count) { bail!("Remote Spaces unavailable: the Space chooser count is invalid"); }
        let mut all = ids;
        for slot in 4..=count {
            let sid = unsafe { ffi::air_spaces_slot_id(slot) };
            if sid == 0 || all.contains(&sid) {
                bail!("Remote Spaces unavailable: a fullscreen Space chooser identity is invalid");
            }
            all.push(sid);
        }
        ACTIVE.store(true, Ordering::SeqCst);
        LOOP_ENABLED.store(false, Ordering::SeqCst);
        HOST_LAST_SWIPE.store(0, Ordering::SeqCst);
        Ok(())
    }
    pub(crate) fn reload(&self) -> ResultType<()> {
        native_result(unsafe { ffi::air_spaces_reload() })
            .map_err(|error| anyhow!("Remote Spaces reload failed: {error}"))
    }
    pub(crate) fn restore(&mut self) -> ResultType<()> {
        restore_checked()?;
        self.restore_on_drop = false;
        Ok(())
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        if !self.restore_on_drop { return; }
        if let Err(error) = restore_checked() {
            super::error_status(&format!("Workspace restoration failed: {error}"));
        }
    }
}

// Optional workspace setup may fall back to ordinary capture only after
// native recovery confirms that all partially moved windows are restored.
pub(crate) fn restore_checked() -> ResultType<()> {
    ACTIVE.store(false, Ordering::SeqCst);
    LOOP_ENABLED.store(false, Ordering::SeqCst);
    *HOST_SWIPE.lock().unwrap() = None;
    native_result(unsafe { ffi::air_spaces_restore() })
}

pub(crate) fn state() -> AirControl {
    let active = ACTIVE.load(Ordering::SeqCst);
    if HOST_REQUESTED.load(Ordering::SeqCst) && !active {
        let flags = 16 | if RECONNECTING.load(Ordering::SeqCst) { 8 } else { 0 };
        return AirControl { kind: 40, payload: vec![1, 0, 0, flags].into(), ..Default::default() };
    }
    let count = if active { unsafe { ffi::air_spaces_slot_count() }.clamp(0, 9) as u8 } else { 0 };
    let current = if active { unsafe { ffi::air_spaces_current_slot() }.clamp(0, count as i32) as u8 } else { 0 };
    let supported = LOOP_AVAILABLE && active && (1..=3).contains(&current) && unsafe { ffi::air_spaces_loop_supported() } != 0;
    let flags = (if supported { 2 | if LOOP_ENABLED.load(Ordering::SeqCst) { 4 } else { 0 } } else { 0 })
        | if HOST_REQUESTED.load(Ordering::SeqCst) { 16 } else { 0 }
        | if RECONNECTING.load(Ordering::SeqCst) { 8 } else { 0 };
    AirControl {
        kind: 40,
        payload: vec![1, count, current, flags].into(),
        ..Default::default()
    }
}
pub(crate) struct StatePoll {
    last: AirControl,
    checked: Instant,
}
impl StatePoll {
    pub(crate) fn new(last: AirControl) -> Self {
        Self { last, checked: Instant::now() }
    }
    pub(crate) fn changed(&mut self) -> Option<AirControl> {
        if self.checked.elapsed() < Duration::from_millis(250) { return None; }
        self.checked = Instant::now();
        self.observe(state())
    }
    fn observe(&mut self, current: AirControl) -> Option<AirControl> {
        if self.last.payload == current.payload { return None; }
        self.last = current.clone();
        Some(current)
    }
}
pub(super) fn host_message(id: i32, message: AirControl) -> Option<AirControl> {
    match message.kind {
        41 => select_message(message),
        43 => loop_message(id, message),
        44 => swipe_message(id, message),
        45 if message.payload.as_ref() == [1] && HOST_REQUESTED.load(Ordering::SeqCst) => {
            if RECONNECTING.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
                RECONNECT_REQUESTED.store(true, Ordering::SeqCst);
            }
            Some(state())
        }
        _ => None,
    }
}
pub(crate) fn take_reconnect_request() -> bool {
    RECONNECT_REQUESTED.swap(false, Ordering::SeqCst)
}
pub(crate) fn reconnect_finished() {
    RECONNECTING.store(false, Ordering::SeqCst);
}
pub(crate) fn reset_reconnect() {
    RECONNECT_REQUESTED.store(false, Ordering::SeqCst);
    RECONNECTING.store(false, Ordering::SeqCst);
}
fn error_message(error: impl ToString) -> AirControl {
    AirControl { kind: 42, payload: error.to_string().into_bytes().into(), ..Default::default() }
}
fn select_message(message: AirControl) -> Option<AirControl> {
    if message.payload.len() != 2 || message.payload[0] != 1
        || !ACTIVE.load(Ordering::SeqCst)
        || message.payload[1] == 0
        || message.payload[1] as i32 > unsafe { ffi::air_spaces_slot_count() } {
        return None;
    }
    match native_result(unsafe { ffi::air_spaces_select(message.payload[1] as i32) }) {
        Ok(()) => Some(state()),
        Err(error) => Some(error_message(error)),
    }
}
fn loop_message(id: i32, message: AirControl) -> Option<AirControl> {
    if !LOOP_AVAILABLE {
        LOOP_ENABLED.store(false, Ordering::SeqCst);
        *HOST_SWIPE.lock().unwrap() = None;
        return Some(error_message("Space looping is unavailable while native trackpad swipes are active"));
    }
    if message.payload.len() != 2 || message.payload[0] != 1 || message.payload[1] > 1 { return None; }
    if !ACTIVE.load(Ordering::SeqCst) || !super::control::host_raw_owner(id)
        || unsafe { ffi::air_host_raw_supported() } == 0
        || unsafe { ffi::air_spaces_loop_supported() } == 0 {
        return Some(error_message("Loop requires an active three-Space raw contact session and a verified Space switch"));
    }
    let enabled = message.payload[1] != 0;
    LOOP_ENABLED.store(enabled, Ordering::SeqCst);
    if !enabled { *HOST_SWIPE.lock().unwrap() = None; }
    Some(state())
}
fn decode_swipe(payload: &[u8]) -> Option<(u8, i32, u64)> {
    if payload.len() != 11 || payload[0] != 1 { return None; }
    let phase = payload[1];
    let direction = payload[2] as i8 as i32;
    if !matches!((phase, direction), (1, 0) | (2, -1) | (2, 1) | (3, 0)) { return None; }
    let token = u64::from_le_bytes(payload[3..11].try_into().ok()?);
    if token == 0 { return None; }
    Some((phase, direction, token))
}
fn boundary_wrap(start: i32, current: i32, direction: i32, age: Duration) -> bool {
    age <= Duration::from_secs(3) && start == current
        && matches!((start, direction), (1, -1) | (3, 1))
}
fn swipe_message(id: i32, message: AirControl) -> Option<AirControl> {
    if !LOOP_AVAILABLE {
        *HOST_SWIPE.lock().unwrap() = None;
        return None;
    }
    let (phase, direction, token) = decode_swipe(&message.payload)?;
    if !super::control::host_raw_owner(id) { return None; }
    if !ACTIVE.load(Ordering::SeqCst) || !LOOP_ENABLED.load(Ordering::SeqCst)
        || unsafe { ffi::air_host_raw_supported() } == 0
        || unsafe { ffi::air_spaces_loop_supported() } == 0 {
        *HOST_SWIPE.lock().unwrap() = None;
        return None;
    }
    match phase {
        1 => {
            if token <= HOST_LAST_SWIPE.load(Ordering::SeqCst) { return None; }
            HOST_LAST_SWIPE.store(token, Ordering::SeqCst);
            let starting_slot = unsafe { ffi::air_spaces_current_slot() };
            *HOST_SWIPE.lock().unwrap() = if (1..=3).contains(&starting_slot) {
                Some(HostSwipe { id, token, starting_slot, started: Instant::now() })
            } else { None };
            None
        }
        3 => { *HOST_SWIPE.lock().unwrap() = None; None }
        2 => {
            let pending = HOST_SWIPE.lock().unwrap().take()?;
            if pending.id != id || pending.token != token
                || !boundary_wrap(pending.starting_slot, unsafe { ffi::air_spaces_current_slot() }, direction, pending.started.elapsed()) {
                return None;
            }
            match unsafe { ffi::air_spaces_wrap_boundary(pending.starting_slot, direction) } {
                1 => Some(state()),
                0 => None,
                _ => Some(error_message("Loop could not switch to the opposite boundary Space")),
            }
        }
        _ => None,
    }
}
pub(super) fn host_disconnected(id: i32) {
    if !super::control::host_raw_owner(id) { return; }
    let mut swipe = HOST_SWIPE.lock().unwrap();
    if swipe.as_ref().is_some_and(|pending| pending.id == id) { *swipe = None; }
    HOST_LAST_SWIPE.store(0, Ordering::SeqCst);
    LOOP_ENABLED.store(false, Ordering::SeqCst);
}
fn decode_state(payload: &[u8]) -> Option<(u8, u8, u8)> {
    if payload.len() != 4 || payload[0] != 1
        || (payload[1] != 0 && !(3..=9).contains(&payload[1]))
        || payload[2] > payload[1] || payload[3] & !30 != 0 || (payload[3] & 4 != 0 && payload[3] & 2 == 0)
        || (payload[3] & 8 != 0 && payload[3] & 16 == 0)
        || (payload[1] == 0 && (payload[2] != 0 || payload[3] & 6 != 0))
        || (payload[3] & 6 != 0 && !(1..=3).contains(&payload[2])) {
        return None;
    }
    Some((payload[1], payload[2], payload[3]))
}
pub(super) fn client_message(message: AirControl) {
    if !requested() { return; }
    if message.kind == 42 {
        if message.payload.len() <= 4096 { super::error_status(&String::from_utf8_lossy(&message.payload)); }
    } else if let Some((count, current, flags)) = decode_state(&message.payload) {
        CLIENT_COUNT.store(count, Ordering::SeqCst);
        CLIENT_CURRENT.store(current, Ordering::SeqCst);
        CLIENT_FLAGS.store(flags, Ordering::SeqCst);
        publish_overlay();
    }
}
fn publish_overlay() {
    let count = CLIENT_COUNT.load(Ordering::SeqCst);
    let current = CLIENT_CURRENT.load(Ordering::SeqCst);
    let mut flags = CLIENT_FLAGS.load(Ordering::SeqCst);
    if !super::control::raw_supported() || unsafe { ffi::air_client_raw_supported() } == 0 { flags &= !6; }
    unsafe { ffi::air_overlay_state(count as i32, current as i32, flags as i32); }
}
pub(super) fn raw_ready() { publish_overlay(); }
pub(super) fn disconnected() {
    CLIENT_COUNT.store(0, Ordering::SeqCst);
    CLIENT_CURRENT.store(0, Ordering::SeqCst);
    CLIENT_FLAGS.store(0, Ordering::SeqCst);
    *CLIENT_SWIPE.lock().unwrap() = None;
    unsafe { ffi::air_overlay_state(0, 0, 0); }
}
pub(super) extern "C" fn loop_changed(enabled: i32) {
    if !LOOP_AVAILABLE { return; }
    super::shell::with_input_lock(|| {
        if !requested() || CLIENT_COUNT.load(Ordering::SeqCst) < 3
            || CLIENT_FLAGS.load(Ordering::SeqCst) & 2 == 0 || !super::control::raw_supported()
            || unsafe { ffi::air_client_raw_supported() } == 0
            || !super::shell::accept_input() { return; }
        send_control(43, vec![1, (enabled != 0) as u8]);
    });
}
pub(super) extern "C" fn space_swipe(phase: i32, finger_direction: i32, generation: u64) {
    let _ = super::shell::try_with_input_lock(|| space_swipe_locked(phase, finger_direction, generation));
}
fn space_swipe_locked(phase: i32, finger_direction: i32, generation: u64) {
    if !LOOP_AVAILABLE {
        *CLIENT_SWIPE.lock().unwrap() = None;
        return;
    }
    if !requested() || !super::control::raw_supported() || unsafe { ffi::air_client_raw_supported() } == 0
        || !super::shell::accept_input()
        || generation != unsafe { ffi::air_input_generation() }
        || CLIENT_COUNT.load(Ordering::SeqCst) < 3 || CLIENT_FLAGS.load(Ordering::SeqCst) & 4 == 0 {
        *CLIENT_SWIPE.lock().unwrap() = None;
        return;
    }
    let (token, direction) = match phase {
        1 if finger_direction == 0 => {
            let token = NEXT_SWIPE.fetch_add(1, Ordering::SeqCst);
            *CLIENT_SWIPE.lock().unwrap() = Some((generation, token));
            (token, 0)
        }
        2 if matches!(finger_direction, -1 | 1) => {
            let Some((saved_generation, token)) = CLIENT_SWIPE.lock().unwrap().take() else { return; };
            if saved_generation != generation { return; }
            // Finger left advances, finger right goes back; physical direction is pending verification.
            (token, -finger_direction)
        }
        3 => {
            let Some((saved_generation, token)) = CLIENT_SWIPE.lock().unwrap().take() else { return; };
            if saved_generation != generation { return; }
            (token, 0)
        }
        _ => return,
    };
    let mut payload = vec![1, phase as u8, direction as i8 as u8];
    payload.extend_from_slice(&token.to_le_bytes());
    send_control(44, payload);
}
fn send_control(kind: u32, payload: Vec<u8>) {
    if let Some(session) = SESSION.lock().unwrap().clone() {
        let mut message = Message::new();
        message.set_air_control(AirControl { kind, payload: payload.into(), ..Default::default() });
        session.send(Data::Message(message));
    }
}
pub(super) extern "C" fn choose(slot: i32) {
    if !requested() || !(1..=(CLIENT_COUNT.load(Ordering::SeqCst) as i32)).contains(&slot)
        || !super::shell::accept_input() { return; }
    if let Some(session) = SESSION.lock().unwrap().clone() {
        let mut message = Message::new();
        message.set_air_control(AirControl { kind: 41, payload: vec![1, slot as u8].into(), ..Default::default() });
        session.send(Data::Message(message));
    }
}
pub(super) extern "C" fn reconnect() {
    if !requested() || !super::shell::accept_input() { return; }
    send_control(45, vec![1]);
}

#[cfg(test)]
mod tests {
    use super::{AirControl, StatePoll};
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    #[test]
    fn native_dock_swipe_cannot_trigger_a_second_boundary_wrap() {
        let mut swipe = vec![1, 2, 255];
        swipe.extend_from_slice(&42_u64.to_le_bytes());
        assert_eq!(super::decode_swipe(&swipe), Some((2, -1, 42)));
        super::LOOP_ENABLED.store(true, Ordering::SeqCst);
        *super::CLIENT_SWIPE.lock().unwrap() = Some((7, 42));
        super::space_swipe_locked(2, 1, 7);
        assert!(super::CLIENT_SWIPE.lock().unwrap().is_none());
        let message = AirControl { kind: 44, payload: swipe.into(), ..Default::default() };
        assert!(super::swipe_message(1, message).is_none());
        assert!(super::HOST_SWIPE.lock().unwrap().is_none());
        let loop_request = AirControl { kind: 43, payload: vec![1, 1].into(), ..Default::default() };
        let error = super::loop_message(1, loop_request).unwrap();
        assert_eq!(error.kind, 42);
        assert!(!super::LOOP_ENABLED.load(Ordering::SeqCst));
    }

    #[test]
    fn remote_space_state_accepts_pinned_fullscreen_slots() {
        assert_eq!(super::decode_state(&[1,3,2,0]), Some((3,2,0)));
        assert_eq!(super::decode_state(&[1,3,2,2]), Some((3,2,2)));
        assert_eq!(super::decode_state(&[1,3,3,6]), Some((3,3,6)));
        assert_eq!(super::decode_state(&[1,4,4,0]), Some((4,4,0)));
        assert_eq!(super::decode_state(&[1,9,9,0]), Some((9,9,0)));
        assert_eq!(super::decode_state(&[1,4,2,6]), Some((4,2,6)));
        assert_eq!(super::decode_state(&[1,0,0,0]), Some((0,0,0)));
        assert_eq!(super::decode_state(&[1,0,0,16]), Some((0,0,16)));
        assert_eq!(super::decode_state(&[1,0,0,24]), Some((0,0,24)));
        assert_eq!(super::decode_state(&[1,3,1,16]), Some((3,1,16)));
        assert_eq!(super::decode_state(&[1,3,1,24]), Some((3,1,24)));
        for invalid in [&[1,2,1,0][..], &[1,0,1,0], &[1,0,0,2], &[1,3,0,2], &[1,3,4,0], &[1,4,5,0], &[1,10,1,0], &[1,4,4,2], &[1,9,9,6], &[1,3,1,8], &[1,3,1,4], &[1,3,1], &[2,3,1,0]] {
            assert_eq!(super::decode_state(invalid), None);
        }
        for invalid in [&[1,0,0,8][..], &[1,0,0,18], &[1,0,0,30]] {
            assert_eq!(super::decode_state(invalid), None);
        }
    }

    #[test]
    fn host_reload_is_advertised_and_queued_without_an_active_space() {
        super::begin_host_session(true);
        assert_eq!(super::state().payload.as_ref(), &[1, 0, 0, 16]);
        let request = AirControl { kind: 45, payload: vec![1].into(), ..Default::default() };
        let reply = super::host_message(1, request.clone()).unwrap();
        assert_eq!(reply.payload.as_ref(), &[1, 0, 0, 24]);
        assert!(super::take_reconnect_request());
        assert!(!super::take_reconnect_request());
        assert_eq!(super::host_message(1, request).unwrap().payload.as_ref(), &[1, 0, 0, 24]);
        super::reconnect_finished();
        assert_eq!(super::state().payload.as_ref(), &[1, 0, 0, 16]);
        super::end_host_session();
        assert_eq!(super::state().payload.as_ref(), &[1, 0, 0, 0]);
    }

    #[test]
    fn boundary_intent_requires_same_space_and_recent_matching_end() {
        assert!(super::boundary_wrap(1, 1, -1, Duration::from_millis(200)));
        assert!(super::boundary_wrap(3, 3, 1, Duration::from_secs(3)));
        for (start, current, direction, age) in [
            (2, 2, 1, Duration::from_millis(200)),
            (2, 3, 1, Duration::from_millis(200)),
            (1, 3, -1, Duration::from_millis(200)),
            (1, 1, 1, Duration::from_millis(200)),
            (3, 3, -1, Duration::from_millis(200)),
            (3, 3, 1, Duration::from_millis(3001)),
        ] {
            assert!(!super::boundary_wrap(start, current, direction, age));
        }
    }

    #[test]
    fn swipe_wire_intent_rejects_malformed_phase_direction_and_token() {
        let mut payload = vec![1, 2, 255];
        payload.extend_from_slice(&42_u64.to_le_bytes());
        assert_eq!(super::decode_swipe(&payload), Some((2, -1, 42)));
        payload[2] = 1;
        assert_eq!(super::decode_swipe(&payload), Some((2, 1, 42)));
        payload[2] = 0;
        assert_eq!(super::decode_swipe(&payload), None);
        payload[1] = 1;
        assert_eq!(super::decode_swipe(&payload), Some((1, 0, 42)));
        payload[3..11].fill(0);
        assert_eq!(super::decode_swipe(&payload), None);
    }

    #[test]
    fn current_space_updates_only_when_state_changes() {
        let state = |slot| AirControl {
            kind: 40, payload: vec![1, 3, slot, 0].into(), ..Default::default()
        };
        let mut poll = StatePoll::new(state(1));
        assert!(poll.observe(state(1)).is_none());
        assert_eq!(poll.observe(state(2)).unwrap().payload, state(2).payload);
        assert!(poll.observe(state(2)).is_none());
        assert_eq!(poll.observe(state(0)).unwrap().payload, state(0).payload);
    }
}
