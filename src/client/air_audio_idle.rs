//! Air-only CoreAudio idle policy. This runs only when an encoded audio packet arrives;
//! it adds no timer or polling to the low-power client.

use std::time::{Duration, Instant};

const MIN_SILENCE: Duration = Duration::from_millis(500);
const DRAIN_TAIL: Duration = Duration::from_millis(20);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Action {
    Queue,
    DropZero,
    Pause,
    Resume,
}

#[derive(Default)]
pub(super) struct AirAudioIdle {
    silence_since: Option<Instant>,
    empty_since: Option<Instant>,
    paused: bool,
}

impl AirAudioIdle {
    pub(super) fn observe(&mut self, now: Instant, source_silent: bool, ring_empty: bool) -> Action {
        if !source_silent {
            self.silence_since = None;
            self.empty_since = None;
            return if self.paused { Action::Resume } else { Action::Queue };
        }
        if self.paused {
            return Action::DropZero;
        }
        let silence_since = *self.silence_since.get_or_insert(now);
        // Preserve decoded Opus tails through short digital-silence gaps. The
        // authoritative state is the Host's source PCM before Opus encoding.
        if now.duration_since(silence_since) < MIN_SILENCE {
            return Action::Queue;
        }
        if !ring_empty {
            self.empty_since = None;
            return Action::DropZero;
        }
        let empty_since = *self.empty_since.get_or_insert(now);
        if !self.paused && now.duration_since(empty_since) >= DRAIN_TAIL {
            Action::Pause
        } else {
            Action::DropZero
        }
    }

    pub(super) fn paused(&mut self) {
        self.paused = true;
    }

    pub(super) fn is_paused(&self) -> bool {
        self.paused
    }

    pub(super) fn resumed(&mut self) {
        self.paused = false;
    }

    pub(super) fn reset(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_short_gap_then_drains_and_resumes_at_first_signal() {
        let start = Instant::now();
        let mut idle = AirAudioIdle::default();
        assert_eq!(idle.observe(start, true, false), Action::Queue);
        assert_eq!(idle.observe(start + Duration::from_millis(499), true, false), Action::Queue);
        assert_eq!(idle.observe(start + Duration::from_millis(500), true, false), Action::DropZero);
        assert_eq!(idle.observe(start + Duration::from_millis(600), true, true), Action::DropZero);
        assert_eq!(idle.observe(start + Duration::from_millis(619), true, true), Action::DropZero);
        assert_eq!(idle.observe(start + Duration::from_millis(620), true, true), Action::Pause);
        idle.paused();
        assert_eq!(idle.observe(start + Duration::from_millis(630), true, true), Action::DropZero);
        assert_eq!(idle.observe(start + Duration::from_millis(640), false, false), Action::Resume);
        idle.resumed();
        assert_eq!(idle.observe(start + Duration::from_millis(650), false, false), Action::Queue);
    }

    #[test]
    fn format_replacement_resets_stale_paused_state() {
        let start = Instant::now();
        let mut idle = AirAudioIdle::default();
        idle.paused();
        idle.reset();
        assert_eq!(idle.observe(start, false, false), Action::Queue);
        assert_eq!(idle.observe(start + Duration::from_millis(1), true, true), Action::Queue);
    }

    #[test]
    fn unmarked_codec_residual_cannot_authorize_suspension() {
        let start = Instant::now();
        let mut idle = AirAudioIdle::default();
        for packet in 0..900 {
            // The decoded PCM can be tiny or even all zero; absent a source
            // marker, the output is kept active without an amplitude guess.
            assert_eq!(idle.observe(start + Duration::from_millis(packet * 10), false, true), Action::Queue);
        }
    }

    #[test]
    fn pause_failure_retries_only_after_drain() {
        let start = Instant::now();
        let mut idle = AirAudioIdle::default();
        idle.observe(start, true, false);
        idle.observe(start + Duration::from_millis(500), true, true);
        assert_eq!(idle.observe(start + Duration::from_millis(520), true, true), Action::Pause);
        // No paused() call: CPAL declined the request.
        assert_eq!(idle.observe(start + Duration::from_millis(530), true, false), Action::DropZero);
        assert_eq!(idle.observe(start + Duration::from_millis(550), true, true), Action::DropZero);
        assert_eq!(idle.observe(start + Duration::from_millis(570), true, true), Action::Pause);
    }
}
