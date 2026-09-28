//! Ordered exact BGRA updates. All pixel comparison happens on the host.
use std::{error::Error, fmt};

pub mod adaptive;

#[cfg(target_os = "macos")]
pub mod apple_lz4;

pub const MAX_WIDTH: usize = 8192;
pub const MAX_HEIGHT: usize = 8192;
pub const MAX_PIXELS: usize = 16_777_216;
pub const MAX_PACKET: usize = MAX_PIXELS * 4 + 1_048_576;
const HEADER: usize = 40;
const TILE: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invalid(pub &'static str);
impl fmt::Display for Invalid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}
impl Error for Invalid {}
type Result<T> = std::result::Result<T, Invalid>;

fn raster_len(w: usize, h: usize) -> Result<usize> {
    if w == 0 || h == 0 || w > MAX_WIDTH || h > MAX_HEIGHT || w * h > MAX_PIXELS {
        return Err(Invalid("invalid raster dimensions"));
    }
    Ok(w * h * 4)
}

#[derive(Debug)]
pub struct Patch<'a> {
    pub x: usize,
    pub y: usize,
    pub width: usize,
    pub height: usize,
    pub bgra: &'a [u8],
}
#[derive(Debug)]
pub struct Update<'a> {
    pub epoch: u64,
    pub sequence: u64,
    pub base: u64,
    pub width: usize,
    pub height: usize,
    pub full: bool,
    pub patches: Vec<Patch<'a>>,
}

struct Reader<'a> {
    data: &'a [u8],
    offset: usize,
}
impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(n)
            .ok_or(Invalid("length overflow"))?;
        let v = self
            .data
            .get(self.offset..end)
            .ok_or(Invalid("truncated update"))?;
        self.offset = end;
        Ok(v)
    }
    fn u32(&mut self) -> Result<u32> {
        let v = self.take(4)?;
        Ok(u32::from_le_bytes([v[0], v[1], v[2], v[3]]))
    }
    fn u64(&mut self) -> Result<u64> {
        let lo = self.u32()? as u64;
        Ok(lo | (self.u32()? as u64) << 32)
    }
}

impl<'a> Update<'a> {
    pub fn parse(data: &'a [u8]) -> Result<Self> {
        if data.len() < HEADER || data.len() > MAX_PACKET {
            return Err(Invalid("invalid packet size"));
        }
        let mut r = Reader { data, offset: 0 };
        if r.take(4)? != b"RDA1" {
            return Err(Invalid("unsupported exact protocol"));
        }
        let flags = r.u32()?;
        if flags > 1 {
            return Err(Invalid("unsupported flags"));
        }
        let epoch = r.u64()?;
        let sequence = r.u64()?;
        let base = r.u64()?;
        let width = r.u32()? as usize;
        let height = r.u32()? as usize;
        raster_len(width, height)?;
        if epoch == 0 || sequence == 0 {
            return Err(Invalid("zero generation or sequence"));
        }
        let full = flags == 1;
        if (full && base != 0) || (!full && base.checked_add(1) != Some(sequence)) {
            return Err(Invalid("invalid dependency"));
        }
        let mut patches = Vec::new();
        let mut total = 0usize;
        while r.offset < data.len() {
            if patches.len() >= 16_384 {
                return Err(Invalid("too many patches"));
            }
            let x = r.u32()? as usize;
            let y = r.u32()? as usize;
            let w = r.u32()? as usize;
            let h = r.u32()? as usize;
            let len = raster_len(w, h)?;
            if x.checked_add(w).filter(|&n| n <= width).is_none()
                || y.checked_add(h).filter(|&n| n <= height).is_none()
            {
                return Err(Invalid("patch outside raster"));
            }
            total = total
                .checked_add(len)
                .ok_or(Invalid("patch byte overflow"))?;
            if total > MAX_PIXELS * 4 {
                return Err(Invalid("excessive patch data"));
            }
            patches.push(Patch {
                x,
                y,
                width: w,
                height: h,
                bgra: r.take(len)?,
            });
        }
        if patches.is_empty() {
            return Err(Invalid("empty update"));
        }
        if full
            && (patches.len() != 1
                || patches[0].x != 0
                || patches[0].y != 0
                || patches[0].width != width
                || patches[0].height != height)
        {
            return Err(Invalid("incomplete full frame"));
        }
        Ok(Self {
            epoch,
            sequence,
            base,
            width,
            height,
            full,
            patches,
        })
    }
}

/// Tracks metadata only. The client never keeps a CPU desktop image.
#[derive(Default, Debug)]
pub struct ReceiverState {
    pub epoch: u64,
    pub sequence: u64,
    pub width: usize,
    pub height: usize,
}
impl ReceiverState {
    pub fn validate(&self, update: &Update<'_>) -> Result<()> {
        if update.full {
            if self.epoch == update.epoch && update.sequence <= self.sequence {
                return Err(Invalid("stale full frame"));
            }
            return Ok(());
        }
        if self.epoch != update.epoch
            || self.sequence != update.base
            || self.width != update.width
            || self.height != update.height
        {
            return Err(Invalid("exact stream needs a full resynchronization"));
        }
        Ok(())
    }
    /// Commit only after every patch was accepted by the GPU upload path.
    pub fn commit(&mut self, update: &Update<'_>) {
        self.epoch = update.epoch;
        self.sequence = update.sequence;
        self.width = update.width;
        self.height = update.height;
    }
    pub fn invalidate(&mut self) {
        *self = Self::default();
    }
}

pub struct Encoder {
    epoch: u64,
    sequence: u64,
    width: usize,
    height: usize,
    previous: Vec<u8>,
}
impl Encoder {
    pub fn new(epoch: u64) -> Result<Self> {
        if epoch == 0 {
            return Err(Invalid("zero epoch"));
        }
        Ok(Self {
            epoch,
            sequence: 0,
            width: 0,
            height: 0,
            previous: Vec::new(),
        })
    }
    /// Send a periodic full frame even if capture produces no new samples while idle.
    pub fn resynchronize(&mut self) -> Result<Option<Vec<u8>>> {
        if self.previous.is_empty() {
            return Ok(None);
        }
        let source = self.previous.clone();
        self.encode(&source, self.width, self.height, self.width * 4, true)
    }
    /// BGRA source may have row padding. Never transmit padding bytes.
    pub fn encode(
        &mut self,
        bgra: &[u8],
        width: usize,
        height: usize,
        stride: usize,
        resync: bool,
    ) -> Result<Option<Vec<u8>>> {
        let len = raster_len(width, height)?;
        if stride < width * 4
            || stride
                .checked_mul(height)
                .filter(|&n| n <= bgra.len())
                .is_none()
        {
            return Err(Invalid("invalid source stride or length"));
        }
        let full =
            resync || self.previous.is_empty() || self.width != width || self.height != height;
        let mut regions = Vec::new();
        if full {
            regions.push((0, 0, width, height));
        } else {
            for y in (0..height).step_by(TILE) {
                let h = TILE.min(height - y);
                let mut run = None;
                for x in (0..width).step_by(TILE) {
                    let w = TILE.min(width - x);
                    let changed = (y..y + h).any(|row| {
                        bgra[row * stride + x * 4..row * stride + (x + w) * 4]
                            != self.previous[(row * width + x) * 4..(row * width + x + w) * 4]
                    });
                    if changed && run.is_none() {
                        run = Some(x);
                    }
                    if !changed {
                        if let Some(start) = run.take() {
                            regions.push((start, y, x - start, h));
                        }
                    }
                }
                if let Some(start) = run {
                    regions.push((start, y, width - start, h));
                }
            }
        }
        if regions.is_empty() {
            return Ok(None);
        }
        let sequence = self
            .sequence
            .checked_add(1)
            .ok_or(Invalid("sequence exhausted"))?;
        let mut out = Vec::with_capacity(
            HEADER
                + regions
                    .iter()
                    .map(|&(_, _, w, h)| 16 + w * h * 4)
                    .sum::<usize>(),
        );
        out.extend_from_slice(b"RDA1");
        out.extend_from_slice(&(full as u32).to_le_bytes());
        out.extend_from_slice(&self.epoch.to_le_bytes());
        out.extend_from_slice(&sequence.to_le_bytes());
        out.extend_from_slice(&(if full { 0 } else { self.sequence }).to_le_bytes());
        out.extend_from_slice(&(width as u32).to_le_bytes());
        out.extend_from_slice(&(height as u32).to_le_bytes());
        self.previous.resize(len, 0);
        for (x, y, w, h) in regions {
            for n in [x, y, w, h] {
                out.extend_from_slice(&(n as u32).to_le_bytes());
            }
            for row in y..y + h {
                let source = &bgra[row * stride + x * 4..row * stride + (x + w) * 4];
                out.extend_from_slice(source);
                self.previous[(row * width + x) * 4..(row * width + x + w) * 4]
                    .copy_from_slice(source);
            }
        }
        self.sequence = sequence;
        self.width = width;
        self.height = height;
        Ok(Some(out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn apply(state: &mut ReceiverState, image: &mut Vec<u8>, packet: &[u8]) -> Result<()> {
        let u = Update::parse(packet)?;
        state.validate(&u)?;
        if u.full {
            image.resize(u.width * u.height * 4, 0);
        }
        for p in &u.patches {
            for row in 0..p.height {
                let start = ((p.y + row) * u.width + p.x) * 4;
                image[start..start + p.width * 4]
                    .copy_from_slice(&p.bgra[row * p.width * 4..(row + 1) * p.width * 4]);
            }
        }
        state.commit(&u);
        Ok(())
    }
    #[test]
    fn exact_random_changes_padding_unchanged_and_resync() {
        let (w, h, stride) = (193, 131, 193 * 4 + 28);
        let mut source = vec![0xa7; stride * h];
        let mut encoder = Encoder::new(7).unwrap();
        let mut receiver = ReceiverState::default();
        let mut image = Vec::new();
        let mut seed = 19u64;
        for step in 0..100 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let x = seed as usize % w;
            let y = (seed >> 32) as usize % h;
            source[y * stride + x * 4] = step;
            let packet = encoder
                .encode(&source, w, h, stride, step % 19 == 0)
                .unwrap()
                .unwrap();
            apply(&mut receiver, &mut image, &packet).unwrap();
            for row in 0..h {
                assert_eq!(
                    &image[row * w * 4..(row + 1) * w * 4],
                    &source[row * stride..row * stride + w * 4]
                );
            }
            assert!(encoder
                .encode(&source, w, h, stride, false)
                .unwrap()
                .is_none());
        }
    }
    #[test]
    fn gap_requires_full_frame_and_resize_reinitializes() {
        let mut e = Encoder::new(8).unwrap();
        let mut s = ReceiverState::default();
        let mut image = Vec::new();
        let mut source = vec![0; 128 * 128 * 4];
        apply(
            &mut s,
            &mut image,
            &e.encode(&source, 128, 128, 512, false).unwrap().unwrap(),
        )
        .unwrap();
        source[0] = 1;
        e.encode(&source, 128, 128, 512, false).unwrap();
        source[8] = 2;
        let skipped = e.encode(&source, 128, 128, 512, false).unwrap().unwrap();
        assert!(apply(&mut s, &mut image, &skipped).is_err());
        apply(
            &mut s,
            &mut image,
            &e.encode(&source, 128, 128, 512, true).unwrap().unwrap(),
        )
        .unwrap();
        let smaller = vec![17; 72 * 60 * 4];
        apply(
            &mut s,
            &mut image,
            &e.encode(&smaller, 72, 60, 288, false).unwrap().unwrap(),
        )
        .unwrap();
        assert_eq!(image, smaller);
    }
    #[test]
    fn rejects_truncation_bounds_bad_flags_and_bad_source() {
        let mut e = Encoder::new(9).unwrap();
        let packet = e
            .encode(&vec![5; 32 * 32 * 4], 32, 32, 128, false)
            .unwrap()
            .unwrap();
        for end in 0..packet.len() {
            assert!(Update::parse(&packet[..end]).is_err());
        }
        for offset in [4, 32, 36, 40, 44, 48, 52] {
            let mut bad = packet.clone();
            bad[offset..offset + 4].copy_from_slice(&u32::MAX.to_le_bytes());
            assert!(Update::parse(&bad).is_err());
        }
        assert!(e.encode(&[0; 4], 1, 1, usize::MAX, false).is_err());
        assert!(e.encode(&[], MAX_WIDTH + 1, 1, 1, false).is_err());
        assert!(Encoder::new(0).is_err());
    }
    #[test]
    fn idle_resync_preserves_pixels_and_rejects_stale_full_frames() {
        let mut encoder = Encoder::new(11).unwrap();
        assert!(encoder.resynchronize().unwrap().is_none());
        let original = vec![83; 97 * 63 * 4];
        let first = encoder
            .encode(&original, 97, 63, 97 * 4, false)
            .unwrap()
            .unwrap();
        let mut state = ReceiverState::default();
        let mut image = Vec::new();
        apply(&mut state, &mut image, &first).unwrap();
        assert!(apply(&mut state, &mut image, &first).is_err());
        let full = encoder.resynchronize().unwrap().unwrap();
        assert!(Update::parse(&full).unwrap().full);
        apply(&mut state, &mut image, &full).unwrap();
        assert_eq!(image, original);
        assert_eq!(state.sequence, 2);
        state.invalidate();
        apply(&mut state, &mut image, &full).unwrap();
        assert_eq!(image, original);
    }
    #[test]
    fn random_untrusted_bytes_never_panic() {
        let mut seed = 1u64;
        for n in 0..2048 {
            let mut bytes = vec![0; n];
            for b in &mut bytes {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                *b = (seed >> 32) as u8;
            }
            let _ = Update::parse(&bytes);
        }
    }
}
