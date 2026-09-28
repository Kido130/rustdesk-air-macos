use super::{ffi, NativeUi, EXACT};
use crate::{client::{Data, Interface}, ui_session_interface::Session};
use hbb_common::tokio;
use std::{
    sync::{atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering}, Arc, Condvar, Mutex},
    thread::JoinHandle,
    time::{Duration, Instant},
};

static FATAL: AtomicU8 = AtomicU8::new(0);
static CONNECTED: AtomicBool = AtomicBool::new(false);
static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);
static OVERFLOWED: AtomicBool = AtomicBool::new(false);
static PENDING_INPUT: AtomicUsize = AtomicUsize::new(0);
static INPUT_SEND_LOCK: Mutex<()> = Mutex::new(());
const MAX_PENDING_INPUT: usize = 256;
unsafe extern "C" { fn air_surface_hold_for_reconnect(); }
fn retain_surface_for_reconnect(was_connected: bool, reconnect: bool, stopping: bool, fatal: u8) -> bool {
    was_connected && reconnect && !stopping && fatal == 0
}
pub(super) fn with_input_lock<T>(f: impl FnOnce() -> T) -> T {
    let _guard = INPUT_SEND_LOCK.lock().unwrap();
    f()
}
pub(super) fn try_with_input_lock<T>(f: impl FnOnce() -> T) -> Option<T> {
    let _guard = INPUT_SEND_LOCK.try_lock().ok()?;
    Some(f())
}
fn queue_has_room(pending: usize) -> bool { pending < MAX_PENDING_INPUT }
fn decrement_pending() {
    let _ = PENDING_INPUT.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |pending| pending.checked_sub(1));
}
pub(super) fn input_dequeued(data: &Data) {
    use base::message_proto::message;
    let is_input = match data {
        Data::Message(packet) => match packet.union.as_ref() {
            Some(message::Union::MouseEvent(_)) | Some(message::Union::KeyEvent(_)) => true,
            Some(message::Union::AirControl(control)) => control.kind == 3,
            _ => false,
        },
        _ => false,
    };
    if is_input {
        super::control::trace_data("rust_ui_dequeued", data, "ok");
        decrement_pending();
    }
}

#[derive(Debug, Eq, PartialEq)]
enum Enqueue { Sent, Closed, Full }
fn enqueue_bounded(sender: &tokio::sync::mpsc::UnboundedSender<Data>, data: Data) -> Enqueue {
    if sender.is_closed() { return Enqueue::Closed; }
    if !queue_has_room(PENDING_INPUT.load(Ordering::SeqCst)) { return Enqueue::Full; }
    PENDING_INPUT.fetch_add(1, Ordering::SeqCst);
    if sender.send(data).is_err() {
        decrement_pending();
        Enqueue::Closed
    } else {
        Enqueue::Sent
    }
}

pub(super) fn fatal_security() {
    FATAL.store(1, Ordering::SeqCst);
    // Never leave a prior peer's image on screen after identity verification fails.
    unsafe { ffi::air_surface_clear(); }
}
pub(super) fn fatal_video() { FATAL.store(2, Ordering::SeqCst); }
pub(super) fn fatal_auth() { FATAL.store(3, Ordering::SeqCst); }
pub(super) fn mark_connected() {
    with_input_lock(|| {
        if !SHUTTING_DOWN.load(Ordering::SeqCst) && FATAL.load(Ordering::SeqCst) == 0 {
            CONNECTED.store(true, Ordering::SeqCst);
        }
    });
}
pub(super) fn shutting_down() -> bool { SHUTTING_DOWN.load(Ordering::SeqCst) }
pub(super) fn accept_input() -> bool {
    CONNECTED.load(Ordering::SeqCst) && !shutting_down() && FATAL.load(Ordering::SeqCst) == 0
}
fn overflow_once(
    flag: &AtomicBool,
    local_release: impl FnOnce(),
    remote_release: impl FnOnce(),
    close: impl FnOnce(),
) -> bool {
    if flag.swap(true, Ordering::SeqCst) { return false; }
    local_release();
    remote_release();
    close();
    true
}

pub(super) fn send_input(data: Data) { send_input_inner(data, None); }
pub(super) fn send_native_input(data: Data, generation: u64) {
    send_input_inner(data, Some(generation));
}
fn send_input_inner(data: Data, generation: Option<u64>) {
    if !accept_input() { super::control::trace_data("rust_send_drop", &data, "not_accepting"); return; }
    let _guard = INPUT_SEND_LOCK.lock().unwrap();
    if !accept_input() { super::control::trace_data("rust_send_drop", &data, "not_accepting_locked"); return; }
    if generation.is_some_and(|captured| captured != unsafe { ffi::air_input_generation() }) { super::control::trace_data("rust_send_drop", &data, "generation"); return; }
    let Some(session) = super::SESSION.lock().unwrap().clone() else { super::control::trace_data("rust_send_drop", &data, "no_session"); return; };
    {
        let sender = session.sender.read().unwrap();
        let Some(sender) = sender.as_ref() else { super::control::trace_data("rust_send_drop", &data, "no_sender"); return; };
        super::control::trace_data("rust_enqueue_attempt", &data, "ok");
        let trace = if super::control::input_trace() { Some(data.clone()) } else { None };
        match enqueue_bounded(sender, data) {
            Enqueue::Sent => { if let Some(data) = &trace { super::control::trace_data("rust_enqueued", data, "ok"); } return; },
            Enqueue::Closed => { if let Some(data) = &trace { super::control::trace_data("rust_send_drop", data, "closed"); } return; },
            Enqueue::Full => { if let Some(data) = &trace { super::control::trace_data("rust_send_drop", data, "full"); } }
        }
    }
    if overflow_once(&OVERFLOWED,
        || {
            CONNECTED.store(false, Ordering::SeqCst);
            unsafe { ffi::air_input_connected(0); }
        },
        || super::control::release_input(),
        || {
            super::control::disconnected_locked();
            session.send(Data::Close);
        },
    ) {
        super::error_status("RustDesk Air — remote input paused after a slow connection");
    }
}
pub(super) fn clear_security_failure() {
    let _ = FATAL.compare_exchange(1, 0, Ordering::SeqCst, Ordering::SeqCst);
}
pub(super) fn fatal_reason() -> u8 { FATAL.load(Ordering::SeqCst) }
pub(super) fn stop_for_input_refusal(reason: &str) {
    stop_for_input_refusal_if(reason, || true);
}
pub(super) fn stop_for_input_refusal_if(reason: &str, only_if: impl FnOnce() -> bool) {
    let stopped = with_input_lock(|| {
        if SHUTTING_DOWN.load(Ordering::SeqCst) || FATAL.load(Ordering::SeqCst) == 6 || !only_if() { return false; }
        let _ = FATAL.compare_exchange(0, 6, Ordering::SeqCst, Ordering::SeqCst);
        super::control::release_input();
        CONNECTED.store(false, Ordering::SeqCst);
        super::control::disconnected_locked();
        if let Some(session) = super::SESSION.lock().unwrap().clone() { session.send(Data::Close); }
        true
    });
    if stopped {
        let detail: String = reason.chars().take(512).map(|c| if c.is_control() { ' ' } else { c }).collect();
        let detail = if detail.trim().is_empty() { "Host refused native input" } else { detail.trim() };
        super::error_status(&format!("RustDesk Air — {detail}; reconnect stopped"));
    }
}
pub(super) fn handle_unavailable_auth_prompt(msgtype: &str) -> bool {
    let message = match msgtype {
        "input-password" | "re-input-password" =>
            "RustDesk Air — paired password was rejected; import a fresh pairing file",
        "input-2fa" =>
            "RustDesk Air — host requires two-factor approval; this pairing cannot answer it",
        _ => return false,
    };
    if msgtype == "input-2fa" { FATAL.store(4, Ordering::SeqCst); }
    else { fatal_auth(); }
    super::control::disconnected();
    super::error_status(message);
    if let Some(session) = super::SESSION.lock().unwrap().clone() {
        session.send(Data::Close);
    }
    true
}
pub(super) fn record_ui_error(message: &str) {
    let lower = message.to_ascii_lowercase();
    if lower.contains("remote spaces unavailable") {
        FATAL.store(5, Ordering::SeqCst);
    } else if ["password", "authentication", "permission denied", "access denied"]
        .iter().any(|word| lower.contains(word)) {
        fatal_auth();
    } else if ["signed identity", "paired host identity", "encryption required", "public key"]
        .iter().any(|word| lower.contains(word)) {
        fatal_security();
    } else if ["hardware decoder", "unsupported video codec", "unrequested hardware codec"]
        .iter().any(|word| lower.contains(word)) {
        fatal_video();
    }
}

fn retry_delay(failures: u32) -> Duration {
    Duration::from_millis((250u64 << failures.min(7)).min(30_000))
}

pub(super) struct Supervisor {
    exit: Arc<(Mutex<bool>, Condvar)>,
    session: Session<NativeUi>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

fn wait_worker(worker: &Mutex<Option<JoinHandle<()>>>, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    loop {
        let mut slot = worker.lock().unwrap();
        if slot.as_ref().is_some_and(JoinHandle::is_finished) {
            let Some(finished) = slot.take() else { return true; };
            drop(slot);
            if finished.join().is_err() { super::error_status("RustDesk Air — session worker stopped unexpectedly"); }
            return true;
        }
        if slot.is_none() { return true; }
        drop(slot);
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() { return false; }
        std::thread::sleep(remaining.min(Duration::from_millis(10)));
    }
}

impl Supervisor {
    pub(super) fn start(session: Session<NativeUi>, reconnect: bool) -> Self {
        FATAL.store(0, Ordering::SeqCst);
        CONNECTED.store(false, Ordering::SeqCst);
        SHUTTING_DOWN.store(false, Ordering::SeqCst);
        OVERFLOWED.store(false, Ordering::SeqCst);
        PENDING_INPUT.store(0, Ordering::SeqCst);
        let exit = Arc::new((Mutex::new(false), Condvar::new()));
        let worker_exit = Arc::clone(&exit);
        let worker_session = session.clone();
        let worker = std::thread::spawn(move || {
            let mut failures = 0;
            loop {
                if *worker_exit.0.lock().unwrap() { break; }
                OVERFLOWED.store(false, Ordering::SeqCst);
                PENDING_INPUT.store(0, Ordering::SeqCst);
                let round = worker_session.connection_round_state.lock().unwrap().new_round();
                crate::ui_session_interface::io_loop(worker_session.clone(), round);
                PENDING_INPUT.store(0, Ordering::SeqCst);
                let was_connected = CONNECTED.swap(false, Ordering::SeqCst);
                super::control::disconnected();
                EXACT.lock().unwrap().invalidate();
                unsafe { ffi::air_decoder_reset(); }
                let stopping=*worker_exit.0.lock().unwrap();
                let fatal = FATAL.load(Ordering::SeqCst);
                if retain_surface_for_reconnect(was_connected,reconnect,stopping,fatal) {
                    unsafe { air_surface_hold_for_reconnect(); }
                } else {
                    unsafe { ffi::air_surface_clear(); }
                }
                if stopping || !reconnect { break; }
                if fatal != 0 {
                    if fatal != 6 {
                        super::error_status(match fatal {
                            1 => "RustDesk Air — paired host identity could not be verified; reconnect stopped",
                            2 => "RustDesk Air — video decoder failed; reconnect stopped",
                            4 => "RustDesk Air — host requires two-factor approval; reconnect stopped",
                            5 => "RustDesk Air — remote Spaces unavailable on host; reconnect stopped",
                            _ => "RustDesk Air — authentication failed; reconnect stopped",
                        });
                    }
                    break;
                }
                if was_connected { failures = 0; }
                super::status("RustDesk Air — connection lost; reconnecting securely");
                let delay = retry_delay(failures);
                failures = failures.saturating_add(1);
                let guard = worker_exit.0.lock().unwrap();
                let (guard, _) = worker_exit.1.wait_timeout_while(guard, delay, |stopped| !*stopped).unwrap();
                if *guard { break; }
                worker_session.reconnect_count.fetch_add(1, Ordering::SeqCst);
            }
        });
        Self { exit, session, worker: Mutex::new(Some(worker)) }
    }

    pub(super) fn shutdown(&self) {
        let mut stopped = self.exit.0.lock().unwrap();
        if *stopped { return; }
        *stopped = true;
        drop(stopped);
        let _guard = INPUT_SEND_LOCK.lock().unwrap();
        SHUTTING_DOWN.store(true, Ordering::SeqCst);
        self.exit.1.notify_all();
        let overflowed = OVERFLOWED.load(Ordering::SeqCst);
        if !overflowed { super::control::release_input(); }
        CONNECTED.store(false, Ordering::SeqCst);
        super::control::disconnected_locked();
        if !overflowed { self.session.send(Data::Close); }
        unsafe { ffi::air_surface_clear(); }
    }

    pub(super) fn wait_stopped(&self, limit: Duration) -> bool {
        wait_worker(&self.worker, limit)
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) { self.shutdown(); }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{message, AirControl};
    static TEST_LOCK: Mutex<()> = Mutex::new(());
    #[test]
    fn surface_retention_only_for_short_ordinary_reconnect() {
        assert!(retain_surface_for_reconnect(true,true,false,0));
        for (connected,reconnect,stopping,fatal) in [
            (false,true,false,0), (true,false,false,0), (true,true,true,0),
            (true,true,false,1), (true,true,false,2), (true,true,false,6),
        ] {
            assert!(!retain_surface_for_reconnect(connected,reconnect,stopping,fatal));
        }
    }
    struct InputTestRestore {
        session: Option<Session<NativeUi>>,
        connected: bool,
        shutting_down: bool,
        overflowed: bool,
        pending: usize,
        fatal: u8,
        requested: bool,
    }
    impl Drop for InputTestRestore {
        fn drop(&mut self) {
            super::super::control::disconnected();
            *super::super::SESSION.lock().unwrap() = self.session.take();
            CONNECTED.store(self.connected, Ordering::SeqCst);
            SHUTTING_DOWN.store(self.shutting_down, Ordering::SeqCst);
            OVERFLOWED.store(self.overflowed, Ordering::SeqCst);
            PENDING_INPUT.store(self.pending, Ordering::SeqCst);
            FATAL.store(self.fatal, Ordering::SeqCst);
            super::super::control::configure(self.requested);
        }
    }
    #[test]
    fn queued_native_callbacks_cannot_enter_a_new_connection() {
        let _guard = TEST_LOCK.lock().unwrap();
        let restore = InputTestRestore {
            session: super::super::SESSION.lock().unwrap().take(),
            connected: CONNECTED.swap(false, Ordering::SeqCst),
            shutting_down: SHUTTING_DOWN.swap(false, Ordering::SeqCst),
            overflowed: OVERFLOWED.swap(false, Ordering::SeqCst),
            pending: PENDING_INPUT.swap(0, Ordering::SeqCst),
            fatal: FATAL.swap(0, Ordering::SeqCst),
            requested: super::super::control::requested(),
        };
        super::super::control::configure(true);
        let session = Session::<NativeUi>::default();
        let (old_sender, mut old_receiver) = tokio::sync::mpsc::unbounded_channel();
        *session.sender.write().unwrap() = Some(old_sender);
        *super::super::SESSION.lock().unwrap() = Some(session.clone());
        let ready = || AirControl { kind: 2, payload: vec![1, 0].into(), ..Default::default() };
        mark_connected();
        super::super::control::client_message(ready());
        let old_generation = unsafe { ffi::air_input_generation() };
        super::super::control::disconnected();
        CONNECTED.store(false, Ordering::SeqCst);
        let (new_sender, mut new_receiver) = tokio::sync::mpsc::unbounded_channel();
        *session.sender.write().unwrap() = Some(new_sender);
        mark_connected();
        super::super::control::client_message(ready());
        let new_generation = unsafe { ffi::air_input_generation() };
        assert_ne!(old_generation, new_generation);
        let input = [1_u8, 2, 3];
        super::super::control::input_event(input.as_ptr(), input.len(), old_generation);
        super::super::control::native_release_input(old_generation);
        assert!(old_receiver.try_recv().is_err());
        assert!(new_receiver.try_recv().is_err());
        super::super::control::input_event(input.as_ptr(), input.len(), new_generation);
        super::super::control::native_release_input(new_generation);
        let packet = new_receiver.try_recv().expect("current native event");
        match &packet {
            Data::Message(message) => match message.union.as_ref() {
                Some(message::Union::AirControl(control)) => {
                    assert_eq!(control.kind, 3);
                    assert_eq!(&control.payload[..], &input);
                }
                _ => panic!("expected native event"),
            },
            _ => panic!("expected message"),
        }
        input_dequeued(&packet);
        match new_receiver.try_recv().expect("current native release") {
            Data::Message(message) => match message.union.as_ref() {
                Some(message::Union::AirControl(control)) => assert_eq!(control.kind, 4),
                _ => panic!("expected native release"),
            },
            _ => panic!("expected message"),
        }
        assert!(new_receiver.try_recv().is_err());
        drop(restore);
    }
    #[test]
    fn reconnect_backoff_is_bounded() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert_eq!(retry_delay(0), Duration::from_millis(250));
        assert_eq!(retry_delay(2), Duration::from_secs(1));
        assert_eq!(retry_delay(100), Duration::from_secs(30));
    }
    #[test]
    fn native_cancel_callback_does_not_wait_on_shutdown_input_lock() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert_eq!(try_with_input_lock(|| 42), Some(42));
        with_input_lock(|| assert_eq!(try_with_input_lock(|| 42), None));
    }
    #[test]
    fn unavailable_remote_spaces_is_fatal() {
        let _guard = TEST_LOCK.lock().unwrap();
        FATAL.store(0, Ordering::SeqCst);
        record_ui_error("Connection Error: Remote Spaces unavailable: no independent desktops");
        assert_eq!(fatal_reason(), 5);
        FATAL.store(0, Ordering::SeqCst);
    }
    #[test]
    fn input_is_gated_until_authenticated_and_after_disconnect() {
        let _guard = TEST_LOCK.lock().unwrap();
        let previous_fatal = FATAL.swap(0, Ordering::SeqCst);
        let previous_shutdown = SHUTTING_DOWN.swap(false, Ordering::SeqCst);
        CONNECTED.store(false, Ordering::SeqCst);
        assert!(!accept_input());
        mark_connected();
        assert!(accept_input());
        CONNECTED.store(false, Ordering::SeqCst);
        assert!(!accept_input());
        FATAL.store(previous_fatal, Ordering::SeqCst);
        SHUTTING_DOWN.store(previous_shutdown, Ordering::SeqCst);
    }
    #[test]
    fn late_ready_cannot_reopen_native_input_after_shutdown() {
        let _guard = TEST_LOCK.lock().unwrap();
        let restore = InputTestRestore {
            session: super::super::SESSION.lock().unwrap().take(),
            connected: CONNECTED.swap(false, Ordering::SeqCst),
            shutting_down: SHUTTING_DOWN.swap(false, Ordering::SeqCst),
            overflowed: OVERFLOWED.swap(false, Ordering::SeqCst),
            pending: PENDING_INPUT.swap(0, Ordering::SeqCst),
            fatal: FATAL.swap(0, Ordering::SeqCst),
            requested: super::super::control::requested(),
        };
        super::super::control::configure(true);
        mark_connected();
        SHUTTING_DOWN.store(true, Ordering::SeqCst);
        let generation = unsafe { ffi::air_input_generation() };
        super::super::control::client_message(AirControl {
            kind: 2, payload: vec![1, 1].into(), ..Default::default()
        });
        assert_eq!(unsafe { ffi::air_input_generation() }, generation);
        assert!(!accept_input());
        drop(restore);
    }
    #[test]
    fn host_input_refusal_releases_then_closes_without_new_hello() {
        let _guard = TEST_LOCK.lock().unwrap();
        let restore = InputTestRestore {
            session: super::super::SESSION.lock().unwrap().take(),
            connected: CONNECTED.swap(false, Ordering::SeqCst),
            shutting_down: SHUTTING_DOWN.swap(false, Ordering::SeqCst),
            overflowed: OVERFLOWED.swap(false, Ordering::SeqCst),
            pending: PENDING_INPUT.swap(0, Ordering::SeqCst),
            fatal: FATAL.swap(0, Ordering::SeqCst),
            requested: super::super::control::requested(),
        };
        super::super::control::configure(true);
        let session = Session::<NativeUi>::default();
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        *session.sender.write().unwrap() = Some(sender);
        *super::super::SESSION.lock().unwrap() = Some(session);
        mark_connected();
        super::super::control::client_message(AirControl {
            kind: 2, payload: vec![1, 0].into(), ..Default::default()
        });
        stop_for_input_refusal_if("stale raw handshake", || false);
        assert!(accept_input());
        assert!(receiver.try_recv().is_err());
        super::super::control::client_message(AirControl {
            kind: 5, payload: b"Host native input refused".to_vec().into(), ..Default::default()
        });
        assert_eq!(fatal_reason(), 6);
        assert!(!accept_input());
        let generation = unsafe { ffi::air_input_generation() };
        mark_connected();
        super::super::control::client_message(AirControl {
            kind: 2, payload: vec![1, 0].into(), ..Default::default()
        });
        assert_eq!(unsafe { ffi::air_input_generation() }, generation);
        assert!(!accept_input());
        match receiver.try_recv().expect("release before close") {
            Data::Message(message) => match message.union.as_ref() {
                Some(message::Union::AirControl(control)) => assert_eq!(control.kind, 4),
                _ => panic!("expected release"),
            },
            _ => panic!("expected release"),
        }
        assert!(matches!(receiver.try_recv(), Ok(Data::Close)));
        super::super::control::hello();
        assert!(receiver.try_recv().is_err());
        drop(restore);
    }
    #[test]
    fn shutdown_releases_remote_input_before_close() {
        let _guard = TEST_LOCK.lock().unwrap();
        let restore = InputTestRestore {
            session: super::super::SESSION.lock().unwrap().take(),
            connected: CONNECTED.swap(false, Ordering::SeqCst),
            shutting_down: SHUTTING_DOWN.swap(false, Ordering::SeqCst),
            overflowed: OVERFLOWED.swap(false, Ordering::SeqCst),
            pending: PENDING_INPUT.swap(0, Ordering::SeqCst),
            fatal: FATAL.swap(0, Ordering::SeqCst),
            requested: super::super::control::requested(),
        };
        super::super::control::configure(true);
        let session = Session::<NativeUi>::default();
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        *session.sender.write().unwrap() = Some(sender);
        *super::super::SESSION.lock().unwrap() = Some(session.clone());
        mark_connected();
        super::super::control::client_message(AirControl {
            kind: 2, payload: vec![1, 0].into(), ..Default::default()
        });
        let supervisor = Supervisor {
            exit: Arc::new((Mutex::new(false), Condvar::new())),
            session,
            worker: Mutex::new(None),
        };
        supervisor.shutdown();
        match receiver.try_recv().expect("release before close") {
            Data::Message(message) => match message.union.as_ref() {
                Some(message::Union::AirControl(control)) => assert_eq!(control.kind, 4),
                _ => panic!("expected release"),
            },
            _ => panic!("expected release"),
        }
        assert!(matches!(receiver.try_recv(), Ok(Data::Close)));
        let generation = unsafe { ffi::air_input_generation() };
        super::super::control::client_message(AirControl {
            kind: 2, payload: vec![1, 0].into(), ..Default::default()
        });
        assert_eq!(unsafe { ffi::air_input_generation() }, generation);
        assert!(receiver.try_recv().is_err());
        drop(supervisor);
        drop(restore);
    }
    #[test]
    fn saturated_queue_releases_locally_then_remotely_and_closes_once() {
        let _guard = TEST_LOCK.lock().unwrap();
        let flag = AtomicBool::new(false);
        let local_grab = AtomicBool::new(true);
        let actions = Mutex::new(Vec::new());
        assert!(queue_has_room(255));
        assert!(!queue_has_room(256));
        assert!(overflow_once(&flag,
            || { local_grab.store(false, Ordering::SeqCst); actions.lock().unwrap().push("local"); },
            || actions.lock().unwrap().push("remote"),
            || actions.lock().unwrap().push("close"),
        ));
        assert!(!local_grab.load(Ordering::SeqCst));
        assert_eq!(*actions.lock().unwrap(), ["local", "remote", "close"]);
        assert!(!overflow_once(&flag, || panic!("repeated local release"),
            || panic!("repeated remote release"), || panic!("repeated close")));
    }
    #[test]
    fn bounded_live_input_queue_tracks_actual_dequeues() {
        let _guard = TEST_LOCK.lock().unwrap();
        use base::message_proto::{Message, MouseEvent};
        fn mouse() -> Data {
            let mut message = Message::new();
            message.set_mouse_event(MouseEvent::default());
            Data::Message(message)
        }
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        PENDING_INPUT.store(0, Ordering::SeqCst);
        for _ in 0..MAX_PENDING_INPUT {
            assert_eq!(enqueue_bounded(&sender, mouse()), Enqueue::Sent);
        }
        assert_eq!(receiver.len(), MAX_PENDING_INPUT);
        assert_eq!(enqueue_bounded(&sender, mouse()), Enqueue::Full);
        let first = receiver.try_recv().unwrap();
        input_dequeued(&first);
        assert_eq!(enqueue_bounded(&sender, mouse()), Enqueue::Sent);
        assert_eq!(receiver.len(), MAX_PENDING_INPUT);
        while let Ok(data) = receiver.try_recv() {
            input_dequeued(&data);
        }
        assert_eq!(PENDING_INPUT.load(Ordering::SeqCst), 0);
        input_dequeued(&mouse());
        assert_eq!(PENDING_INPUT.load(Ordering::SeqCst), 0);
    }
    #[test]
    fn shutdown_interrupts_wait() {
        let _guard = TEST_LOCK.lock().unwrap();
        let exit = Arc::new((Mutex::new(false), Condvar::new()));
        let worker_exit = Arc::clone(&exit);
        let worker = std::thread::spawn(move || {
            let guard = worker_exit.0.lock().unwrap();
            let (guard, _) = worker_exit.1.wait_timeout_while(guard, Duration::from_secs(30), |stopped| !*stopped).unwrap();
            *guard
        });
        *exit.0.lock().unwrap() = true;
        exit.1.notify_all();
        assert!(worker.join().unwrap());
    }
    #[test]
    fn worker_wait_is_bounded_then_joins_after_exit() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (sender, receiver) = std::sync::mpsc::channel();
        let worker = Mutex::new(Some(std::thread::spawn(move || {
            receiver.recv().unwrap();
        })));
        assert!(!wait_worker(&worker, Duration::from_millis(20)));
        assert!(worker.lock().unwrap().is_some());
        sender.send(()).unwrap();
        assert!(wait_worker(&worker, Duration::from_secs(1)));
        assert!(worker.lock().unwrap().is_none());
    }
}
