//! Optional bounded LZ4 envelope for large exact updates; small patches stay raw.
use crate::{Invalid, MAX_PACKET};
use std::{borrow::Cow, ffi::c_void, ptr};

const LZ4: u32 = 0x100;
const HEADER: usize = 8;
const MIN_COMPRESS: usize = 65_536;

#[repr(C)]
struct Stream {
    dst_ptr: *mut u8,
    dst_size: usize,
    src_ptr: *const u8,
    src_size: usize,
    state: *mut c_void,
}

#[link(name = "compression")]
extern "C" {
    fn compression_encode_buffer(
        dst: *mut u8,
        dst_size: usize,
        src: *const u8,
        src_size: usize,
        scratch: *mut c_void,
        algorithm: u32,
    ) -> usize;
    fn compression_stream_init(stream: *mut Stream, operation: u32, algorithm: u32) -> i32;
    fn compression_stream_process(stream: *mut Stream, flags: i32) -> i32;
    fn compression_stream_destroy(stream: *mut Stream) -> i32;
}

pub fn pack(raw: Vec<u8>) -> Result<Vec<u8>, Invalid> {
    if raw.len() > MAX_PACKET || !raw.starts_with(b"RDA1") {
        return Err(Invalid("invalid exact compression input"));
    }
    if raw.len() < MIN_COMPRESS {
        return Ok(raw);
    }
    let mut encoded = vec![0u8; raw.len()];
    // Apple allocates temporary encoder scratch space when scratch is null.
    let size = unsafe {
        compression_encode_buffer(
            encoded[HEADER..].as_mut_ptr(),
            encoded.len() - HEADER,
            raw.as_ptr(),
            raw.len(),
            ptr::null_mut(),
            LZ4,
        )
    };
    if size == 0 || size + HEADER >= raw.len() {
        return Ok(raw);
    }
    encoded[..4].copy_from_slice(b"RDL1");
    encoded[4..HEADER].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    encoded.truncate(HEADER + size);
    Ok(encoded)
}

pub fn unpack(packet: &[u8]) -> Result<Cow<'_, [u8]>, Invalid> {
    if !packet.starts_with(b"RDL1") {
        return Ok(Cow::Borrowed(packet));
    }
    if packet.len() <= HEADER || packet.len() > MAX_PACKET {
        return Err(Invalid("invalid LZ4 envelope size"));
    }
    let size = u32::from_le_bytes([packet[4], packet[5], packet[6], packet[7]]) as usize;
    if !(MIN_COMPRESS..=MAX_PACKET).contains(&size) {
        return Err(Invalid("invalid LZ4 expanded size"));
    }
    // The extra byte detects data expanding past the declared limit.
    let mut decoded = vec![0u8; size + 1];
    let mut stream = Stream {
        dst_ptr: ptr::null_mut(),
        dst_size: 0,
        src_ptr: ptr::null(),
        src_size: 0,
        state: ptr::null_mut(),
    };
    if unsafe { compression_stream_init(&mut stream, 1, LZ4) } != 0 {
        return Err(Invalid("cannot initialize LZ4 decoder"));
    }
    stream.dst_ptr = decoded.as_mut_ptr();
    stream.dst_size = decoded.len();
    stream.src_ptr = packet[HEADER..].as_ptr();
    stream.src_size = packet.len() - HEADER;
    // All input and enough output space are supplied at once; do not loop on
    // malformed input. FINALIZE makes a truncated stream fail immediately.
    let status = unsafe { compression_stream_process(&mut stream, 1) };
    let complete = status == 1 && stream.src_size == 0 && stream.dst_size == 1;
    let destroyed = unsafe { compression_stream_destroy(&mut stream) };
    if !complete || destroyed != 0 || !decoded.starts_with(b"RDA1") {
        return Err(Invalid("invalid or truncated LZ4 exact update"));
    }
    decoded.truncate(size);
    Ok(Cow::Owned(decoded))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Encoder, Update};

    fn full() -> Vec<u8> {
        Encoder::new(1)
            .unwrap()
            .encode(&vec![211; 512 * 256 * 4], 512, 256, 512 * 4, true)
            .unwrap()
            .unwrap()
    }

    #[test]
    fn full_roundtrip_and_small_raw_patch() {
        let raw = full();
        let wire = pack(raw.clone()).unwrap();
        assert!(wire.len() < raw.len() / 10);
        let decoded = unpack(&wire).unwrap();
        assert_eq!(&*decoded, &raw);
        assert!(Update::parse(&decoded).unwrap().full);
        let mut encoder = Encoder::new(2).unwrap();
        let mut pixels = vec![0; 128 * 128 * 4];
        encoder.encode(&pixels, 128, 128, 512, true).unwrap();
        pixels[0] = 1;
        let patch = encoder
            .encode(&pixels, 128, 128, 512, false)
            .unwrap()
            .unwrap();
        assert!(patch.len() < MIN_COMPRESS);
        let wire = pack(patch.clone()).unwrap();
        assert_eq!(wire, patch);
        assert!(matches!(unpack(&wire).unwrap(), Cow::Borrowed(_)));
    }

    #[test]
    fn rejects_corruption_truncation_size_lies_and_trailing_bytes() {
        let wire = pack(full()).unwrap();
        for end in 4..wire.len() {
            assert!(unpack(&wire[..end]).is_err());
        }
        for size in [0, 1, 65_535, 65_536, MAX_PACKET as u32 + 1, u32::MAX] {
            let mut wrong = wire.clone();
            wrong[4..8].copy_from_slice(&size.to_le_bytes());
            assert!(unpack(&wrong).is_err());
        }
        let mut trailing = wire.clone();
        trailing.push(0);
        assert!(unpack(&trailing).is_err());
        let mut corrupt = wire;
        corrupt[8..12].fill(0xff);
        assert!(unpack(&corrupt).is_err());
    }

    #[test]
    fn incompressible_pixels_roundtrip_without_expansion() {
        let mut pixels = vec![0; 256 * 256 * 4];
        let mut random = 0x1357_2468u32;
        for value in &mut pixels {
            random ^= random << 13;
            random ^= random >> 17;
            random ^= random << 5;
            *value = random as u8;
        }
        let raw = Encoder::new(1)
            .unwrap()
            .encode(&pixels, 256, 256, 1024, true)
            .unwrap()
            .unwrap();
        let wire = pack(raw.clone()).unwrap();
        assert!(wire.len() <= raw.len());
        assert_eq!(&*unpack(&wire).unwrap(), raw);
    }
}
