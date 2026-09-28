//! Host-only motion selection. The client always receives a full exact image
//! after video; deltas never depend on a frame that was sent as lossy video.
use crate::{Encoder, Result, Update};

pub enum Frame {
    Exact(Vec<u8>),
    Video { keyframe: bool },
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Refresh {
    None,
    /// Timer refresh: keyframe during motion, full exact image while idle.
    Periodic,
    /// Subscriber join or explicit recovery always needs an independent image.
    Full,
}

pub struct AdaptiveEncoder {
    exact: Encoder,
    motion: bool,
    quiet_since: Option<u64>,
    burst_since: Option<u64>,
    burst_bytes: usize,
    burst_frames: u8,
}

// A single large update is worth encoding as video immediately. Three small
// updates in a short burst catch animations that stay within a few exact tiles
// without switching modes for a one-off edit or incidental screen change.
const LARGE_MOTION_BYTES: usize = 64 * 1024;
const SMALL_MOTION_BYTES: usize = 8 * 1024;
const SMALL_MOTION_BURST_BYTES: usize = 32 * 1024;
const SMALL_MOTION_BURST_FRAMES: u8 = 3;
const BURST_WINDOW_MS: u64 = 120;
const SETTLE_MS: u64 = 500;

impl AdaptiveEncoder {
    pub fn new(epoch: u64) -> Result<Self> {
        Ok(Self {
            exact: Encoder::new(epoch)?,
            motion: false,
            quiet_since: None,
            burst_since: None,
            burst_bytes: 0,
            burst_frames: 0,
        })
    }

    pub fn encode(
        &mut self,
        source: Option<(&[u8], usize, usize, usize)>,
        now_ms: u64,
        refresh: Refresh,
    ) -> Result<Option<Frame>> {
        // Keep the exact encoder's source current during video, but only a
        // requested recovery/join may interrupt motion with a full image.
        let full_exact = refresh == Refresh::Full
            || (refresh == Refresh::Periodic && !self.motion);
        let packet = match source {
            Some((bytes, width, height, stride)) => {
                self.exact.encode(bytes, width, height, stride, full_exact)?
            }
            None if full_exact => self.exact.resynchronize()?,
            None => None,
        };
        if let Some(bytes) = packet.as_ref() {
            if Update::parse(bytes)?.full {
                self.motion = false;
                self.quiet_since = None;
                self.burst_since = None;
                self.burst_bytes = 0;
                self.burst_frames = 0;
                return Ok(packet.map(Frame::Exact));
            }
        }
        let changed_bytes = packet.as_ref().map_or(0, Vec::len);
        if !self.motion {
            let large_motion = changed_bytes >= LARGE_MOTION_BYTES;
            if changed_bytes >= SMALL_MOTION_BYTES {
                if self
                    .burst_since
                    .map_or(true, |start| now_ms.saturating_sub(start) > BURST_WINDOW_MS)
                {
                    self.burst_since = Some(now_ms);
                    self.burst_bytes = 0;
                    self.burst_frames = 0;
                }
                self.burst_bytes = self.burst_bytes.saturating_add(changed_bytes);
                self.burst_frames = self.burst_frames.saturating_add(1);
            } else if self.burst_since.map_or(false, |start| {
                now_ms.saturating_sub(start) > BURST_WINDOW_MS
            }) {
                self.burst_since = None;
                self.burst_bytes = 0;
                self.burst_frames = 0;
            }
            let sustained_motion = self.burst_frames >= SMALL_MOTION_BURST_FRAMES
                && self.burst_bytes >= SMALL_MOTION_BURST_BYTES;
            if large_motion || sustained_motion {
                self.motion = true;
                self.quiet_since = None;
                self.burst_since = None;
                self.burst_bytes = 0;
                self.burst_frames = 0;
                return Ok(Some(Frame::Video { keyframe: true }));
            }
        }
        if self.motion {
            if changed_bytes >= SMALL_MOTION_BYTES {
                self.quiet_since = None;
            } else {
                let since = *self.quiet_since.get_or_insert(now_ms);
                if now_ms.saturating_sub(since) >= SETTLE_MS {
                    self.motion = false;
                    self.quiet_since = None;
                    return Ok(self.exact.resynchronize()?.map(Frame::Exact));
                }
            }
            // A periodic keyframe needs a held capture buffer. If capture is
            // idle, leave the timer due until a new sample arrives or settling
            // restores a full exact image.
            if refresh == Refresh::Periodic && source.is_some() {
                return Ok(Some(Frame::Video { keyframe: true }));
            }
            return Ok(packet.map(|_| Frame::Video { keyframe: false }));
        }
        Ok(packet.map(Frame::Exact))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ReceiverState;

    #[test]
    fn motion_resumes_with_keyframe_and_settles_to_current_exact_pixels() {
        let mut e = AdaptiveEncoder::new(1).unwrap();
        let mut pixels = vec![0; 512 * 256 * 4];
        let first = e.encode(Some((&pixels, 512, 256, 2048)), 0, Refresh::None).unwrap();
        let Some(Frame::Exact(first)) = first else {
            panic!("initial frame must be exact")
        };
        let mut receiver = ReceiverState::default();
        receiver.commit(&Update::parse(&first).unwrap());
        pixels.fill(72);
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 20, Refresh::None)
                .unwrap(),
            Some(Frame::Video { keyframe: true })
        ));
        pixels.fill(99);
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 40, Refresh::None)
                .unwrap(),
            Some(Frame::Video { keyframe: false })
        ));
        assert!(e.encode(None, 50, Refresh::None).unwrap().is_none());
        assert!(e.encode(None, 549, Refresh::None).unwrap().is_none());
        let Some(Frame::Exact(restored)) = e.encode(None, 550, Refresh::None).unwrap() else {
            panic!("missing exact refresh")
        };
        let update = Update::parse(&restored).unwrap();
        assert!(update.full);
        receiver.validate(&update).unwrap();
        assert_eq!(update.patches[0].bgra, pixels);
        receiver.commit(&update);
        pixels[0] = 1;
        let Some(Frame::Exact(small)) = e
            .encode(Some((&pixels, 512, 256, 2048)), 600, Refresh::None)
            .unwrap()
        else {
            panic!("small patch must stay exact")
        };
        let update = Update::parse(&small).unwrap();
        assert!(!update.full);
        receiver.validate(&update).unwrap();
        pixels.fill(5);
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 650, Refresh::None)
                .unwrap(),
            Some(Frame::Video { keyframe: true })
        ));
    }

    #[test]
    fn resize_and_periodic_refresh_never_emit_dependent_deltas() {
        let mut e = AdaptiveEncoder::new(2).unwrap();
        let mut pixels = vec![0; 512 * 256 * 4];
        e.encode(Some((&pixels, 512, 256, 2048)), 0, Refresh::None).unwrap();
        pixels.fill(17);
        e.encode(Some((&pixels, 512, 256, 2048)), 20, Refresh::None)
            .unwrap();
        let Some(Frame::Exact(resize)) =
            e.encode(Some((&pixels, 256, 256, 1024)), 30, Refresh::Periodic).unwrap()
        else {
            panic!("resize must reset")
        };
        assert!(Update::parse(&resize).unwrap().full);
        let Some(Frame::Exact(periodic)) = e.encode(None, 10000, Refresh::Periodic).unwrap() else {
            panic!("idle resync missing")
        };
        assert!(Update::parse(&periodic).unwrap().full);
    }

    #[test]
    fn small_continuous_animation_switches_within_three_frames() {
        let mut e = AdaptiveEncoder::new(3).unwrap();
        let mut pixels = vec![0; 256 * 256 * 4];
        assert!(matches!(
            e.encode(Some((&pixels, 256, 256, 1024)), 0, Refresh::None).unwrap(),
            Some(Frame::Exact(_))
        ));
        for (frame, time) in [(1, 16), (2, 33)] {
            pixels[0] = frame;
            assert!(matches!(
                e.encode(Some((&pixels, 256, 256, 1024)), time, Refresh::None)
                    .unwrap(),
                Some(Frame::Exact(_))
            ));
        }
        pixels[0] = 3;
        assert!(matches!(
            e.encode(Some((&pixels, 256, 256, 1024)), 50, Refresh::None)
                .unwrap(),
            Some(Frame::Video { keyframe: true })
        ));
        pixels[0] = 4;
        assert!(matches!(
            e.encode(Some((&pixels, 256, 256, 1024)), 66, Refresh::None)
                .unwrap(),
            Some(Frame::Video { keyframe: false })
        ));
        assert!(e.encode(None, 100, Refresh::None).unwrap().is_none());
        assert!(e.encode(None, 599, Refresh::None).unwrap().is_none());
        let Some(Frame::Exact(full)) = e.encode(None, 600, Refresh::None).unwrap() else {
            panic!("missing exact return")
        };
        let update = Update::parse(&full).unwrap();
        assert!(update.full);
        assert_eq!(update.patches[0].bgra, pixels);
    }

    #[test]
    fn isolated_small_changes_do_not_enter_video() {
        let mut e = AdaptiveEncoder::new(4).unwrap();
        let mut pixels = vec![0; 256 * 256 * 4];
        e.encode(Some((&pixels, 256, 256, 1024)), 0, Refresh::None).unwrap();
        for time in [16, 300, 600, 900] {
            pixels[0] = (time / 16) as u8;
            assert!(matches!(
                e.encode(Some((&pixels, 256, 256, 1024)), time, Refresh::None)
                    .unwrap(),
                Some(Frame::Exact(_))
            ));
        }
    }

    #[test]
    fn periodic_refresh_during_motion_is_a_keyframe_without_exact_interruption() {
        let mut e = AdaptiveEncoder::new(5).unwrap();
        let mut pixels = vec![0; 512 * 256 * 4];
        e.encode(Some((&pixels, 512, 256, 2048)), 0, Refresh::None).unwrap();
        pixels.fill(72);
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 16, Refresh::None)
                .unwrap(),
            Some(Frame::Video { keyframe: true })
        ));
        pixels.fill(73);
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 32, Refresh::Periodic)
                .unwrap(),
            Some(Frame::Video { keyframe: true })
        ));
        pixels.fill(74);
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 48, Refresh::None)
                .unwrap(),
            Some(Frame::Video { keyframe: false })
        ));
        assert!(e.encode(None, 64, Refresh::Periodic).unwrap().is_none());
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 80, Refresh::Periodic).unwrap(),
            Some(Frame::Video { keyframe: true })
        ));
        assert!(e.encode(None, 563, Refresh::Periodic).unwrap().is_none());
        let Some(Frame::Exact(full)) = e.encode(None, 564, Refresh::Periodic).unwrap() else {
            panic!("settling must restore a full exact frame")
        };
        let update = Update::parse(&full).unwrap();
        assert!(update.full);
        assert_eq!(update.patches[0].bgra, pixels);
        let mut receiver = ReceiverState::default();
        receiver.validate(&update).unwrap();
        receiver.commit(&update);
        pixels[0] = 1;
        let Some(Frame::Exact(delta)) = e.encode(Some((&pixels, 512, 256, 2048)), 580, Refresh::None).unwrap() else {
            panic!("small change after settling must be exact")
        };
        let update = Update::parse(&delta).unwrap();
        assert!(!update.full);
        receiver.validate(&update).unwrap();
    }

    #[test]
    fn explicit_recovery_during_motion_is_full_exact() {
        let mut e = AdaptiveEncoder::new(6).unwrap();
        let mut pixels = vec![0; 512 * 256 * 4];
        e.encode(Some((&pixels, 512, 256, 2048)), 0, Refresh::None).unwrap();
        pixels.fill(72);
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 16, Refresh::None).unwrap(),
            Some(Frame::Video { keyframe: true })
        ));
        pixels.fill(73);
        let Some(Frame::Exact(full)) = e.encode(Some((&pixels, 512, 256, 2048)), 32, Refresh::Full).unwrap() else {
            panic!("recovery must be exact")
        };
        let update = Update::parse(&full).unwrap();
        assert!(update.full);
        assert_eq!(update.patches[0].bgra, pixels);
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 48, Refresh::None).unwrap(),
            None
        ));

        pixels.fill(74);
        assert!(matches!(
            e.encode(Some((&pixels, 512, 256, 2048)), 64, Refresh::None).unwrap(),
            Some(Frame::Video { keyframe: true })
        ));
        let Some(Frame::Exact(join)) = e.encode(None, 80, Refresh::Full).unwrap() else {
            panic!("a new subscriber needs a full exact frame even without a new sample")
        };
        let update = Update::parse(&join).unwrap();
        assert!(update.full);
        assert_eq!(update.patches[0].bgra, pixels);
    }
}
