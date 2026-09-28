//! Adjust hardware video bitrate from frames actually presented by the Air.
//! A sender-limited stream is held steady: fewer sent frames alone do not
//! establish that lowering bitrate would improve playback.

const MIN_BPS: u32 = 2_000_000;
const SAMPLE_MS: u64 = 2_000;
const STALE_MS: u64 = 3_000;

pub(crate) struct QualityController {
    bitrate_bps: u32,
    baseline_bps: u32,
    baseline: Option<(u64, u64, u64, u64)>,
    delivery_ewma: Option<f64>,
    bad_windows: u8,
    good_windows: u8,
}

impl QualityController {
    pub(crate) fn new(initial_bps: u32) -> Self {
        Self {
            bitrate_bps: initial_bps,
            baseline_bps: initial_bps,
            baseline: None,
            delivery_ewma: None,
            bad_windows: 0,
            good_windows: 0,
        }
    }

    pub(crate) fn bitrate_bps(&self) -> u32 { self.bitrate_bps }

    pub(crate) fn reset_measurement(&mut self) {
        self.baseline = None;
        self.delivery_ewma = None;
        self.bad_windows = 0;
        self.good_windows = 0;
    }

    /// Cumulative counts must describe the same video stream. `blocked_ms_total`
    /// counts time spent waiting for flow credit. `feedback_age_ms` is None
    /// until the first Air report.
    /// Returns a new bitrate only when the active encoder should be updated.
    pub(crate) fn sample(
        &mut self,
        now_ms: u64,
        sent_total: u64,
        presented_total: u64,
        blocked_ms_total: u64,
        feedback_age_ms: Option<u64>,
    ) -> Option<u32> {
        let stale = feedback_age_ms.map_or(true, |age| age > STALE_MS);
        let Some((last_ms, last_sent, last_presented, last_blocked)) = self.baseline else {
            self.baseline = Some((now_ms, sent_total, presented_total, blocked_ms_total));
            return None;
        };
        if sent_total < last_sent || presented_total < last_presented
            || blocked_ms_total < last_blocked || now_ms < last_ms {
            self.baseline = Some((now_ms, sent_total, presented_total, blocked_ms_total));
            self.delivery_ewma = None;
            self.bad_windows = 0;
            self.good_windows = 0;
            return None;
        }
        let elapsed = now_ms - last_ms;
        if elapsed < SAMPLE_MS { return None; }
        self.baseline = Some((now_ms, sent_total, presented_total, blocked_ms_total));
        let sent = sent_total - last_sent;
        let presented = presented_total - last_presented;
        let blocked_ms = blocked_ms_total - last_blocked;
        if stale {
            self.delivery_ewma = None;
            self.bad_windows = 0;
            self.good_windows = 0;
            return None;
        }
        // Sparse frames while a scene settles do not describe a sustained
        // video stream. Their ACK/presentation timing can include a large
        // exact refresh and would otherwise needlessly lower LAN quality.
        // A stream stalled behind ACK credit can also send very few frames.
        // Require repeated frames and near-continuous blocking to distinguish
        // that failure from an idle scene or a single large Exact refresh.
        let stalled_video = sent >= 8 && blocked_ms >= elapsed.saturating_mul(3) / 4;
        if sent < 40 && !stalled_video {
            self.good_windows = 0;
            self.bad_windows = 0;
            return None;
        }
        let delivery = (presented as f64 / sent as f64).min(1.0);
        let smoothed = self.delivery_ewma.map_or(delivery, |previous| previous * 0.5 + delivery * 0.5);
        self.delivery_ewma = Some(smoothed);
        let sent_fps = sent as f64 * 1_000.0 / elapsed as f64;
        let presented_fps = presented as f64 * 1_000.0 / elapsed as f64;
        let flow_congested = blocked_ms >= 200 && presented_fps < 53.0;
        let congested = smoothed < 0.88 || flow_congested;
        if congested {
            self.good_windows = 0;
            self.bad_windows = self.bad_windows.saturating_add(1);
            if delivery < 0.65 || self.bad_windows >= 2 {
                self.bad_windows = 0;
                let target = (self.bitrate_bps as u64 * 80 / 100) as u32;
                return self.set_bitrate(target.max(self.baseline_bps.min(MIN_BPS)));
            }
            return None;
        }
        self.bad_windows = 0;
        let smooth = smoothed >= 0.97
            && sent_fps >= 55.0
            && presented_fps >= 53.0
            && blocked_ms < 100;
        if smooth {
            self.good_windows = self.good_windows.saturating_add(1);
            if self.good_windows >= 3 {
                self.good_windows = 0;
                let target = (self.bitrate_bps as u64 * 105 / 100) as u32;
                return self.set_bitrate(target.min(self.baseline_bps));
            }
        } else {
            self.good_windows = 0;
        }
        None
    }

    fn set_bitrate(&mut self, next: u32) -> Option<u32> {
        if next == self.bitrate_bps { return None; }
        self.bitrate_bps = next;
        Some(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn healthy_playback_recovers_gradually_to_configured_baseline() {
        let mut q = QualityController::new(12_000_000);
        q.bitrate_bps = 10_000_000;
        assert_eq!(q.sample(0, 0, 0, 0, Some(0)), None);
        assert_eq!(q.sample(2_000, 120, 120, 0, Some(0)), None);
        assert_eq!(q.sample(4_000, 240, 240, 0, Some(0)), None);
        assert_eq!(q.sample(6_000, 360, 360, 0, Some(0)), Some(10_500_000));
        assert!(q.bitrate_bps() <= 12_000_000);
    }

    #[test]
    fn healthy_playback_recovers_without_backpressure() {
        let mut q = QualityController::new(12_000_000);
        q.bitrate_bps = 8_000_000;
        q.sample(0, 0, 0, 0, Some(0));
        q.sample(2_000, 120, 120, 0, Some(0));
        q.sample(4_000, 240, 240, 0, Some(0));
        assert_eq!(q.sample(6_000, 360, 360, 0, Some(0)), Some(8_400_000));
    }

    #[test]
    fn sustained_delivery_loss_reduces_bitrate_without_dropping_below_floor() {
        let mut q = QualityController::new(12_000_000);
        q.sample(0, 0, 0, 0, Some(0));
        assert_eq!(q.sample(2_000, 120, 100, 0, Some(0)), None);
        assert_eq!(q.sample(4_000, 240, 190, 0, Some(0)), Some(9_600_000));
        assert_eq!(q.bitrate_bps(), 9_600_000);
    }

    #[test]
    fn sender_limited_cadence_holds_quality_when_delivery_is_complete() {
        let mut q = QualityController::new(12_000_000);
        q.sample(0, 0, 0, 0, Some(0));
        for window in 1..=10 {
            assert_eq!(q.sample(window * 2_000, window * 96, window * 96, 0, Some(0)), None);
        }
        assert_eq!(q.bitrate_bps(), 12_000_000);
    }

    #[test]
    fn sparse_settling_frames_do_not_lower_video_quality() {
        let mut q = QualityController::new(12_000_000);
        q.sample(0, 0, 0, 0, Some(0));
        assert_eq!(q.sample(2_000, 24, 16, 850, Some(0)), None);
        assert_eq!(q.sample(4_000, 28, 23, 1_600, Some(0)), None);
        assert_eq!(q.bitrate_bps(), 12_000_000);
    }

    #[test]
    fn flow_backpressure_reduces_bitrate_even_when_every_sent_frame_presents() {
        let mut q = QualityController::new(12_000_000);
        q.sample(0, 0, 0, 0, Some(0));
        assert_eq!(q.sample(2_000, 96, 96, 250, Some(0)), None);
        assert_eq!(q.sample(4_000, 192, 192, 500, Some(0)), Some(9_600_000));
        assert_eq!(q.sample(6_000, 312, 312, 500, Some(0)), None);
        assert_eq!(q.sample(8_000, 432, 432, 500, Some(0)), None);
        assert_eq!(q.sample(10_000, 552, 552, 500, Some(0)), Some(10_080_000));
    }

    #[test]
    fn missing_feedback_preserves_configured_quality() {
        let mut q = QualityController::new(16_000_000);
        q.sample(0, 0, 0, 0, None);
        assert_eq!(q.sample(2_000, 120, 0, 500, None), None);
        assert_eq!(q.sample(4_000, 240, 0, 1_000, None), None);
        assert_eq!(q.sample(6_000, 360, 360, 1_000, Some(0)), None);
        assert_eq!(q.sample(8_000, 480, 480, 1_000, Some(0)), None);
        assert_eq!(q.sample(10_000, 600, 600, 1_000, Some(0)), None);
        assert_eq!(q.bitrate_bps(), 16_000_000);
    }

    #[test]
    fn alternating_good_and_bad_windows_do_not_oscillate() {
        let mut q = QualityController::new(12_000_000);
        q.sample(0, 0, 0, 0, Some(0));
        for window in 1..=10 {
            let sent = window * 120;
            let presented = if window % 2 == 0 { sent - 20 } else { sent };
            assert_eq!(q.sample(window * 2_000, sent, presented, 0, Some(0)), None);
        }
        assert_eq!(q.bitrate_bps(), 12_000_000);
    }
    #[test]
    fn sustained_five_fps_with_credit_stalls_reduces_bitrate() {
        let mut q = QualityController::new(12_000_000);
        q.sample(0, 0, 0, 0, Some(0));
        assert_eq!(q.sample(2_000, 10, 10, 1_800, Some(0)), None);
        assert_eq!(q.sample(4_000, 20, 20, 3_600, Some(0)), Some(9_600_000));
    }

    #[test]
    fn low_frame_rate_without_credit_stalls_preserves_quality() {
        let mut q = QualityController::new(12_000_000);
        q.sample(0, 0, 0, 0, Some(0));
        for t in 1..=5 {
            assert_eq!(q.sample(t * 2_000, t * 10, t * 10, t * 50, Some(0)), None);
        }
        assert_eq!(q.bitrate_bps(), 12_000_000);
    }

}
