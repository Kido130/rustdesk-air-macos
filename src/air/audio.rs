//! Native remote-mode microphone. The client's microphone is encoded by RustDesk's
//! existing Opus voice-call sender. On the host it is decoded only into the named
//! virtual device, never into the host's physical speakers.

use base::message_proto::{AudioFormat, AudioFrame};
use core_foundation::{
    base::TCFType,
    string::{CFString, CFStringRef},
};
use cpal::{
    traits::{DeviceTrait, HostTrait, StreamTrait},
    SampleFormat, StreamConfig,
};
use hbb_common::{
    anyhow::{anyhow, bail, Context},
    config::Config,
    ResultType,
};
use magnum_opus::{Channels, Decoder};
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    ffi::c_void,
    fs,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender, TrySendError},
        Arc, Mutex,
    },
    thread::JoinHandle,
};

#[path = "mic_demand.rs"]
mod demand;
pub(crate) use demand::NativeMicDemand;

const VIRTUAL_DEVICE: &str = "BlackHole 2ch";
const PCM_QUEUE_MS: usize = 80;
const ENCODED_QUEUE_PACKETS: usize = 8;
static MIC_DEMANDED: AtomicBool = AtomicBool::new(false);
static MIC_ENABLED: AtomicBool = AtomicBool::new(true);
static SINK_ACTIVE: AtomicBool = AtomicBool::new(false);

pub(crate) fn configure_microphone(enabled: bool) {
    MIC_ENABLED.store(enabled, Ordering::Release);
    if !super::shell::accept_input() {
        return;
    }
    request_on_connected();
}

pub(crate) fn microphone_enabled() -> bool {
    MIC_ENABLED.load(Ordering::Acquire)
}

pub(crate) fn capture_allowed() -> bool {
    microphone_enabled() && MIC_DEMANDED.load(Ordering::Acquire) && super::shell::accept_input()
}

pub(crate) fn set_demand(active: bool) {
    let active = active && microphone_enabled();
    if MIC_DEMANDED.swap(active, Ordering::AcqRel) == active { return; }
    hbb_common::log::info!("Air microphone demand {}", if active { "started" } else { "stopped" });
    if let Some(session) = super::SESSION.lock().unwrap().as_ref() {
        if active && super::shell::accept_input() { session.request_voice_call(); }
        else { session.close_voice_call(); }
    }
}

pub(crate) fn reset_demand() { MIC_DEMANDED.store(false, Ordering::Release); }

pub(crate) fn request_on_connected() {
    use crate::client::Interface;
    set_demand(false);
    let mut message = base::message_proto::Message::new();
    message.set_air_control(base::message_proto::AirControl {
        kind: 50, payload: vec![1, microphone_enabled() as u8].into(), ..Default::default()
    });
    if let Some(session) = super::SESSION.lock().unwrap().as_ref() {
        session.send(crate::client::Data::Message(message));
    }
}

fn virtual_output() -> ResultType<cpal::Device> {
    let host = cpal::default_host();
    host.output_devices()
        .context("Cannot list Pro audio outputs")?
        .find(|device| device.name().ok().as_deref() == Some(VIRTUAL_DEVICE))
        .ok_or_else(|| anyhow!("BlackHole 2ch virtual microphone is unavailable on the Pro"))
}

pub(crate) fn virtual_device_available() -> bool {
    virtual_output().is_ok()
}

enum MicPacket {
    Format(AudioFormat),
    Frame(AudioFrame),
}

/// One sink belongs to one authenticated Air connection. Dropping it also restores
/// the original default microphone, including normal disconnect and emergency exit.
pub(crate) struct NativeMicSink {
    sender: Option<SyncSender<MicPacket>>,
    worker: Option<JoinHandle<()>>,
}

impl NativeMicSink {
    pub(crate) fn start(managed_input: bool) -> ResultType<Self> {
        if SINK_ACTIVE
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            bail!("A remote microphone session is already active");
        }
        let result = Self::start_inner(managed_input);
        if result.is_err() {
            SINK_ACTIVE.store(false, Ordering::Release);
        }
        result
    }

    fn start_inner(managed_input: bool) -> ResultType<Self> {
        let (sender, receiver) = mpsc::sync_channel(ENCODED_QUEUE_PACKETS);
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let worker = std::thread::Builder::new()
            .name("air-virtual-mic".into())
            .spawn(move || {
                if let Err(error) = run_mic_worker(receiver, ready_tx.clone(), managed_input) {
                    let _ = ready_tx.send(Err(error));
                }
            })
            .context("Cannot start virtual microphone thread")?;
        match ready_rx
            .recv()
            .context("Virtual microphone thread stopped at startup")?
        {
            Ok(()) => Ok(Self {
                sender: Some(sender),
                worker: Some(worker),
            }),
            Err(error) => {
                drop(sender);
                let _ = worker.join();
                Err(error)
            }
        }
    }

    pub(crate) fn send_format(&self, format: AudioFormat) -> ResultType<()> {
        self.sender
            .as_ref()
            .context("Microphone is closed")?
            .try_send(MicPacket::Format(format))
            .map_err(|error| anyhow!("Cannot queue microphone format: {error}"))
    }

    pub(crate) fn send_frame(&self, frame: AudioFrame) {
        if let Some(sender) = &self.sender {
            match sender.try_send(MicPacket::Frame(frame)) {
                Ok(()) | Err(TrySendError::Full(_)) => {} // Drop late packets; preserve live latency.
                Err(TrySendError::Disconnected(_)) => {
                    hbb_common::log::warn!("Virtual microphone decoder stopped")
                }
            }
        }
    }
}

impl Drop for NativeMicSink {
    fn drop(&mut self) {
        self.sender.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        SINK_ACTIVE.store(false, Ordering::Release);
    }
}

// CPAL's Stream is intentionally !Send. Create, run, and drop it on one audio
// thread; only the bounded sender crosses into the network connection task.
fn run_mic_worker(
    receiver: mpsc::Receiver<MicPacket>,
    ready: SyncSender<ResultType<()>>,
    managed_input: bool,
) -> ResultType<()> {
    let device = virtual_output()?;
    let supported = device
        .default_output_config()
        .context("BlackHole 2ch has no usable output format")?;
    if supported.channels() != 2 || supported.sample_rate().0 == 0 {
        bail!("BlackHole 2ch must expose a stereo output");
    }
    let rate = supported.sample_rate().0;
    let capacity = (rate as usize * 2 * PCM_QUEUE_MS / 1000).max(960);
    let pcm = Arc::new(Mutex::new(VecDeque::with_capacity(capacity)));
    let config: StreamConfig = supported.clone().into();
    let stream = match supported.sample_format() {
        SampleFormat::F32 => build_stream::<f32>(&device, &config, pcm.clone())?,
        SampleFormat::I16 => build_stream::<i16>(&device, &config, pcm.clone())?,
        SampleFormat::I32 => build_stream::<i32>(&device, &config, pcm.clone())?,
        other => bail!("Unsupported BlackHole output sample format: {other:?}"),
    };
    stream
        .play()
        .context("Cannot start BlackHole virtual microphone")?;
    let _input_override = if managed_input { None } else { Some(InputOverride::activate()?) };
    ready
        .send(Ok(()))
        .context("Microphone startup receiver closed")?;
    decode_loop(receiver, pcm, capacity, rate);
    drop(stream);
    Ok(())
}

fn build_stream<T>(
    device: &cpal::Device,
    config: &StreamConfig,
    pcm: Arc<Mutex<VecDeque<f32>>>,
) -> ResultType<cpal::Stream>
where
    T: cpal::Sample + cpal::SizedSample + cpal::FromSample<f32>,
{
    Ok(device.build_output_stream(
        config,
        move |output: &mut [T], _| {
            if let Ok(mut queue) = pcm.try_lock() {
                for sample in output {
                    *sample = T::from_sample(queue.pop_front().unwrap_or(0.0));
                }
            } else {
                for sample in output {
                    *sample = T::from_sample(0.0);
                }
            }
        },
        |error| hbb_common::log::error!("BlackHole output stream: {error}"),
        None,
    )?)
}

fn decode_loop(
    receiver: mpsc::Receiver<MicPacket>,
    pcm: Arc<Mutex<VecDeque<f32>>>,
    capacity: usize,
    output_rate: u32,
) {
    let mut decoder: Option<Decoder> = None;
    let mut channels = 0usize;
    let mut resampler = None;
    let mut buffer = Vec::new();
    while let Ok(packet) = receiver.recv() {
        match packet {
            MicPacket::Format(format) => {
                channels = format.channels as usize;
                if !(channels == 1 || channels == 2)
                    || !matches!(
                        format.sample_rate,
                        8_000 | 12_000 | 16_000 | 24_000 | 48_000
                    )
                {
                    hbb_common::log::error!("Invalid Air microphone format: {:?}", format);
                    decoder = None;
                    continue;
                }
                decoder = Decoder::new(
                    format.sample_rate,
                    if channels == 1 {
                        Channels::Mono
                    } else {
                        Channels::Stereo
                    },
                )
                .ok();
                resampler = if format.sample_rate != output_rate {
                    crate::audio_resampler::AudioResampler::new(
                        crate::audio_resampler::AudioResamplerConfig {
                            input_rate: format.sample_rate,
                            output_rate,
                            channels: channels as u16,
                        },
                    )
                    .ok()
                } else {
                    None
                };
                buffer.resize(format.sample_rate as usize * channels * 120 / 1000, 0.0);
                if let Ok(mut queue) = pcm.lock() {
                    queue.clear();
                }
            }
            MicPacket::Frame(frame) => {
                let Some(decoder) = decoder.as_mut() else {
                    continue;
                };
                let Ok(frames) = decoder.decode_float(&frame.data, &mut buffer, false) else {
                    continue;
                };
                let samples = &buffer[..frames * channels];
                let converted;
                let samples = if let Some(resampler) = resampler.as_mut() {
                    converted = match resampler.process(samples) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };
                    &converted[..]
                } else {
                    samples
                };
                if let Ok(mut queue) = pcm.lock() {
                    append_pcm(&mut queue, samples, channels, capacity);
                }
            }
        }
    }
}

fn append_pcm(queue: &mut VecDeque<f32>, samples: &[f32], channels: usize, capacity: usize) {
    debug_assert!(channels == 1 || channels == 2);
    let input_frames = samples.len() / channels;
    let retained_frames = input_frames.min(capacity / 2);
    let retained = &samples[(input_frames - retained_frames) * channels..input_frames * channels];
    let new_samples = retained_frames * 2;
    let overflow = queue
        .len()
        .saturating_add(new_samples)
        .saturating_sub(capacity);
    for _ in 0..overflow.min(queue.len()) {
        queue.pop_front();
    }
    if channels == 1 {
        for &sample in retained {
            queue.push_back(sample);
            queue.push_back(sample);
        }
    } else {
        queue.extend(retained.iter().copied());
    }
}

#[cfg(test)]
mod tests {
    use super::append_pcm;
    use std::collections::VecDeque;

    #[test]
    fn mono_microphone_is_stereo_and_never_buffers_past_latency_limit() {
        let mut output = VecDeque::new();
        append_pcm(&mut output, &[1.0, 2.0, 3.0], 1, 4);
        assert_eq!(
            output.into_iter().collect::<Vec<_>>(),
            vec![2.0, 2.0, 3.0, 3.0]
        );
    }

    #[test]
    fn newer_microphone_audio_replaces_stale_audio() {
        let mut output = VecDeque::from([1.0, 2.0, 3.0, 4.0]);
        append_pcm(&mut output, &[5.0, 6.0], 2, 4);
        assert_eq!(
            output.into_iter().collect::<Vec<_>>(),
            vec![3.0, 4.0, 5.0, 6.0]
        );
    }
}

type AudioObjectID = u32;
#[repr(C)]
struct PropertyAddress {
    selector: u32,
    scope: u32,
    element: u32,
}
#[link(name = "CoreAudio", kind = "framework")]
extern "C" {
    fn AudioObjectGetPropertyData(
        id: AudioObjectID,
        address: *const PropertyAddress,
        qualifier_size: u32,
        qualifier: *const c_void,
        size: *mut u32,
        data: *mut c_void,
    ) -> i32;
    fn AudioObjectSetPropertyData(
        id: AudioObjectID,
        address: *const PropertyAddress,
        qualifier_size: u32,
        qualifier: *const c_void,
        size: u32,
        data: *const c_void,
    ) -> i32;
    fn AudioObjectGetPropertyDataSize(
        id: AudioObjectID,
        address: *const PropertyAddress,
        qualifier_size: u32,
        qualifier: *const c_void,
        size: *mut u32,
    ) -> i32;
}
const SYSTEM: AudioObjectID = 1;
const fn fourcc(bytes: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*bytes)
}
const GLOBAL: u32 = fourcc(b"glob");
const DEFAULT_INPUT: u32 = fourcc(b"dIn ");
const DEVICES: u32 = fourcc(b"dev#");
const UID: u32 = fourcc(b"uid ");
const ADDRESS_INPUT: PropertyAddress = PropertyAddress {
    selector: DEFAULT_INPUT,
    scope: GLOBAL,
    element: 0,
};
const ADDRESS_DEVICES: PropertyAddress = PropertyAddress {
    selector: DEVICES,
    scope: GLOBAL,
    element: 0,
};
const ADDRESS_UID: PropertyAddress = PropertyAddress {
    selector: UID,
    scope: GLOBAL,
    element: 0,
};

fn get_id(id: AudioObjectID, address: &PropertyAddress) -> ResultType<AudioObjectID> {
    let mut size = 4u32;
    let mut result = 0u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            id,
            address,
            0,
            std::ptr::null(),
            &mut size,
            (&mut result as *mut u32).cast(),
        )
    };
    if status != 0 || size != 4 {
        bail!("CoreAudio property read failed: {status}");
    }
    Ok(result)
}
fn set_id(id: AudioObjectID, address: &PropertyAddress, value: AudioObjectID) -> ResultType<()> {
    let status = unsafe {
        AudioObjectSetPropertyData(
            id,
            address,
            0,
            std::ptr::null(),
            4,
            (&value as *const u32).cast(),
        )
    };
    if status != 0 {
        bail!("CoreAudio input switch failed: {status}");
    }
    Ok(())
}
fn device_uid(id: AudioObjectID) -> ResultType<String> {
    let mut size = std::mem::size_of::<CFStringRef>() as u32;
    let mut value: CFStringRef = std::ptr::null();
    let status = unsafe {
        AudioObjectGetPropertyData(
            id,
            &ADDRESS_UID,
            0,
            std::ptr::null(),
            &mut size,
            (&mut value as *mut CFStringRef).cast(),
        )
    };
    if status != 0 || value.is_null() {
        bail!("Cannot read CoreAudio device UID: {status}");
    }
    Ok(unsafe { CFString::wrap_under_create_rule(value) }.to_string())
}
fn all_devices() -> ResultType<Vec<AudioObjectID>> {
    let mut size = 0u32;
    let status = unsafe {
        AudioObjectGetPropertyDataSize(SYSTEM, &ADDRESS_DEVICES, 0, std::ptr::null(), &mut size)
    };
    if status != 0 {
        bail!("Cannot list CoreAudio devices: {status}");
    }
    let mut devices = vec![0u32; size as usize / 4];
    let status = unsafe {
        AudioObjectGetPropertyData(
            SYSTEM,
            &ADDRESS_DEVICES,
            0,
            std::ptr::null(),
            &mut size,
            devices.as_mut_ptr().cast(),
        )
    };
    if status != 0 {
        bail!("Cannot read CoreAudio devices: {status}");
    }
    devices.truncate(size as usize / 4);
    Ok(devices)
}
fn find_device(uid: &str) -> ResultType<AudioObjectID> {
    all_devices()?
        .into_iter()
        .find(|id| device_uid(*id).ok().as_deref() == Some(uid))
        .ok_or_else(|| anyhow!("CoreAudio device UID is unavailable: {uid}"))
}
fn virtual_uid() -> ResultType<String> {
    // BlackHole's CPAL-visible output was validated separately. Match its CoreAudio
    // device by name, then persist the stable UID rather than a reboot-unstable ID.
    const NAME: PropertyAddress = PropertyAddress {
        selector: fourcc(b"lnam"),
        scope: GLOBAL,
        element: 0,
    };
    for id in all_devices()? {
        let mut size = std::mem::size_of::<CFStringRef>() as u32;
        let mut value: CFStringRef = std::ptr::null();
        let status = unsafe {
            AudioObjectGetPropertyData(
                id,
                &NAME,
                0,
                std::ptr::null(),
                &mut size,
                (&mut value as *mut CFStringRef).cast(),
            )
        };
        if status == 0 && !value.is_null() {
            let name = unsafe { CFString::wrap_under_create_rule(value) }.to_string();
            if name == VIRTUAL_DEVICE {
                return device_uid(id);
            }
        }
    }
    bail!("BlackHole 2ch is not visible to CoreAudio")
}

#[derive(Serialize, Deserialize)]
struct InputJournal {
    original_uid: String,
    virtual_uid: String,
}
fn journal_path() -> PathBuf {
    Config::path("air-virtual-mic-input.json")
}
fn save_journal(journal: &InputJournal) -> ResultType<()> {
    let path = journal_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, serde_json::to_vec(journal)?)?;
    fs::rename(&temporary, path)?;
    Ok(())
}
pub(crate) fn recover_default_input() -> ResultType<()> {
    let path = journal_path();
    let bytes = match fs::read(&path) {
        Ok(v) => v,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    let journal: InputJournal = serde_json::from_slice(&bytes)?;
    let current = get_id(SYSTEM, &ADDRESS_INPUT)?;
    let current_uid = device_uid(current)?;
    if current_uid == journal.virtual_uid {
        set_id(SYSTEM, &ADDRESS_INPUT, find_device(&journal.original_uid)?)?;
    } else if current_uid != journal.original_uid {
        // A user-selected input takes precedence over stale session recovery.
        hbb_common::log::info!("Default microphone changed outside remote mode; retaining it");
    }
    fs::remove_file(path)?;
    Ok(())
}

struct InputOverride {
    active: bool,
}
impl InputOverride {
    fn activate() -> ResultType<Self> {
        recover_default_input()?;
        let original = get_id(SYSTEM, &ADDRESS_INPUT)?;
        let original_uid = device_uid(original)?;
        let virtual_uid = virtual_uid()?;
        let virtual_id = find_device(&virtual_uid)?;
        if original_uid == virtual_uid {
            return Ok(Self { active: false });
        }
        save_journal(&InputJournal {
            original_uid,
            virtual_uid,
        })?;
        if let Err(error) = set_id(SYSTEM, &ADDRESS_INPUT, virtual_id) {
            let _ = fs::remove_file(journal_path());
            return Err(error);
        }
        Ok(Self { active: true })
    }
    fn restore(&mut self) {
        if self.active {
            if let Err(error) = recover_default_input() {
                hbb_common::log::error!("Cannot restore original Pro microphone: {error:#}");
            }
            self.active = false;
        }
    }
}
impl Drop for InputOverride {
    fn drop(&mut self) {
        self.restore();
    }
}
