//! Bounded Host timing evidence for video delivery and acknowledgements.
//! Air-side timing remains opt-in to avoid extra work on the low-power client.
//! No frame bytes, keyboard data, window titles, or network addresses are retained.
use std::{
    collections::VecDeque,
    ffi::OsStr,
    sync::{atomic::{AtomicU64, Ordering}, Mutex, OnceLock},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const LIMIT: usize = 128;
static ENABLED: OnceLock<bool> = OnceLock::new();
static EVENTS: OnceLock<Mutex<VecDeque<Event>>> = OnceLock::new();
static DROPPED: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, serde::Serialize)]
struct Event {
    unix_ms: u64,
    stage: &'static str,
    bytes: usize,
    duration_us: u64,
    peer: i32,
    ok: bool,
}

fn requested(value: Option<&OsStr>) -> bool {
    value == Some(OsStr::new("1"))
}

pub(crate) fn enabled() -> bool {
    trace_active(super::host_enabled(),
        *ENABLED.get_or_init(|| requested(std::env::var_os("RUSTDESK_AIR_ACK_TRACE").as_deref())))
}

fn trace_active(host: bool, requested: bool) -> bool {
    host || requested
}

fn keep(queue: &mut VecDeque<Event>, event: Event) {
    if queue.len() == LIMIT { queue.pop_front(); }
    queue.push_back(event);
}

pub(crate) fn record(stage: &'static str, bytes: usize, duration: Duration, peer: i32, ok: bool) {
    if !enabled() { return; }
    let event = Event {
        unix_ms: SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default()
            .as_millis().min(u64::MAX as u128) as u64,
        stage, bytes,
        duration_us: duration.as_micros().min(u64::MAX as u128) as u64,
        peer, ok,
    };
    let Some(queue) = EVENTS.get_or_init(|| Mutex::new(VecDeque::with_capacity(LIMIT))).try_lock().ok() else {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return;
    };
    let mut queue = queue;
    keep(&mut queue, event);
}

pub(crate) fn dump(reason: &'static str) {
    if !enabled() { return; }
    let events = EVENTS.get_or_init(|| Mutex::new(VecDeque::with_capacity(LIMIT)))
        .lock().unwrap().iter().cloned().collect::<Vec<_>>();
    eprintln!("air_ack_trace={}", serde_json::json!({
        "schema": 1, "reason": reason, "limit": LIMIT,
        "dropped": DROPPED.load(Ordering::Relaxed), "events": events,
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_trace_is_always_ready_and_air_trace_is_opt_in() {
        assert!(!requested(None));
        assert!(!requested(Some(OsStr::new("true"))));
        assert!(requested(Some(OsStr::new("1"))));
        assert!(trace_active(true, false));
        assert!(!trace_active(false, false));
        assert!(trace_active(false, true));
        let mut queue = VecDeque::new();
        for n in 0..LIMIT + 3 {
            keep(&mut queue, Event { unix_ms: n as u64, stage: "test", bytes: 0,
                duration_us: 0, peer: 0, ok: true });
        }
        assert_eq!(queue.len(), LIMIT);
        assert_eq!(queue.front().unwrap().unix_ms, 3);
        assert_eq!(queue.back().unwrap().unix_ms, (LIMIT + 2) as u64);
        let encoded = serde_json::to_string(&queue[0]).unwrap();
        for field in ["unix_ms", "stage", "bytes", "duration_us", "peer", "ok"] {
            assert!(encoded.contains(field));
        }
    }
}
