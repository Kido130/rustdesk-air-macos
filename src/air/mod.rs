use crate::{
    client::{Data, Interface},
    ui_session_interface::{InvokeUiSession, Session},
};
use base::message_proto::*;
use hbb_common::{
    anyhow::{anyhow, Context},
    bail,
    config::{Config, APP_NAME},
    rendezvous_proto::ConnType,
    tokio, ResultType, Stream,
};
use rustdesk_air_protocol::{apple_lz4, ReceiverState, Update};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
        Arc, Mutex, RwLock,
    },
};

mod ui;
mod network;
mod shell;
pub(crate) mod audio;
pub(crate) mod workspace;
pub(crate) mod control;
pub(crate) mod flow;
pub(crate) mod quality;
pub(crate) mod ack_trace;
use ui::NativeUi;

static CLIENT_MODE: AtomicU32 = AtomicU32::new(0);
static MATCH_DISPLAY: AtomicBool = AtomicBool::new(false);
static CLIENT_DISPLAY: Mutex<Option<AirDisplaySpec>> = Mutex::new(None);
static HOST: AtomicBool = AtomicBool::new(false);
static PAIRING: Mutex<Option<Pairing>> = Mutex::new(None);
static SESSION: Mutex<Option<Session<NativeUi>>> = Mutex::new(None);
static RECEIVED_VIDEO_FRAMES: AtomicU64 = AtomicU64::new(0);
static FEEDBACK_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static LAST_FEEDBACK: Mutex<Option<std::time::Instant>> = Mutex::new(None);
static EXACT: Mutex<ReceiverState> = Mutex::new(ReceiverState {
    epoch: 0,
    sequence: 0,
    width: 0,
    height: 0,
});
pub(crate) static DISPLAY_ORIGIN: Mutex<(i32, i32)> = Mutex::new((0, 0));

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct Pairing {
    version: u32,
    address: String,
    #[serde(default)]
    lan_addresses: Vec<String>,
    #[serde(default)]
    tailscale_addresses: Vec<String>,
    host_id: String,
    public_key: String,
    password: String,
}

#[repr(C)]
#[derive(Default)]
pub(crate) struct NativeDisplaySpec {
    pub logical_width: u32,
    pub logical_height: u32,
    pub pixel_width: u32,
    pub pixel_height: u32,
}

#[repr(C)]
#[derive(Default)]
pub(crate) struct NativeStageTiming {
    pub calls: u64,
    pub total_us: u64,
    pub max_us: u64,
}

#[repr(C)]
#[derive(Default)]
pub(crate) struct NativeCaptureProfile {
    pub complete_callbacks: u64,
    pub latest_overwrites: u64,
    pub next_successes: u64,
    pub encode_submit: NativeStageTiming,
    pub encode_complete_wait: NativeStageTiming,
}

pub(crate) mod ffi {
    use super::{c_char, c_void, NativeCaptureProfile, NativeDisplaySpec};
    extern "C" {
        pub fn air_app_init(
            input: Option<extern "C" fn(i32, f64, f64, u32, u64, *mut c_void)>,
            context: *mut c_void,
            host: i32,
        ) -> i32;
        pub fn air_display_current(spec: *mut NativeDisplaySpec) -> i32;
        pub fn air_display_match(spec: *const NativeDisplaySpec) -> i32;
        pub fn air_display_restore() -> i32;
        pub fn air_display_shutdown() -> i32;
        pub fn air_spaces_recover() -> i32;
        pub fn air_spaces_diagnostics() -> *const c_char;
        pub fn air_spaces_prepare() -> i32;
        pub fn air_spaces_activate() -> i32;
        pub fn air_spaces_restore() -> i32;
        pub fn air_spaces_shutdown() -> i32;
        pub fn air_spaces_select(slot: i32) -> i32;
        pub fn air_spaces_current_slot() -> i32;
        pub fn air_spaces_slot_count() -> i32;
        pub fn air_spaces_slot_id(slot: i32) -> u64;
        pub fn air_spaces_loop_supported() -> i32;
        pub fn air_spaces_wrap_boundary(starting_slot: i32, logical_direction: i32) -> i32;
        pub fn air_overlay_state(count: i32, current: i32, flags: i32);
        pub fn air_overlay_setup(choose: Option<extern "C" fn(i32)>, loop_changed: Option<extern "C" fn(i32)>);
        pub fn air_overlay_setup_reconnect(reconnect: Option<extern "C" fn()>);
        pub fn air_client_match_display(enabled: i32, fullscreen: i32);
        pub fn air_microphone_menu(callback: Option<extern "C" fn(i32)>, enabled: i32);
        pub fn air_chosen_display_match() -> i32;
        pub fn air_is_host_bundle() -> i32;
        pub fn air_choose_pairing() -> *const c_char;
        pub fn air_choose_mode() -> i32;
        pub fn air_host_pairing(path: *const c_char);
        pub fn air_show_error(message: *const c_char);
        pub fn air_input_capture_schedule(seconds: i32, path: *const c_char);
        pub fn air_capture_v2_schedule(seconds: i32, path: *const c_char, generation: u64);
        pub fn air_capture_v2_stop();
        pub fn air_capture_v2_status() -> i32;
        pub fn air_input_setup(event: Option<extern "C" fn(*const u8, usize, u64)>, release: Option<extern "C" fn(u64)>) -> i32;
        pub fn air_keyboard_probe_configure(enabled: i32) -> i32;
        pub fn air_cursor_probe_configure(enabled: i32) -> i32;
        pub fn air_input_connected(connected: i32);
        pub fn air_input_generation() -> u64;
        pub fn air_input_raw_enabled(enabled: i32);
        pub fn air_input_space_swipe_callback(callback: Option<extern "C" fn(i32, i32, u64)>);
        pub fn air_host_raw_supported() -> i32;
        pub fn air_client_raw_supported() -> i32;
        pub fn air_raw_probe_configure(seconds: i32) -> i32;
        pub fn air_raw_full_configure(enabled: i32) -> i32;
        pub fn air_raw_wire_version() -> i32;
        pub fn air_input_shutdown();
        pub fn air_host_input_begin(id: i32, requested_raw: i32) -> i32;
        pub fn air_host_input_event(id: i32, bytes: *const u8, len: usize) -> i32;
        pub fn air_host_edge_drag_event(id: i32, kind: i32, x: i32, y: i32);
        pub fn air_host_input_release(id: i32);
        pub fn air_host_input_end(id: i32);
        pub fn air_host_input_shutdown();
        pub fn air_app_run();
        pub fn air_app_stop();
        pub fn air_app_set_cleanup(cleanup: Option<extern "C" fn(*mut c_void)>, context: *mut c_void);
        pub fn air_status(message: *const c_char, error: i32);
        pub fn air_hardware_support(codec: i32) -> i32;
        pub fn air_exact_begin(width: u32, height: u32, full: i32, upload_bytes: usize) -> i32;
        pub fn air_exact_patch(
            x: u32,
            y: u32,
            width: u32,
            height: u32,
            bytes: *const u8,
            len: usize,
        ) -> i32;
        pub fn air_exact_commit() -> i32;
        pub fn air_exact_abort();
        pub fn air_decode(bytes: *const u8, len: usize) -> i32;
        pub fn air_decoder_reset();
        pub fn air_cursor(x: f64, y: f64);
        pub fn air_cursor_shape(id: u64, w: u32, h: u32, hx: u32, hy: u32, rgba: *const u8, len: usize) -> i32;
        pub fn air_cursor_select(id: u64);
        pub fn air_cursor_selftest() -> i32;
        pub fn air_surface_clear();
        pub fn air_shell_begin();
        pub fn air_shell_end();
        pub fn air_chosen_remote_mode() -> i32;
        pub fn air_chosen_remote_spaces() -> i32;
        pub fn air_chosen_raw_contacts() -> i32;
        pub fn air_input_dimensions(width: u32, height: u32);
        pub fn air_video_bytes(bytes: usize);
        pub fn air_presentation_counters(unique: *mut u64, missed: *mut u64);
        pub fn air_last_error() -> *const c_char;
        pub fn air_metrics() -> *const c_char;
        pub fn air_builtin_display() -> u32;
        pub fn air_capture_start(display: u32, profile: i32) -> *mut c_void;
        pub fn air_capture_video_bitrate(capture: *mut c_void) -> u32;
        pub fn air_capture_set_video_bitrate(capture: *mut c_void, bits_per_second: u32) -> i32;
        pub fn air_capture_next(
            capture: *mut c_void,
            data: *mut *const u8,
            len: *mut usize,
            width: *mut u32,
            height: *mut u32,
            stride: *mut u32,
            timeout: u32,
        ) -> i32;
        pub fn air_capture_release_frame(capture: *mut c_void);
        pub fn air_capture_stop(capture: *mut c_void);
        pub fn air_capture_stop_profiled(capture: *mut c_void, profile: *mut NativeCaptureProfile);
        pub fn air_encode(
            capture: *mut c_void,
            codec: i32,
            data: *mut *const u8,
            len: *mut usize,
            force_key: i32,
        ) -> i32;
        pub fn air_encode_submit(capture: *mut c_void, codec: i32, force_key: i32) -> i32;
        pub fn air_encode_finish(capture: *mut c_void, data: *mut *const u8, len: *mut usize) -> i32;
        pub fn air_native_selftest() -> i32;
        pub fn air_transition_selftest() -> i32;
        pub fn air_codec_selftest(codec: i32) -> i32;
        pub fn air_codec_async_selftest(codec: i32) -> i32;
        pub fn air_set_video_bitrate(bits_per_second: u32) -> i32;
    }
}
pub fn client_enabled() -> bool {
    CLIENT_MODE.load(Ordering::Relaxed) != 0
}
pub(crate) fn input_dequeued(data: &Data) {
    shell::input_dequeued(data);
}
pub fn host_enabled() -> bool {
    HOST.load(Ordering::Relaxed)
}
pub fn host_display(displays: &[DisplayInfo], primary: usize) -> usize {
    if !host_enabled() {
        return primary;
    }
    let builtin = unsafe { ffi::air_builtin_display() }.to_string();
    displays
        .iter()
        .position(|display| display.name == builtin)
        .unwrap_or(primary)
}
pub(crate) fn native_result(code: i32) -> ResultType<()> {
    if code < 0 {
        bail!(unsafe { CStr::from_ptr(ffi::air_last_error()) }
            .to_string_lossy()
            .into_owned());
    }
    Ok(())
}
pub(crate) fn status(message: &str) {
    set_status(message, false);
}
pub(crate) fn error_status(message: &str) {
    set_status(message, true);
}
fn set_status(message: &str, error: bool) {
    eprintln!("{message}");
    if let Ok(text) = CString::new(message) {
        unsafe {
            ffi::air_status(text.as_ptr(), error as _);
        }
    }
}
pub fn capabilities() -> Option<SupportedDecoding> {
    let mode = CLIENT_MODE.load(Ordering::Relaxed);
    if mode == 0 {
        return None;
    }
    Some(SupportedDecoding {
        air_native_version: if workspace::requested() { 5 } else { 4 },
        air_remote_spaces: workspace::requested(),
        air_display: CLIENT_DISPLAY.lock().unwrap().clone().into(),
        air_mode: mode,
        ability_h264: unsafe { ffi::air_hardware_support(1) },
        ability_h265: unsafe { ffi::air_hardware_support(2) },
        prefer: if mode == 2 {
            supported_decoding::PreferCodec::H264
        } else {
            supported_decoding::PreferCodec::H265
        }
        .into(),
        ..Default::default()
    })
}

pub async fn connect() -> ResultType<(Stream, Vec<u8>)> {
    let pairing = PAIRING
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| anyhow!("No paired host"))?;
    network::connect(&pairing).await
}

fn render(packet: &[u8]) -> ResultType<()> {
    let mode = CLIENT_MODE.load(Ordering::Relaxed);
    if packet.starts_with(b"RDL1") && mode != 1 && mode != 4 {
        bail!("Unrequested Exact Lossless mode");
    }
    let expanded = apple_lz4::unpack(packet)?;
    let packet = expanded.as_ref();
    if packet.starts_with(b"RDA1") {
        if mode != 1 && mode != 4 {
            bail!("Unrequested Exact Lossless mode");
        }
        let update = Update::parse(packet)?;
        let mut state = EXACT.lock().unwrap();
        state.validate(&update)?;
        let first = state.sequence == 0;
        let upload_bytes: usize = update
            .patches
            .iter()
            .map(|p| ((p.width * 4 + 255) & !255) * p.height)
            .sum();
        unsafe {
            native_result(ffi::air_exact_begin(
                update.width as _,
                update.height as _,
                update.full as _,
                upload_bytes,
            ))?;
            for patch in &update.patches {
                if let Err(error) = native_result(ffi::air_exact_patch(
                    patch.x as _,
                    patch.y as _,
                    patch.width as _,
                    patch.height as _,
                    patch.bgra.as_ptr(),
                    patch.bgra.len(),
                )) {
                    ffi::air_exact_abort();
                    return Err(error);
                }
            }
            native_result(ffi::air_exact_commit())?;
        }
        state.commit(&update);
        if first {
            status(&format!(
                "RustDesk Air — exact pixels — {}×{} — ⌃⌥⌘Esc exits",
                update.width, update.height
            ));
        }
    } else if packet.starts_with(b"RDV1") {
        if CLIENT_MODE.load(Ordering::Relaxed) == 1 {
            bail!("Refusing lossy video in Exact Lossless mode");
        }
        let expected = if mode == 4 { 2 } else { mode - 1 };
        if packet.get(4..8) != Some(expected.to_le_bytes().as_slice()) {
            bail!("Unrequested hardware codec");
        }
        native_result(unsafe { ffi::air_decode(packet.as_ptr(), packet.len()) })?;
        if mode == 4 {
            EXACT.lock().unwrap().invalidate();
        }
    } else {
        bail!("Unsupported video codec; software decoding is disabled");
    }
    Ok(())
}
pub(crate) async fn host_notifications(
    mut incoming: tokio::sync::mpsc::UnboundedReceiver<crate::ipc::Data>,
    _outgoing: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
) {
    while let Some(event) = incoming.recv().await {
        if let crate::ipc::Data::Login { authorized, .. } = event {
            if authorized {
                status("RustDesk Air Host — paired client connected");
            }
        }
    }
}
pub async fn receive_video<T: InvokeUiSession>(
    frame: VideoFrame,
    session: &Session<T>,
    peer: &mut Stream,
) -> bool {
    let Some(video_frame::Union::AirVideo(packet)) = frame.union else {
        error_status("Hardware decoder unavailable — peer sent an unsupported video path");
        return false;
    };
    let packet_bytes = packet.len();
    if packet.starts_with(b"RDV1") {
        RECEIVED_VIDEO_FRAMES.fetch_add(1, Ordering::Relaxed);
    }
    ack_trace::record("air_receive", packet_bytes, std::time::Duration::ZERO, 0, true);
    unsafe {
        ffi::air_video_bytes(packet.len());
    }
    let recoverable_exact = (CLIENT_MODE.load(Ordering::Relaxed) == 1
        || CLIENT_MODE.load(Ordering::Relaxed) == 4)
        && (packet.starts_with(b"RDA1") || packet.starts_with(b"RDL1"));
    let render_started = ack_trace::enabled().then(std::time::Instant::now);
    let result = tokio::task::spawn_blocking(move || render(&packet))
        .await
        .map_err(|e| anyhow!(e))
        .and_then(|result| result);
    if let Some(started) = render_started {
        ack_trace::record("air_render_done", packet_bytes, started.elapsed(), 0, result.is_ok());
    }
    match result {
        Ok(()) => {}
        Err(error) => {
            EXACT.lock().unwrap().invalidate();
            eprintln!("Native video error: {error}");
            error_status(if recoverable_exact {
                "RustDesk Air — resynchronizing exact pixels"
            } else {
                "Hardware decoder unavailable"
            });
            session.refresh_video(frame.display);
            // A sequence gap can recover with a full frame; decoder failures end the session.
            if !recoverable_exact {
                shell::fatal_video();
                return false;
            }
        }
    }
    let mut misc = Misc::new();
    misc.set_video_received(true);
    let mut ack = Message::new();
    ack.set_misc(misc);
    let ack_started = ack_trace::enabled().then(std::time::Instant::now);
    let sent = peer.send(&ack).await.is_ok();
    if let Some(started) = ack_started {
        ack_trace::record("air_ack_sent", 0, started.elapsed(), 0, sent);
    }
    if sent { send_video_feedback(peer).await } else { false }
}

async fn send_video_feedback(peer: &mut Stream) -> bool {
    let now = std::time::Instant::now();
    {
        let mut last = LAST_FEEDBACK.lock().unwrap();
        if last.as_ref().is_some_and(|previous| now.duration_since(*previous) < std::time::Duration::from_millis(500)) {
            return true;
        }
        *last = Some(now);
    }
    let mut unique = 0;
    let mut missed = 0;
    unsafe { ffi::air_presentation_counters(&mut unique, &mut missed); }
    let sequence = FEEDBACK_SEQUENCE.fetch_add(1, Ordering::Relaxed) + 1;
    let mut payload = Vec::with_capacity(33);
    payload.push(1);
    for value in [sequence, RECEIVED_VIDEO_FRAMES.load(Ordering::Relaxed), unique, missed] {
        payload.extend_from_slice(&value.to_le_bytes());
    }
    let mut message = Message::new();
    message.set_air_control(AirControl { kind: 60, payload: payload.into(), ..Default::default() });
    peer.send(&message).await.is_ok()
}

fn refresh_client_display() -> ResultType<()> {
    if !MATCH_DISPLAY.load(Ordering::Relaxed) { return Ok(()); }
    let mut spec = NativeDisplaySpec::default();
    native_result(unsafe { ffi::air_display_current(&mut spec) })?;
    let spec = AirDisplaySpec {
        logical_width: spec.logical_width, logical_height: spec.logical_height,
        pixel_width: spec.pixel_width, pixel_height: spec.pixel_height,
        ..Default::default()
    };
    {
        let mut current = CLIENT_DISPLAY.lock().unwrap();
        if current.as_ref() == Some(&spec) { return Ok(()); }
        *current = Some(spec);
    }
    if let Some(session) = SESSION.lock().unwrap().clone() {
        let mut option = OptionMessage::new();
        option.supported_decoding = capabilities().into();
        let mut misc = Misc::new(); misc.set_option(option);
        let mut message = Message::new(); message.set_misc(misc);
        session.send(Data::Message(message));
    }
    Ok(())
}

extern "C" fn input(kind: i32, x: f64, y: f64, code: u32, flags: u64, _: *mut c_void) {
    if kind == 8 {
        if let Err(error) = refresh_client_display() { error_status(&error.to_string()); }
        return;
    }
    if !shell::accept_input() { return; }
    let mut msg = Message::new();
    if (1..=3).contains(&kind) || kind == 7 {
        let (ox, oy) = *DISPLAY_ORIGIN.lock().unwrap();
        let event = MouseEvent {
            mask: match kind {
                2 => 1 | (code as i32) << 3,
                3 => 2 | (code as i32) << 3,
                7 => 3,
                _ => 0,
            },
            x: if kind == 7 {
                x.round() as i32
            } else {
                x as i32 + ox
            },
            y: if kind == 7 {
                y.round() as i32
            } else {
                y as i32 + oy
            },
            ..Default::default()
        };
        msg.set_mouse_event(event);
    } else {
        let mut event = KeyEvent {
            down: kind == 4,
            mode: KeyboardMode::Map.into(),
            ..Default::default()
        };
        if kind == 6 {
            let mask = match code {
                54 | 55 => 1 << 20,
                56 | 60 => 1 << 17,
                58 | 61 => 1 << 19,
                59 | 62 => 1 << 18,
                63 => 1 << 23,
                _ => 0,
            };
            event.down = flags & mask != 0;
        }
        event.set_chr(code);
        msg.set_key_event(event);
    }
    shell::send_input(Data::Message(msg));
}

fn arg_value(args: &[String], name: &str) -> Option<String> {
    args.windows(2).find(|p| p[0] == name).map(|p| p[1].clone())
}
fn raw_probe_seconds(args: &[String], host: bool) -> ResultType<i32> {
    let count = args.iter().filter(|s| *s == "--probe-raw-contacts").count();
    if count == 0 { return Ok(0); }
    if count != 1 { bail!("Specify the raw-contact probe once"); }
    let seconds = arg_value(args, "--probe-raw-contacts")
        .ok_or_else(|| anyhow!("Raw-contact probe needs a duration of 1–60 seconds"))?
        .parse::<i32>()?;
    if !(1..=60).contains(&seconds) { bail!("Raw-contact probe duration must be 1–60 seconds"); }
    if args.iter().any(|s| matches!(s.as_str(), "--no-remote-mode" | "--no-raw-contacts" | "--inspect-spaces"
        | "--capture-input-test" | "--self-test" | "--self-test-renderer" | "--self-test-network")) {
        bail!("Raw-contact probe requires an authenticated Remote Mode session");
    }
    if !host && !args.iter().any(|s| s == "--remote-mode") {
        bail!("Raw-contact probe on the Air requires --remote-mode");
    }
    Ok(seconds)
}
fn keyboard_probe_requested(args: &[String], host: bool) -> ResultType<bool> {
    let count = args.iter().filter(|s| *s == "--test-keyboard-path").count();
    if count == 0 { return Ok(false); }
    if count != 1 { bail!("Specify the keyboard path probe once"); }
    if host { bail!("Keyboard path probe is available only in the Client"); }
    if !args.iter().any(|s| s == "--test-profile") || !args.iter().any(|s| s == "--remote-mode")
        || args.iter().any(|s| s == "--no-remote-mode") {
        bail!("Keyboard path probe requires Client --test-profile --remote-mode");
    }
    let quit_count = args.iter().filter(|s| *s == "--quit-after").count();
    let quit = arg_value(args, "--quit-after")
        .ok_or_else(|| anyhow!("Keyboard path probe requires --quit-after 15–60"))?
        .parse::<u64>()?;
    if quit_count != 1 || !(15..=60).contains(&quit) {
        bail!("Keyboard path probe requires one --quit-after value of 15–60 seconds");
    }
    if args.iter().any(|s| matches!(s.as_str(), "--capture-input-test" | "--capture-native-session"
        | "--probe-raw-contacts" | "--self-test" | "--self-test-renderer" | "--self-test-network"
        | "--inspect-spaces" | "--test-cursor-path")) {
        bail!("Keyboard path probe cannot run with another diagnostic");
    }
    Ok(true)
}
fn cursor_probe_requested(args: &[String], host: bool) -> ResultType<bool> {
    let count = args.iter().filter(|s| *s == "--test-cursor-path").count();
    if count == 0 { return Ok(false); }
    if count != 1 || host || !args.iter().any(|s| s == "--test-profile")
        || !args.iter().any(|s| s == "--remote-mode")
        || args.iter().any(|s| s == "--no-remote-mode") {
        bail!("Cursor path probe requires one Client --test-profile --remote-mode request");
    }
    let quit_count = args.iter().filter(|s| *s == "--quit-after").count();
    let quit = arg_value(args, "--quit-after")
        .ok_or_else(|| anyhow!("Cursor path probe requires --quit-after 45"))?
        .parse::<u64>()?;
    if quit_count != 1 || quit != 45 { bail!("Cursor path probe requires --quit-after 45"); }
    if args.iter().any(|s| matches!(s.as_str(), "--capture-input-test" | "--capture-native-session"
        | "--probe-raw-contacts" | "--self-test" | "--self-test-renderer" | "--self-test-network"
        | "--inspect-spaces" | "--test-keyboard-path" | "--self-test-pipeline")) {
        bail!("Cursor path probe cannot run with another diagnostic");
    }
    Ok(true)
}
#[cfg(test)]
mod raw_probe_tests {
    use super::{cursor_probe_requested,keyboard_probe_requested,raw_probe_seconds};

    #[test]
    fn raw_probe_requires_explicit_bounded_session_request() {
        let parse = |args: &[&str], host| raw_probe_seconds(
            &args.iter().map(|s| s.to_string()).collect::<Vec<_>>(), host);
        assert_eq!(parse(&["air"], false).unwrap(), 0);
        assert_eq!(parse(&["air", "--probe-raw-contacts", "60", "--remote-mode"], false).unwrap(), 60);
        assert_eq!(parse(&["host", "--probe-raw-contacts", "1"], true).unwrap(), 1);
        for args in [
            vec!["air", "--probe-raw-contacts"],
            vec!["air", "--probe-raw-contacts", "60"],
            vec!["air", "--probe-raw-contacts", "0", "--remote-mode"],
            vec!["air", "--probe-raw-contacts", "61", "--remote-mode"],
            vec!["air", "--probe-raw-contacts", "60", "--no-remote-mode", "--remote-mode"],
            vec!["air", "--probe-raw-contacts", "60", "--self-test", "--remote-mode"],
            vec!["air", "--probe-raw-contacts", "60", "--remote-mode", "--probe-raw-contacts", "1"],
        ] { assert!(parse(&args, false).is_err()); }
    }

    #[test]
    fn keyboard_probe_requires_isolated_bounded_test_client() {
        let parse = |args: &[&str], host| keyboard_probe_requested(
            &args.iter().map(|s| s.to_string()).collect::<Vec<_>>(), host);
        assert!(!parse(&["air"], false).unwrap());
        assert!(parse(&["air", "--test-keyboard-path", "--test-profile", "--remote-mode", "--quit-after", "55"], false).unwrap());
        for args in [
            vec!["air", "--test-keyboard-path", "--remote-mode", "--quit-after", "55"],
            vec!["air", "--test-keyboard-path", "--test-profile", "--remote-mode"],
            vec!["air", "--test-keyboard-path", "--test-profile", "--remote-mode", "--quit-after", "8"],
            vec!["air", "--test-keyboard-path", "--test-profile", "--remote-mode", "--quit-after", "61"],
            vec!["air", "--test-keyboard-path", "--test-profile", "--remote-mode", "--quit-after", "55", "--capture-native-session", "/tmp/x"],
            vec!["air", "--test-keyboard-path", "--test-profile", "--remote-mode", "--quit-after", "55", "--probe-raw-contacts", "5"],
            vec!["air", "--test-keyboard-path", "--test-profile", "--remote-mode", "--quit-after", "55", "--test-keyboard-path"],
        ] { assert!(parse(&args, false).is_err()); }
        assert!(parse(&["host", "--test-keyboard-path", "--test-profile", "--remote-mode", "--quit-after", "55"], true).is_err());
    }

    #[test]
    fn cursor_probe_requires_isolated_forty_five_second_client() {
        let parse = |args: &[&str], host| cursor_probe_requested(
            &args.iter().map(|s| s.to_string()).collect::<Vec<_>>(), host);
        assert!(!parse(&["air"], false).unwrap());
        assert!(parse(&["air", "--test-cursor-path", "--test-profile", "--remote-mode", "--quit-after", "45"], false).unwrap());
        for args in [
            vec!["air", "--test-cursor-path", "--remote-mode", "--quit-after", "45"],
            vec!["air", "--test-cursor-path", "--test-profile", "--quit-after", "45"],
            vec!["air", "--test-cursor-path", "--test-profile", "--remote-mode", "--quit-after", "46"],
            vec!["air", "--test-cursor-path", "--test-profile", "--remote-mode", "--quit-after", "45", "--test-keyboard-path"],
            vec!["air", "--test-cursor-path", "--test-profile", "--remote-mode", "--quit-after", "45", "--test-cursor-path"],
        ] { assert!(parse(&args, false).is_err()); }
        assert!(parse(&["host", "--test-cursor-path", "--test-profile", "--remote-mode", "--quit-after", "45"], true).is_err());
    }
}
pub fn run() -> ResultType<()> {
    let args: Vec<String> = std::env::args().collect();
    let host = args.iter().any(|s| s == "--host") || unsafe { ffi::air_is_host_bundle() != 0 };
    let raw_probe = raw_probe_seconds(&args, host)?;
    let keyboard_probe = keyboard_probe_requested(&args, host)?;
    let cursor_probe = cursor_probe_requested(&args, host)?;
    let native_capture = args.iter().any(|value| value == "--capture-native-session");
    if native_capture && args.iter().any(|value| value == "--capture-input-test") {
        bail!("Choose one native input capture mode");
    }
    if !native_capture && args.iter().any(|value| value == "--capture-native-seconds") {
        bail!("--capture-native-seconds requires --capture-native-session");
    }
    let native_capture_request = if native_capture {
        let path = arg_value(&args, "--capture-native-session").ok_or_else(|| anyhow!("Native session capture needs an absolute output path"))?;
        if !std::path::Path::new(&path).is_absolute() { bail!("Native session capture path must be absolute"); }
        let seconds = arg_value(&args, "--capture-native-seconds").unwrap_or_else(|| "60".into()).parse::<i32>()?;
        if !(1..=60).contains(&seconds) { bail!("Native session capture duration must be 1–60 seconds"); }
        Some((seconds,CString::new(path)?))
    } else { None };
    if native_capture && (args.iter().any(|value| value == "--host") || unsafe { ffi::air_is_host_bundle() != 0 }) {
        bail!("Native session capture is available only in an Air client session");
    }
    if native_capture && !args.iter().any(|value| value == "--remote-mode")
        && (args.iter().any(|value| value == "--no-remote-mode") || args.iter().any(|value| value == "--test-profile")) {
        bail!("Native session capture requires Remote Mode");
    }
    if args.iter().any(|s| s == "--inspect-spaces") {
        let report = unsafe { ffi::air_spaces_diagnostics() };
        if report.is_null() { bail!("Cannot inspect native workspace access"); }
        println!("{}", unsafe { CStr::from_ptr(report) }.to_string_lossy());
        return Ok(());
    }
    if let Some(path) = arg_value(&args, "--capture-input-test") {
        let seconds = arg_value(&args, "--seconds").unwrap_or_else(|| "45".into()).parse::<i32>()?;
        if !(1..=60).contains(&seconds) { bail!("Capture duration must be 1–60 seconds"); }
        let path = CString::new(path)?;
        native_result(unsafe { ffi::air_app_init(None, std::ptr::null_mut(), 0) })?;
        unsafe { ffi::air_input_capture_schedule(seconds, path.as_ptr()); ffi::air_app_run(); ffi::air_input_shutdown(); }
        return Ok(());
    }
    if args.iter().any(|s| s == "--self-test-network") {
        network::self_test()?;
        network::connection_self_test()?;
        println!("LAN-first route policy and legacy pairing: passed");
        return Ok(());
    }
    if args.iter().any(|s| s == "--self-test-pipeline") {
        native_result(unsafe { ffi::air_native_selftest() })?;
        for codec in [1, 2] {
            native_result(unsafe { ffi::air_codec_async_selftest(codec) })?;
        }
        println!("Bounded hardware encode pipeline: passed");
        return Ok(());
    }
    if args.iter().any(|s| s == "--self-test" || s == "--self-test-renderer") {
        native_result(unsafe { ffi::air_native_selftest() })?;
        native_result(unsafe { ffi::air_cursor_selftest() })?;
        if !args.iter().any(|s| s == "--self-test-renderer") {
            for codec in [1, 2] {
                native_result(unsafe { ffi::air_codec_selftest(codec) })?;
            }
            native_result(unsafe { ffi::air_transition_selftest() })?;
        }
        println!(
            "{}",
            unsafe { CStr::from_ptr(ffi::air_metrics()) }.to_string_lossy()
        );
        return Ok(());
    }
    *APP_NAME.write().unwrap() = if args.iter().any(|a| a == "--test-profile") {
        "RustDeskAirTest"
    } else {
        "RustDeskAir"
    }
    .into();
    hbb_common::sodiumoxide::init().map_err(|_| anyhow!("Cannot initialize encryption"))?;
    let _logger = hbb_common::init_log(false, if host { "air-host" } else { "air-client" });
    HOST.store(host, Ordering::Relaxed);
    native_result(unsafe { ffi::air_raw_probe_configure(raw_probe) })?;
    native_result(unsafe { ffi::air_keyboard_probe_configure(keyboard_probe as _) })?;
    native_result(unsafe { ffi::air_cursor_probe_configure(cursor_probe as _) })?;
    let raw_allowed = !args.iter().any(|s| s == "--no-raw-contacts");
    native_result(unsafe { ffi::air_raw_full_configure((host && raw_allowed && raw_probe == 0) as _) })?;
    let explicit_pairing = arg_value(&args, "--pairing");
    let pairing_path = explicit_pairing
        .as_ref()
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            Config::path(if host {
                "air-pairing"
            } else {
                "air-client-pairing"
            })
        });
    native_result(unsafe {
        ffi::air_app_init(
            if host { None } else { Some(input) },
            std::ptr::null_mut(),
            host as _,
        )
    })?;
    if let Some(seconds) = arg_value(&args, "--quit-after").and_then(|s| s.parse::<u64>().ok()) {
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(seconds));
            unsafe {
                ffi::air_app_stop();
            }
        });
    }
    let mut supervisor = None;
    if host {
        native_result(unsafe { ffi::air_spaces_recover() })?;
        let video_mbps = arg_value(&args, "--video-mbps")
            .unwrap_or_else(|| "12".into())
            .parse::<u32>()
            .context("Video bitrate must be 1–100 Mbps")?;
        if !(1..=100).contains(&video_mbps) {
            bail!("Video bitrate must be 1–100 Mbps");
        }
        native_result(unsafe { ffi::air_set_video_bitrate(video_mbps * 1_000_000) })?;
        let explicit_address = arg_value(&args, "--address");
        let refresh_network = explicit_address.is_none() && !args.iter().any(|a| a == "--test-profile");
        let address = explicit_address.clone().unwrap_or_else(|| {
            if refresh_network { return "127.0.0.1:21128".into(); }
            let ip = default_net::get_default_interface()
                .ok()
                .and_then(|interface| interface.ipv4.first().map(|ip| ip.addr.to_string()))
                .unwrap_or_else(|| "127.0.0.1".into());
            format!("{ip}:21128")
        });
        let port = address
            .rsplit(':')
            .next()
            .and_then(|p| p.parse::<u16>().ok())
            .ok_or_else(|| anyhow!("Invalid host port"))?;
        let pairing_lock = lock_pairing(&pairing_path)?;
        let pairing_existed = pairing_path.exists();
        let mut pairing = if pairing_existed {
            serde_json::from_slice::<Pairing>(&std::fs::read(&pairing_path)?)?
        } else {
            if Config::get_id().is_empty() {
                Config::set_id(&Config::get_auto_numeric_password(9));
            }
            let password = Config::get_auto_password(32);
            if !Config::set_permanent_password(&password) {
                bail!("Cannot save host password");
            }
            let (_, pk) = Config::get_key_pair();
            Pairing {
                version: 1,
                address: address.clone(),
                lan_addresses: Vec::new(),
                tailscale_addresses: Vec::new(),
                host_id: Config::get_id(),
                public_key: hex::encode(pk),
                password,
            }
        };
        if pairing.version != 1
            || pairing.host_id != Config::get_id()
            || hex::decode(&pairing.public_key)? != Config::get_key_pair().1
            || pairing.password.is_empty()
        {
            bail!("Pairing file does not belong to this host profile");
        }
        if !Config::set_permanent_password(&pairing.password) {
            bail!("Cannot save host password");
        }
        let routes_changed = if refresh_network {
            let (lan, tailscale) = network::advertised(port);
            network::refresh_routes(&mut pairing, port, lan, tailscale)
        } else {
            pairing.address = address.clone();
            (pairing.lan_addresses, pairing.tailscale_addresses) = network::advertised(port);
            true
        };
        save_host_pairing_if_needed_unlocked(&pairing_path, &pairing, pairing_existed, routes_changed)?;
        drop(pairing_lock);
        let pairing_cpath = CString::new(pairing_path.to_string_lossy().as_bytes())?;
        unsafe {
            ffi::air_host_pairing(pairing_cpath.as_ptr());
        }
        let shown_address = pairing.address.clone();
        if refresh_network {
            refresh_host_pairing(pairing_path.clone(), pairing, port);
        }
        Config::set_option("approve-mode".into(), "password".into());
        Config::set_option(
            "verification-method".into(),
            "use-permanent-password".into(),
        );
        audio::recover_default_input()?;
        Config::set_option("audio-input".into(), String::new());
        Config::set_option("enable-audio".into(), "Y".into());
        Config::set_option("enable-file-transfer".into(), "N".into());
        Config::set_option("enable-clipboard".into(), "N".into());
        std::thread::spawn(move || {
            if let Err(error) = host_listen(port) {
                status(&format!("Host stopped: {error}"));
            }
        });
        status(&format!("RustDesk Air Host — built-in display — {shown_address}"));
    } else {
        let import_path = if explicit_pairing.is_none()
            && (!pairing_path.exists() || args.iter().any(|a| a == "--choose-pairing"))
        {
            let selected = unsafe { ffi::air_choose_pairing() };
            if selected.is_null() {
                return Ok(());
            }
            PathBuf::from(
                unsafe { CStr::from_ptr(selected) }
                    .to_string_lossy()
                    .into_owned(),
            )
        } else {
            pairing_path.clone()
        };
        let mut pairing: Pairing = serde_json::from_slice(
            &std::fs::read(&import_path).context("Cannot read the host pairing file")?,
        )?;
        if pairing.version != 1
            || pairing.password.is_empty()
            || hex::decode(&pairing.public_key)?.len() != 32
        {
            bail!("Invalid pairing file");
        }
        if let Some(address) = arg_value(&args, "--address") {
            pairing.address = address;
        }
        if import_path != pairing_path {
            save_pairing(&pairing_path, &pairing)?;
        }
        let mut mode = match arg_value(&args, "--mode").as_deref().unwrap_or("exact") {
            "exact" => 1,
            "h264" => 2,
            "hevc" => 3,
            "adaptive" => 4,
            _ => bail!("Mode must be adaptive, exact, h264, or hevc"),
        };
        let mut match_display = args.iter().any(|s| s == "--match-display")
            || (!args.iter().any(|s| s == "--test-profile") && !args.iter().any(|s| s == "--no-match-display"));
        if args.len() == 1 {
            mode = unsafe { ffi::air_choose_mode() } as u32;
            if mode == 0 {
                return Ok(());
            }
            match_display = unsafe { ffi::air_chosen_display_match() != 0 };
        }
        let remote_mode = if args.len() == 1 { unsafe { ffi::air_chosen_remote_mode() != 0 } } else {
            args.iter().any(|s| s == "--remote-mode")
                || (!args.iter().any(|s| s == "--test-profile") && !args.iter().any(|s| s == "--no-remote-mode"))
        };
        let remote_spaces = remote_mode && if args.len() == 1 {
            unsafe { ffi::air_chosen_remote_spaces() != 0 }
        } else {
            args.iter().any(|s| s == "--remote-spaces")
                || (!args.iter().any(|s| s == "--test-profile") && !args.iter().any(|s| s == "--no-remote-spaces"))
        };
        let raw_required = remote_mode && raw_allowed && (args.len() != 1 || unsafe { ffi::air_chosen_raw_contacts() != 0 });
        native_result(unsafe { ffi::air_raw_full_configure((raw_required && raw_probe == 0) as _) })?;
        workspace::configure(remote_spaces);
        unsafe { ffi::air_overlay_setup(Some(workspace::choose), None); }
        unsafe { ffi::air_overlay_setup_reconnect(Some(workspace::reconnect)); }
        MATCH_DISPLAY.store(match_display, Ordering::Relaxed);
        refresh_client_display()?;
        unsafe { ffi::air_client_match_display(match_display as _, (!args.iter().any(|s| s == "--windowed")) as _); }
        CLIENT_MODE.store(mode, Ordering::Relaxed);
        let hardware_codec = if mode == 4 { 2 } else { mode - 1 };
        if mode > 1 && unsafe { ffi::air_hardware_support(hardware_codec as _) } == 0 {
            error_status("Hardware decoder unavailable");
            unsafe {
                ffi::air_app_run();
            }
            return Ok(());
        }
        let session = Session::<NativeUi> {
            password: pairing.password.clone(),
            server_keyboard_enabled: Arc::new(RwLock::new(true)),
            ..Default::default()
        };
        {
            let mut lc = session.lc.write().unwrap();
            lc.initialize(
                pairing.address.clone(),
                ConnType::DEFAULT_CONN,
                None,
                false,
                None,
                None,
                None,
            );
            lc.get_config().options.insert("disable-audio".into(), "N".into());
            lc.get_config().disable_audio.v = false;
            lc.get_config().options.insert("disable-clipboard".into(), "Y".into());
        }
        let microphone = !args.iter().any(|s| s == "--no-microphone");
        audio::configure_microphone(microphone);
        unsafe { ffi::air_microphone_menu(Some(microphone_changed), microphone as i32); }
        control::configure(remote_mode);
        control::configure_raw_required(raw_required);
        control::configure_native_capture(native_capture_request);
        if remote_mode {
            unsafe { ffi::air_input_space_swipe_callback(None); }
            native_result(unsafe { ffi::air_input_setup(Some(control::input_event), Some(control::native_release_input)) })?;
            unsafe { ffi::air_shell_begin(); }
        }
        *PAIRING.lock().unwrap() = Some(pairing);
        *SESSION.lock().unwrap() = Some(session.clone());
        let reconnect = args.iter().any(|s| s == "--reconnect") ||
            (!args.iter().any(|s| s == "--test-profile") && !args.iter().any(|s| s == "--no-reconnect"));
        supervisor = Some(shell::Supervisor::start(session, reconnect));
        status("RustDesk Air — connecting securely — ⌃⌥⌘Esc exits");
    }
    let mut cleanup = AppCleanup { supervisor: supervisor.as_ref(), native_capture, host, started: false, result: None };
    unsafe {
        ffi::air_app_set_cleanup(Some(app_cleanup), (&mut cleanup as *mut AppCleanup<'_>).cast());
        ffi::air_app_run();
        ffi::air_app_set_cleanup(None, std::ptr::null_mut());
    }
    cleanup.finish();
    cleanup.result.take().unwrap_or_else(|| Err(anyhow!("Air session cleanup did not finish")))
}

struct AppCleanup<'a> {
    supervisor: Option<&'a shell::Supervisor>,
    native_capture: bool,
    host: bool,
    started: bool,
    result: Option<ResultType<()>>,
}
extern "C" fn microphone_changed(enabled: i32) {
    audio::configure_microphone(enabled != 0);
}
impl AppCleanup<'_> {
    fn finish(&mut self) {
        if self.started { return; }
        self.started = true;
        self.result = Some(finish_session(self.supervisor, self.native_capture, self.host));
    }
}
extern "C" fn app_cleanup(context: *mut c_void) {
    if context.is_null() { return; }
    // Registered only while this stack context is alive; AppKit calls it synchronously on main.
    let cleanup = unsafe { &mut *context.cast::<AppCleanup<'_>>() };
    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| cleanup.finish())).is_err() {
        eprintln!("Air cleanup panicked; persisted restoration remains for the next Host start");
        cleanup.result = Some(Err(anyhow!("Air session cleanup panicked")));
    }
}
fn finish_session(supervisor: Option<&shell::Supervisor>, native_capture: bool, host: bool) -> ResultType<()> {
    let worker_stopped = if let Some(supervisor) = supervisor {
        supervisor.shutdown();
        supervisor.wait_stopped(std::time::Duration::from_secs(2))
    } else { true };
    if native_capture { unsafe { ffi::air_capture_v2_stop(); } }
    if worker_stopped { unsafe { ffi::air_input_shutdown(); } }
    else { eprintln!("Air connection worker did not stop within two seconds; native teardown deferred to process exit"); }
    unsafe { ffi::air_shell_end(); }
    if native_capture { println!("air_native_session_capture_final_status={}", unsafe { ffi::air_capture_v2_status() }); }
    let mut restore_error = None;
    if host {
        unsafe { ffi::air_host_input_shutdown(); }
        if let Err(error) = native_result(unsafe { ffi::air_display_shutdown() }) {
            eprintln!("Display restoration failed at Host shutdown: {error}");
            restore_error = Some(error);
        }
        if let Err(error) = native_result(unsafe { ffi::air_spaces_shutdown() }) {
            eprintln!("Workspace restoration failed at Host shutdown: {error}");
            if restore_error.is_none() { restore_error = Some(error); }
        }
    }
    if let Some(session) = SESSION.lock().unwrap().take() {
        session.send(Data::Close);
    }
    println!(
        "{}",
        unsafe { CStr::from_ptr(ffi::air_metrics()) }.to_string_lossy()
    );
    if !host { ack_trace::dump("air_session_end"); }
    if let Some(error) = restore_error { return Err(error); }
    Ok(())
}
fn same_pairing_identity(current: &Pairing, expected: &Pairing) -> bool {
    current.version == expected.version && current.host_id == expected.host_id
        && current.public_key == expected.public_key && current.password == expected.password
}

fn refresh_host_pairing(path: PathBuf, expected: Pairing, port: u16) {
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(5));
        let (lan, tailscale) = network::advertised(port);
        let _lock = match lock_pairing(&path) {
            Ok(lock) => lock,
            Err(error) => {
                eprintln!("Air pairing route refresh stopped: cannot lock pairing file: {error}");
                break;
            }
        };
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(_) => {
                eprintln!("Air pairing route refresh stopped: pairing file unavailable");
                break;
            }
        };
        let mut current = match serde_json::from_slice::<Pairing>(&bytes) {
            Ok(pairing) if same_pairing_identity(&pairing, &expected) => pairing,
            _ => {
                eprintln!("Air pairing route refresh stopped: pairing file changed or unavailable");
                break;
            }
        };
        if network::refresh_routes(&mut current, port, lan, tailscale) {
            if std::fs::read(&path).ok().as_deref() != Some(bytes.as_slice()) { continue; }
            if let Err(error) = save_pairing_unlocked(&path, &current) {
                eprintln!("Air pairing route refresh failed: {error}");
            }
        }
    });
}

fn pairing_file_private(path: &std::path::Path) -> ResultType<bool> {
    use std::os::unix::fs::PermissionsExt;
    let metadata = std::fs::symlink_metadata(path)?;
    Ok(metadata.file_type().is_file() && metadata.permissions().mode() & 0o777 == 0o600)
}

fn save_host_pairing_if_needed_unlocked(path: &std::path::Path, pairing: &Pairing,
    existed: bool, routes_changed: bool) -> ResultType<()> {
    if !existed || routes_changed || !pairing_file_private(path)? {
        save_pairing_unlocked(path, pairing)?;
    }
    Ok(())
}

fn lock_pairing(path: &std::path::Path) -> ResultType<std::fs::File> {
    use std::os::unix::{fs::{OpenOptionsExt, PermissionsExt}, io::AsRawFd};
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| std::path::Path::new("."));
    std::fs::create_dir_all(parent)?;
    let lock_path = parent.join(".rustdesk-air-pairing.lock");
    let lock = std::fs::OpenOptions::new().read(true).write(true).create(true)
        .mode(0o600).custom_flags(hbb_common::libc::O_NOFOLLOW).open(lock_path)?;
    lock.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    if unsafe { hbb_common::libc::flock(lock.as_raw_fd(), hbb_common::libc::LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(lock)
}

fn save_pairing(path: &std::path::Path, pairing: &Pairing) -> ResultType<()> {
    let _lock = lock_pairing(path)?;
    save_pairing_unlocked(path, pairing)
}

fn save_pairing_unlocked(path: &std::path::Path, pairing: &Pairing) -> ResultType<()> {
    let bytes = serde_json::to_vec_pretty(pairing)?;
    let temporary = stage_pairing(path, &bytes)?;
    if let Err(error) = std::fs::rename(&temporary, path) {
        if let Err(cleanup) = std::fs::remove_file(&temporary) {
            eprintln!("Cannot remove incomplete Air pairing file: {cleanup}");
        }
        return Err(error.into());
    }
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| std::path::Path::new("."));
    std::fs::File::open(parent)?.sync_all()?;
    Ok(())
}
fn stage_pairing(path: &std::path::Path, bytes: &[u8]) -> ResultType<PathBuf> {
    use std::{io::Write, os::unix::fs::{OpenOptionsExt, PermissionsExt}};
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| std::path::Path::new("."));
    std::fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".rustdesk-air-pairing-{}.tmp", uuid::Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let staged = file.set_permissions(std::fs::Permissions::from_mode(0o600))
        .and_then(|_| file.write_all(bytes)).and_then(|_| file.sync_all());
    drop(file);
    if let Err(error) = staged {
        if let Err(cleanup) = std::fs::remove_file(&temporary) {
            eprintln!("Cannot remove incomplete Air pairing file: {cleanup}");
        }
        return Err(error.into());
    }
    Ok(temporary)
}
#[cfg(test)]
mod pairing_save_tests {
    use super::*;
    use std::os::unix::{fs::PermissionsExt, io::AsRawFd};

    #[test]
    fn pairing_lock_serializes_independent_writers() {
        let directory = std::env::temp_dir().join(format!("rustdesk-air-lock-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("air-pairing");
        let first = lock_pairing(&path).unwrap();
        let second = std::fs::OpenOptions::new().read(true).write(true)
            .open(directory.join(".rustdesk-air-pairing.lock")).unwrap();
        let try_lock = || unsafe { hbb_common::libc::flock(second.as_raw_fd(),
            hbb_common::libc::LOCK_EX | hbb_common::libc::LOCK_NB) };
        assert_eq!(try_lock(), -1);
        drop(first);
        assert_eq!(try_lock(), 0);
        drop(second);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn interrupted_stage_keeps_prior_pairing_and_rename_is_private() {
        let directory = std::env::temp_dir().join(format!("rustdesk-air-pairing-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("air-pairing");
        let pairing = |address: &str| Pairing {
            version: 1, address: address.into(), lan_addresses: Vec::new(),
            tailscale_addresses: Vec::new(), host_id: "fixture".into(),
            public_key: "fixture".into(), password: "fixture-secret".into(),
        };
        let old = pairing("127.0.0.1:21128");
        let new = pairing("127.0.0.2:21128");
        save_pairing(&path, &old).unwrap();
        let original = std::fs::read(&path).unwrap();
        let staged = stage_pairing(&path, &serde_json::to_vec_pretty(&new).unwrap()).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert_eq!(std::fs::metadata(&staged).unwrap().permissions().mode() & 0o777, 0o600);
        std::fs::remove_file(staged).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        save_pairing(&path, &new).unwrap();
        assert_eq!(serde_json::from_slice::<Pairing>(&std::fs::read(&path).unwrap()).unwrap().address,
            "127.0.0.2:21128");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::read_dir(&directory).unwrap().count(), 2);
        let occupied = directory.join("occupied-target");
        std::fs::create_dir(&occupied).unwrap();
        assert!(save_pairing(&occupied, &old).is_err());
        assert!(occupied.is_dir());
        assert_eq!(std::fs::read_dir(&directory).unwrap().count(), 3);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn unchanged_host_routes_restore_private_pairing_permissions() {
        let directory = std::env::temp_dir().join(format!("rustdesk-air-mode-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("air-pairing");
        let pairing = Pairing {
            version: 1, address: "10.0.0.8:21128".into(),
            lan_addresses: vec!["10.0.0.8:21128".into()],
            tailscale_addresses: Vec::new(), host_id: "fixture".into(),
            public_key: "fixture".into(), password: "fixture-secret".into(),
        };
        save_pairing(&path, &pairing).unwrap();
        let original = std::fs::read(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let pairing_lock = lock_pairing(&path).unwrap();
        save_host_pairing_if_needed_unlocked(&path, &pairing, true, false).unwrap();
        drop(pairing_lock);
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert!(pairing_file_private(&path).unwrap());
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
pub fn report_error(error: &str) {
    eprintln!("{error}");
    if std::env::args().len() == 1 {
        if let Ok(message) = CString::new(error) {
            unsafe {
                ffi::air_show_error(message.as_ptr());
            }
        }
    }
}
#[tokio::main(flavor = "current_thread")]
async fn host_listen(port: u16) -> ResultType<()> {
    crate::common::set_server_running(true);
    let server = crate::server::new();
    let listener = hbb_common::tcp::listen_any(port).await?;
    loop {
        let (socket, addr) = listener.accept().await?;
        socket.set_nodelay(true)?;
        let local = socket.local_addr()?;
        let server = server.clone();
        tokio::spawn(async move {
            if let Err(error) = crate::server::create_tcp_connection(
                server,
                Stream::from(socket, local),
                addr,
                true,
                Default::default(),
            )
            .await
            {
                status(&format!("Connection rejected: {error}"));
            }
        });
    }
}
