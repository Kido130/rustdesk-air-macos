//! A bounded native-only video window. Acknowledgements are ordered per peer.
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{mpsc::{self, Receiver, SyncSender}, Mutex},
    time::{Duration, Instant},
};

static NOTIFIER: Mutex<Option<SyncSender<(i32, bool)>>> = Mutex::new(None);
static FEEDBACK_NOTIFIER: Mutex<Option<SyncSender<(i32, Feedback)>>> = Mutex::new(None);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Feedback {
    pub sequence: u64,
    pub received_video: u64,
    pub unique_presented_video: u64,
    pub drawable_drops: u64,
}

impl Feedback {
    pub(crate) fn decode(payload: &[u8]) -> Option<Self> {
        if payload.len() != 33 || payload[0] != 1 { return None; }
        let field = |offset| Some(u64::from_le_bytes(payload[offset..offset + 8].try_into().ok()?));
        let report = Self {
            sequence: field(1)?,
            received_video: field(9)?,
            unique_presented_video: field(17)?,
            drawable_drops: field(25)?,
        };
        (report.sequence != 0 && report.unique_presented_video <= report.received_video
            && report.received_video <= 1_000_000_000 && report.drawable_drops <= 1_000_000_000)
            .then_some(report)
    }
}

pub(crate) fn notify_feedback(id: i32, payload: &[u8]) -> bool {
    if id == 0 { return false; }
    let Some(report) = Feedback::decode(payload) else { return false; };
    let sender = FEEDBACK_NOTIFIER.lock().unwrap();
    sender.as_ref().is_some_and(|sender| sender.try_send((id, report)).is_ok())
}

pub(crate) fn notify(id: i32, disconnected: bool) -> bool {
    let sender = NOTIFIER.lock().unwrap();
    let Some(sender) = sender.as_ref() else { return false };
    sender.try_send((id, disconnected)).is_ok()
}

struct Pending {
    peers: HashSet<i32>,
    deadline: Instant,
}

pub(crate) struct Window {
    receiver: Receiver<(i32, bool)>,
    feedback_receiver: Receiver<(i32, Feedback)>,
    last_feedback: HashMap<i32, (Feedback, Instant)>,
    known_peers: HashSet<i32>,
    pending: VecDeque<Pending>,
}

impl Window {
    pub fn pending_count(&self) -> usize { self.pending.len() }
    pub(crate) fn peer_count(&self) -> usize { self.known_peers.len() }
    pub fn new() -> Self {
        let (sender, receiver) = mpsc::sync_channel(128);
        let (feedback_sender, feedback_receiver) = mpsc::sync_channel(128);
        *NOTIFIER.lock().unwrap() = Some(sender);
        *FEEDBACK_NOTIFIER.lock().unwrap() = Some(feedback_sender);
        Self { receiver, feedback_receiver, last_feedback: HashMap::new(), known_peers: HashSet::new(), pending: VecDeque::new() }
    }
    pub fn sent(&mut self, peers: HashSet<i32>, timeout: Duration) {
        if !peers.is_empty() {
            self.known_peers.extend(peers.iter().copied());
            self.pending.push_back(Pending { peers, deadline: Instant::now() + timeout });
        }
    }
    fn acknowledge(&mut self, id: i32, disconnected: bool) {
        if disconnected { self.last_feedback.remove(&id); self.known_peers.remove(&id); }
        let mut matched = false;
        for frame in &mut self.pending {
            if frame.peers.remove(&id) {
                matched = true;
                if !disconnected { break; }
            }
        }
        while self.pending.front().is_some_and(|p| p.peers.is_empty()) {
            self.pending.pop_front();
        }
        super::ack_trace::record("host_ack_applied", 0, Duration::ZERO, id, matched);
    }
    pub(crate) fn take_feedback(&mut self) -> Vec<(i32, Feedback)> {
        while let Ok((id, closed)) = self.receiver.try_recv() { self.acknowledge(id, closed); }
        let mut accepted = Vec::new();
        while let Ok((id, report)) = self.feedback_receiver.try_recv() {
            if !self.known_peers.contains(&id) { continue; }
            let now = Instant::now();
            let valid = self.last_feedback.get(&id).map_or(true, |(old, when)| {
                if report.sequence <= old.sequence
                    || report.received_video < old.received_video
                    || report.unique_presented_video < old.unique_presented_video
                    || report.drawable_drops < old.drawable_drops { return false; }
                let seconds = now.duration_since(*when).as_secs_f64();
                let frame_budget = (seconds * 240.0).ceil() as u64 + 16;
                report.received_video - old.received_video <= frame_budget
                    && report.unique_presented_video - old.unique_presented_video <= frame_budget
            });
            if valid {
                self.last_feedback.insert(id, (report, now));
                accepted.push((id, report));
            }
        }
        accepted
    }
    pub fn ready(&mut self, limit: usize) -> Result<bool, &'static str> {
        while let Ok((id, closed)) = self.receiver.try_recv() { self.acknowledge(id, closed); }
        if self.pending.front().is_some_and(|p| Instant::now() >= p.deadline) {
            let oldest_peers = self.pending.front().map_or(0, |frame| frame.peers.len());
            eprintln!("air_video_flow_timeout pending_frames={} oldest_unacked_peers={}",
                self.pending.len(), oldest_peers);
            super::ack_trace::dump("host_flow_ack_timeout");
            return Err("Native video acknowledgement timed out");
        }
        if self.pending.len() < limit { return Ok(true); }
        if let Ok((id, closed)) = self.receiver.recv_timeout(Duration::from_millis(25)) {
            self.acknowledge(id, closed);
        }
        Ok(self.pending.len() < limit)
    }
}

impl Drop for Window {
    fn drop(&mut self) {
        *NOTIFIER.lock().unwrap() = None;
        *FEEDBACK_NOTIFIER.lock().unwrap() = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn each_ack_releases_one_frame_and_disconnect_releases_all() {
        let mut window = Window::new();
        for _ in 0..3 { window.sent(HashSet::from([7, 8]), Duration::from_secs(5)); }
        assert!(!window.ready(3).unwrap());
        assert!(notify(7, false));
        assert!(notify(7, false));
        assert!(notify(8, false));
        assert!(window.ready(3).unwrap());
        assert_eq!(window.pending.len(), 2);
        assert!(notify(8, true));
        window.ready(3).unwrap();
        assert_eq!(window.pending.len(), 1);
        assert!(notify(7, false));
        window.ready(3).unwrap();
        assert!(window.pending.is_empty());
        window.sent(HashSet::from([9]), Duration::ZERO);
        assert!(window.ready(3).is_err());
    }

    #[test]
    fn feedback_requires_known_peer_and_monotonic_counters() {
        let mut window = Window::new();
        let payload = |sequence: u64, received: u64, presented: u64, dropped: u64| {
            let mut bytes = vec![1];
            for value in [sequence, received, presented, dropped] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
            bytes
        };
        assert!(!notify_feedback(7, &[1, 2]));
        assert!(notify_feedback(7, &payload(1, 3, 2, 0)));
        assert!(window.take_feedback().is_empty());
        window.sent(HashSet::from([7]), Duration::from_secs(5));
        assert!(notify_feedback(7, &payload(1, 3, 2, 0)));
        assert_eq!(window.take_feedback()[0].1.unique_presented_video, 2);
        assert!(notify_feedback(7, &payload(1, 4, 3, 0)));
        assert!(notify_feedback(7, &payload(2, 4, 1, 0)));
        assert!(window.take_feedback().is_empty());
        assert!(notify_feedback(7, &payload(2, 5, 4, 1)));
        assert_eq!(window.take_feedback()[0].1.received_video, 5);
        assert!(notify(7, true));
        window.ready(3).unwrap();
        assert!(notify_feedback(7, &payload(3, 6, 5, 2)));
        assert!(window.take_feedback().is_empty());
    }
}
