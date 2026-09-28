use super::*;
use crate::air::{ffi, native_result};
use crate::air::quality::QualityController;
use rustdesk_air_protocol::{adaptive::{AdaptiveEncoder, Frame as AdaptiveFrame, Refresh as AdaptiveRefresh}, Encoder as ExactEncoder};

struct DisplayMatch;
impl Drop for DisplayMatch {
    fn drop(&mut self) {
        if let Err(error) = native_result(unsafe { ffi::air_display_restore() }) {
            crate::air::status(&format!("Display restoration failed: {error}"));
        }
    }
}
#[derive(Default)]
struct StageTiming { calls: u64, total_us: u64, max_us: u64 }
impl StageTiming {
    fn record(&mut self, started: Instant) {
        let elapsed = started.elapsed().as_micros().min(u64::MAX as u128) as u64;
        self.calls = self.calls.saturating_add(1);
        self.total_us = self.total_us.saturating_add(elapsed);
        self.max_us = self.max_us.max(elapsed);
    }
}
struct HostProfile {
    started: Instant,
    capture_wait: StageTiming,
    capture_timeouts: u64,
    // Adaptive mode includes classification; Exact mode includes packet construction.
    exact_diff: StageTiming,
    video_encode: StageTiming,
    exact_pack: StageTiming,
    credit_wait: StageTiming,
    credit_blocks: u64,
    send_attempts: u64,
    sent_exact: u64,
    sent_video: u64,
    sent_exact_bytes: u64,
    sent_video_bytes: u64,
    recipients: u64,
}
impl HostProfile {
    fn new() -> Self {
        Self { started: Instant::now(), capture_wait: StageTiming::default(), capture_timeouts: 0,
            exact_diff: StageTiming::default(),
            video_encode: StageTiming::default(), exact_pack: StageTiming::default(),
            credit_wait: StageTiming::default(), credit_blocks: 0, send_attempts: 0,
            sent_exact: 0, sent_video: 0, sent_exact_bytes: 0, sent_video_bytes: 0, recipients: 0 }
    }
    fn sent(&mut self, bytes: usize, exact: bool, recipients: usize) {
        self.send_attempts = self.send_attempts.saturating_add(1);
        self.recipients = self.recipients.saturating_add(recipients as u64);
        if recipients == 0 { return; }
        if exact {
            self.sent_exact = self.sent_exact.saturating_add(1);
            self.sent_exact_bytes = self.sent_exact_bytes.saturating_add(bytes as u64);
        } else {
            self.sent_video = self.sent_video.saturating_add(1);
            self.sent_video_bytes = self.sent_video_bytes.saturating_add(bytes as u64);
        }
    }
    fn emit(&self, capture: crate::air::NativeCaptureProfile, started: bool) {
        let stage = |value: &StageTiming| serde_json::json!({
            "calls": value.calls, "total_us": value.total_us, "max_us": value.max_us
        });
        let native_stage = |value: &crate::air::NativeStageTiming| serde_json::json!({
            "calls": value.calls, "total_us": value.total_us, "max_us": value.max_us
        });
        eprintln!("air_host_profile={}", serde_json::json!({
            "schema": 1, "elapsed_ms": self.started.elapsed().as_millis().min(u64::MAX as u128) as u64,
            "capture_started": started,
            "capture_complete_callbacks": capture.complete_callbacks,
            "capture_latest_overwrites": capture.latest_overwrites,
            "capture_next_successes": capture.next_successes,
            "capture_next_wait": stage(&self.capture_wait),
            "capture_next_timeouts": self.capture_timeouts,
            "exact_diff": stage(&self.exact_diff), "video_encode": stage(&self.video_encode),
            "video_encode_submit": native_stage(&capture.encode_submit),
            "video_encode_complete_wait": native_stage(&capture.encode_complete_wait),
            "exact_pack": stage(&self.exact_pack), "ack_credit_wait": stage(&self.credit_wait),
            "ack_credit_blocks": self.credit_blocks, "send_attempts": self.send_attempts,
            "sent_exact_frames": self.sent_exact, "sent_video_frames": self.sent_video,
            "sent_exact_bytes": self.sent_exact_bytes, "sent_video_bytes": self.sent_video_bytes,
            "peer_recipients": self.recipients
        }));
    }
}
struct Capture(*mut std::ffi::c_void, Option<HostProfile>);
fn profile_requested(value: Option<&std::ffi::OsStr>) -> bool {
    value == Some(std::ffi::OsStr::new("1"))
}
impl Drop for Capture {
    fn drop(&mut self) {
        unsafe {
            if let Some(profile) = self.1.as_ref() {
                let mut capture = crate::air::NativeCaptureProfile::default();
                ffi::air_capture_stop_profiled(self.0, &mut capture);
                profile.emit(capture, !self.0.is_null());
            } else {
                ffi::air_capture_stop(self.0);
            }
        }
    }
}
fn refresh_workspace(
    vs: &VideoService,
    poll: &mut Option<crate::air::workspace::StatePoll>,
    message: &mut Message,
) {
    if let Some(state) = poll.as_mut().and_then(|poll| poll.changed()) {
        message.set_air_control(state);
        vs.sp.send(message.clone());
    }
}
fn send_pipeline_video(
    vs: &VideoService,
    flow: &mut crate::air::flow::Window,
    profile: Option<&mut HostProfile>,
    packet: Vec<u8>,
    width: u32,
    height: u32,
    mode: u32,
    frames: &mut u64,
) -> bool {
    let packet_len = packet.len();
    let acknowledgement_timeout = Duration::from_secs(5 + (packet_len as u64 / 1_000_000).min(25));
    let mut frame = VideoFrame::new();
    frame.display = vs.idx as _;
    frame.set_air_video(packet.into());
    let mut message = Message::new();
    message.set_video_frame(frame);
    let recipients = vs.sp.send_video_frame(message);
    let delivered = !recipients.is_empty();
    crate::air::ack_trace::record("host_enqueue", packet_len, Duration::ZERO, 0, !recipients.is_empty());
    if let Some(profile) = profile { profile.sent(packet_len, false, recipients.len()); }
    flow.sent(recipients, acknowledgement_timeout);
    *frames += 1;
    if *frames == 1 {
        crate::air::status(&format!("RustDesk Air Host — streaming {}×{} — mode {}", width, height, mode));
    }
    delivered
}
pub(super) fn run(vs: VideoService) -> ResultType<()> {
    let result = run_inner(&vs);
    crate::air::workspace::end_host_session();
    if let Err(error) = &result {
        if error.to_string() != "SWITCH" {
            let reason = format!("RustDesk Air capture stopped: {error}");
            crate::air::status(&reason);
            let mut misc = Misc::new();
            misc.set_close_reason(reason);
            let mut message = Message::new();
            message.set_misc(misc);
            vs.sp.snapshot(|subscriber| {
                subscriber.send(message.clone());
                Ok(())
            })?;
            vs.sp.send(message);
        }
    }
    result
}
fn run_inner(vs: &VideoService) -> ResultType<()> {
    let _raii = Raii::new(vs.idx, vs.sp.name());
    if !vs.source.is_monitor() {
        bail!("RustDesk Air supports only its built-in display");
    }
    let mode =
        Encoder::air_mode().ok_or_else(|| anyhow!("Peer must negotiate native Air video"))?;
    let builtin = unsafe { ffi::air_builtin_display() };
    let displays = Display::all()?;
    let selected = displays
        .get(vs.idx)
        .ok_or_else(|| anyhow!("Display is unavailable"))?;
    if selected.name() != builtin.to_string() {
        bail!("Only the built-in Retina display may be streamed");
    }
    let requested_display = Encoder::air_display().map_err(|error| anyhow!(error))?;
    let requested_spaces = Encoder::air_remote_spaces().map_err(|error| anyhow!(error))?;
    crate::air::workspace::begin_host_session(requested_spaces);
    let mut spaces = if requested_spaces {
        match crate::air::workspace::Session::prepare() {
            Ok(session) => Some(session),
            Err(error) => {
                crate::air::workspace::restore_checked()
                    .map_err(|restore| anyhow!("{error}; workspace recovery failed: {restore}"))?;
                log::warn!("Remote Spaces preparation failed: {error}");
                crate::air::status(&format!("Window migration unavailable; continuing built-in capture after verified recovery: {error}"));
                None
            }
        }
    } else { None };
    let _display_match = DisplayMatch;
    if let Some(spec) = requested_display.as_ref() {
        let native = crate::air::NativeDisplaySpec {
            logical_width: spec.logical_width, logical_height: spec.logical_height,
            pixel_width: spec.pixel_width, pixel_height: spec.pixel_height,
        };
        native_result(unsafe { ffi::air_display_match(&native) })?;
        display_service::check_displays_changed()?;
    }
    if let Some(session) = spaces.as_ref() {
        if let Err(error) = session.activate() {
            // Restore display geometry before restoring original window frames,
            // matching the normal guard-drop order. A failed recovery is fatal.
            native_result(unsafe { ffi::air_display_restore() })?;
            crate::air::workspace::restore_checked()
                .map_err(|restore| anyhow!("{error}; workspace recovery failed: {restore}"))?;
            spaces = None;
            display_service::check_displays_changed()?;
            log::warn!("Remote Spaces activation failed: {error}");
            crate::air::status(&format!("Window migration unavailable; continuing built-in capture after verified recovery: {error}"));
        }
    }
    let mut workspace_message = Message::new();
    let workspace_state = crate::air::workspace::state();
    let mut workspace_poll = requested_spaces.then(|| crate::air::workspace::StatePoll::new(workspace_state.clone()));
    workspace_message.set_air_control(workspace_state);
    vs.sp.send(workspace_message.clone());
    let display_message = make_display_changed_msg(vs.idx, None, VideoSource::Monitor);
    if let Some(message) = display_message.as_ref() { vs.sp.send(message.clone()); }
    let profile = profile_requested(std::env::var_os("RUSTDESK_AIR_PROFILE").as_deref());
    let pipeline = mode > 1 && profile_requested(std::env::var_os("RUSTDESK_AIR_ENCODE_PIPELINE").as_deref());
    let mut capture = Capture(unsafe { ffi::air_capture_start(builtin, profile as i32) },
                              profile.then(HostProfile::new));
    if capture.0.is_null() {
        native_result(-1)?;
    }
    let mut epoch = hbb_common::rand::random::<u64>();
    if epoch == 0 {
        epoch = 1;
    }
    let mut exact = ExactEncoder::new(epoch)?;
    let mut adaptive = AdaptiveEncoder::new(epoch)?;
    let mut flow = if mode > 1 { Some(crate::air::flow::Window::new()) } else { None };
    let clock = Instant::now();
    let mut quality = (mode == 4).then(|| QualityController::new(unsafe { ffi::air_capture_video_bitrate(capture.0) }));
    let mut quality_peer: Option<(i32, u64, Instant)> = None;
    let mut sent_video_total = 0u64;
    let mut credit_blocked_ms_total = 0u64;
    let mut window_limit = 3;
    let mut controller = VideoFrameController::new(vs.idx);
    let mut last_refresh = Instant::now();
    let mut force_full = true;
    let mut frames = 0u64;
    let mut pending_video: Option<(u32, u32)> = None;
    let mut last_adaptive_exact: Option<bool> = None;
    while vs.sp.ok() {
        if requested_spaces && crate::air::workspace::take_reconnect_request() {
            let retry = (|| -> ResultType<()> {
                if let Some(session) = spaces.as_mut() {
                    session.restore()?;
                    spaces = None;
                }
                match crate::air::workspace::Session::prepare() {
                    Ok(session) => match session.activate() {
                        Ok(()) => { spaces = Some(session); Ok(()) }
                        Err(error) => Err(error),
                    },
                    Err(error) => {
                        crate::air::workspace::restore_checked()
                            .map_err(|restore| anyhow!("{error}; workspace recovery failed: {restore}"))?;
                        Err(error)
                    }
                }
            })();
            match retry {
                Ok(()) => { force_full = true; log::info!("Remote Spaces reconnect succeeded"); }
                Err(error) => log::warn!("Remote Spaces reconnect failed: {error}"),
            }
            crate::air::workspace::reconnect_finished();
            let state = crate::air::workspace::state();
            workspace_message.set_air_control(state.clone());
            workspace_poll = Some(crate::air::workspace::StatePoll::new(state));
            vs.sp.send(workspace_message.clone());
        }
        refresh_workspace(vs, &mut workspace_poll, &mut workspace_message);
        if let Some(flow) = flow.as_mut() {
            let reports = flow.take_feedback();
            if flow.peer_count() != 1 {
                quality_peer = None;
                if let Some(controller) = quality.as_mut() { controller.reset_measurement(); }
            } else {
                for (id, report) in reports {
                    if quality_peer.as_ref().map(|(peer, _, _)| *peer) != Some(id) {
                        if let Some(controller) = quality.as_mut() { controller.reset_measurement(); }
                    }
                    quality_peer = Some((id, report.unique_presented_video, Instant::now()));
                    if profile {
                        eprintln!("air_quality_feedback={}", serde_json::json!({
                            "elapsed_ms": clock.elapsed().as_millis(),
                            "peer": id, "sequence": report.sequence,
                            "received_video": report.received_video,
                            "unique_presented_video": report.unique_presented_video,
                            "drawable_drops": report.drawable_drops,
                            "sent_video": sent_video_total,
                        }));
                    }
                }
            }
            let mut disable_quality = false;
            if let Some(controller) = quality.as_mut() {
                let age = quality_peer.as_ref().map(|(_, _, at)| at.elapsed().as_millis() as u64);
                let presented = quality_peer.as_ref().map_or(0, |(_, count, _)| *count);
                if let Some(target) = controller.sample(clock.elapsed().as_millis() as u64,
                                                        sent_video_total, presented,
                                                        credit_blocked_ms_total, age) {
                    if let Err(error) = native_result(unsafe { ffi::air_capture_set_video_bitrate(capture.0, target) }) {
                        eprintln!("air_quality_disabled: {error}");
                        disable_quality = true;
                    } else if profile {
                        eprintln!("air_quality_update={}", serde_json::json!({
                            "elapsed_ms": clock.elapsed().as_millis(), "bitrate_bps": target,
                            "sent_video": sent_video_total, "presented_video": presented,
                            "credit_blocked_ms": credit_blocked_ms_total,
                        }));
                    }
                }
            }
            if disable_quality { quality = None; }
            let credit_was_full = flow.pending_count() >= window_limit;
            let credit_started = Instant::now();
            let ready_result = flow.ready(window_limit);
            // An ACK can arrive during the wait and return ready=true. That
            // time still delayed the stream and must reach the quality controller.
            if credit_was_full && ready_result.is_ok() {
                credit_blocked_ms_total = credit_blocked_ms_total
                    .saturating_add(credit_started.elapsed().as_millis() as u64);
            }
            if let Some(profile) = capture.1.as_mut().filter(|_| credit_was_full) {
                profile.credit_wait.record(credit_started);
                if matches!(ready_result, Ok(false)) {
                    profile.credit_blocks = profile.credit_blocks.saturating_add(1);
                }
            }
            if !ready_result.map_err(|error| anyhow!(error))? { continue; }
        }
        if Encoder::air_mode() != Some(mode)
            || Encoder::air_display().map_err(|error| anyhow!(error))? != requested_display
            || Encoder::air_remote_spaces().map_err(|error| anyhow!(error))? != requested_spaces {
            bail!("SWITCH");
        }
        let mut joined = false;
        vs.sp.snapshot(|subscriber| {
            subscriber.send(workspace_message.clone());
            if let Some(message) = display_message.as_ref() { subscriber.send(message.clone()); }
            force_full = true;
            joined = true;
            Ok(())
        })?;
        if vs.sp.is_option_true(OPTION_REFRESH) {
            vs.sp.set_option_bool(OPTION_REFRESH, false);
            force_full = true;
        }
        let periodic_due = last_refresh.elapsed() >= Duration::from_secs(10);
        let refresh_due = force_full || periodic_due;
        let (mut bytes, mut len, mut width, mut height, mut stride) =
            (std::ptr::null(), 0, 0, 0, 0);
        let capture_started = capture.1.as_ref().map(|_| Instant::now());
        let result = unsafe {
            ffi::air_capture_next(
                capture.0,
                &mut bytes,
                &mut len,
                &mut width,
                &mut height,
                &mut stride,
                250,
            )
        };
        if let (Some(profile), Some(started)) = (capture.1.as_mut(), capture_started) {
            profile.capture_wait.record(started);
            if result == 0 && (!pipeline || started.elapsed() >= Duration::from_millis(240)) {
                profile.capture_timeouts = profile.capture_timeouts.saturating_add(1);
            }
        }
        native_result(result)?;
        let mut ready_video = None;
        if let Some((video_width, video_height)) = pending_video.take() {
            let (mut video_bytes, mut video_len) = (std::ptr::null(), 0);
            let encode_started = capture.1.as_ref().map(|_| Instant::now());
            let encoded = native_result(unsafe { ffi::air_encode_finish(capture.0, &mut video_bytes, &mut video_len) });
            if let (Some(profile), Some(started)) = (capture.1.as_mut(), encode_started) {
                profile.video_encode.record(started);
            }
            encoded?;
            if !joined {
                let packet = unsafe { std::slice::from_raw_parts(video_bytes, video_len) }.to_vec();
                ready_video = Some((packet, video_width, video_height));
            }
        }
        let mut exact_packet = mode == 1;
        let packet = if mode == 4 {
            let source = if result == 0 { None } else {
                Some((unsafe { std::slice::from_raw_parts(bytes, len) }, width as usize, height as usize, stride as usize))
            };
            let exact_started = (capture.1.is_some() && source.is_some()).then(Instant::now);
            let refresh = if force_full { AdaptiveRefresh::Full }
                else if periodic_due { AdaptiveRefresh::Periodic }
                else { AdaptiveRefresh::None };
            let decision = adaptive.encode(source, clock.elapsed().as_millis() as u64, refresh);
            if let (Some(profile), Some(started)) = (capture.1.as_mut(), exact_started) {
                profile.exact_diff.record(started);
            }
            match decision? {
                Some(AdaptiveFrame::Exact(packet)) => {
                    if profile && last_adaptive_exact != Some(true) {
                        eprintln!("air_adaptive_transition={}", serde_json::json!({
                            "elapsed_ms": clock.elapsed().as_millis(), "kind": "exact",
                            "periodic_or_join_refresh": refresh_due,
                        }));
                    }
                    last_adaptive_exact = Some(true);
                    exact_packet = true;
                    Some(packet)
                }
                Some(AdaptiveFrame::Video { keyframe }) => {
                    if profile && (last_adaptive_exact != Some(false) || keyframe) {
                        eprintln!("air_adaptive_transition={}", serde_json::json!({
                            "elapsed_ms": clock.elapsed().as_millis(), "kind": "video",
                            "keyframe": keyframe,
                        }));
                    }
                    last_adaptive_exact = Some(false);
                    if pipeline {
                        let encode_started = capture.1.as_ref().map(|_| Instant::now());
                        let submitted = native_result(unsafe { ffi::air_encode_submit(capture.0, 2, keyframe as _) });
                        if let (Some(profile), Some(started)) = (capture.1.as_mut(), encode_started) {
                            profile.video_encode.record(started);
                        }
                        submitted?;
                        pending_video = Some((width, height));
                        if refresh_due { last_refresh = Instant::now(); force_full = false; }
                        None
                    } else {
                        let encode_started = capture.1.as_ref().map(|_| Instant::now());
                        let encoded = native_result(unsafe { ffi::air_encode(capture.0, 2, &mut bytes, &mut len, keyframe as _) });
                        if let (Some(profile), Some(started)) = (capture.1.as_mut(), encode_started) {
                            profile.video_encode.record(started);
                        }
                        encoded?;
                        Some(unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec())
                    }
                }
                None => None,
            }
        } else if result == 0 {
            if mode == 1 && refresh_due {
                exact.resynchronize()?
            } else if pipeline {
                None
            } else {
                continue;
            }
        } else if mode == 1 {
            let source = unsafe { std::slice::from_raw_parts(bytes, len) };
            let exact_started = capture.1.as_ref().map(|_| Instant::now());
            let encoded = exact.encode(source, width as _, height as _, stride as _, refresh_due);
            if let (Some(profile), Some(started)) = (capture.1.as_mut(), exact_started) {
                profile.exact_diff.record(started);
            }
            encoded?
        } else {
            if pipeline {
                let encode_started = capture.1.as_ref().map(|_| Instant::now());
                let submitted = native_result(unsafe { ffi::air_encode_submit(capture.0, (mode - 1) as _, refresh_due as _) });
                if let (Some(profile), Some(started)) = (capture.1.as_mut(), encode_started) {
                    profile.video_encode.record(started);
                }
                submitted?;
                pending_video = Some((width, height));
                if refresh_due { last_refresh = Instant::now(); force_full = false; }
                None
            } else {
                let encode_started = capture.1.as_ref().map(|_| Instant::now());
                let encoded = native_result(unsafe {
                    ffi::air_encode(
                        capture.0,
                        (mode - 1) as _,
                        &mut bytes,
                        &mut len,
                        refresh_due as _,
                    )
                });
                if let (Some(profile), Some(started)) = (capture.1.as_mut(), encode_started) {
                    profile.video_encode.record(started);
                }
                encoded?;
                Some(unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec())
            }
        };
        unsafe {
            ffi::air_capture_release_frame(capture.0);
        }
        let mut pending_sent = false;
        if let Some((packet, video_width, video_height)) = ready_video {
            let flow = flow.as_mut().ok_or_else(|| anyhow!("Asynchronous video requires acknowledgement flow control"))?;
            if send_pipeline_video(vs, flow, capture.1.as_mut(), packet, video_width, video_height, mode, &mut frames) {
                sent_video_total = sent_video_total.saturating_add(1);
            }
            window_limit = 3;
            pending_sent = true;
        }
        let Some(packet) = packet else {
            continue;
        };
        if pending_sent && exact_packet {
            if let Some(flow) = flow.as_mut() {
                while !flow.ready(3).map_err(|error| anyhow!(error))? {
                    if !vs.sp.ok() { return Ok(()); }
                    refresh_workspace(vs, &mut workspace_poll, &mut workspace_message);
                }
            }
        }
        let packet = if exact_packet {
            let pack_started = capture.1.as_ref().map(|_| Instant::now());
            let packed = rustdesk_air_protocol::apple_lz4::pack(packet);
            if let (Some(profile), Some(started)) = (capture.1.as_mut(), pack_started) {
                profile.exact_pack.record(started);
            }
            packed?
        } else { packet };
        let packet_len = packet.len();
        let acknowledgement_timeout =
            Duration::from_secs(5 + (packet.len() as u64 / 1_000_000).min(25));
        if refresh_due {
            last_refresh = Instant::now();
            force_full = false;
        }
        let mut frame = VideoFrame::new();
        frame.display = vs.idx as _;
        frame.set_air_video(packet.into());
        let mut message = Message::new();
        message.set_video_frame(frame);
        if let Some(flow) = flow.as_mut() {
            // Large exact refreshes drain before more work is sent. Video has
            // three credits so round trips overlap without an unbounded queue.
            window_limit = if exact_packet { 1 } else { 3 };
            let recipients = vs.sp.send_video_frame(message);
            if !exact_packet && !recipients.is_empty() {
                sent_video_total = sent_video_total.saturating_add(1);
            }
            crate::air::ack_trace::record("host_enqueue", packet_len, Duration::ZERO, 0, !recipients.is_empty());
            if let Some(profile) = capture.1.as_mut() {
                profile.sent(packet_len, exact_packet, recipients.len());
            }
            flow.sent(recipients, acknowledgement_timeout);
            frames += 1;
            if frames == 1 { crate::air::status(&format!("RustDesk Air Host — streaming {}×{} — mode {}", width, height, mode)); }
            continue;
        }
        controller.reset();
        let send_started = Instant::now();
        let recipients = vs.sp.send_video_frame(message);
        crate::air::ack_trace::record("host_enqueue", packet_len, Duration::ZERO, 0, !recipients.is_empty());
        if let Some(profile) = capture.1.as_mut() {
            profile.sent(packet_len, exact_packet, recipients.len());
        }
        controller.set_send(send_started, recipients);
        let mut received = HashSet::new();
        let began = Instant::now();
        while !controller.all_sent_peers_acknowledged(&received) {
            if !vs.sp.ok() {
                return Ok(());
            }
            refresh_workspace(vs, &mut workspace_poll, &mut workspace_message);
            controller.try_wait_next(&mut received, 100);
            if began.elapsed() > acknowledgement_timeout {
                crate::air::ack_trace::dump("host_exact_ack_timeout");
                eprintln!(
                    "air_video_ack_timeout packet_bytes={} recipients={} acknowledged={} unrelated_notifications={} elapsed_ms={}",
                    packet_len,
                    controller.send_conn_ids.len(),
                    controller.acknowledged_count(&received),
                    received.len().saturating_sub(controller.acknowledged_count(&received)),
                    began.elapsed().as_millis(),
                );
                bail!("Native video acknowledgement timed out");
            }
        }
        if let Some(profile) = capture.1.as_mut() { profile.credit_wait.record(began); }
        DISPLAY_CONN_IDS.lock().unwrap().remove(&vs.idx);
        frames += 1;
        if frames == 1 {
            crate::air::status(&format!(
                "RustDesk Air Host — streaming {}×{} — mode {}",
                width, height, mode
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod profile_tests {
    use super::*;

    #[test]
    fn native_stage_layout_matches_capture_abi() {
        assert_eq!(std::mem::size_of::<crate::air::NativeStageTiming>(), 24);
        assert_eq!(std::mem::size_of::<crate::air::NativeCaptureProfile>(), 72);
        assert_eq!(std::mem::offset_of!(crate::air::NativeCaptureProfile, encode_submit), 24);
        assert_eq!(std::mem::offset_of!(crate::air::NativeCaptureProfile, encode_complete_wait), 48);
    }

    #[test]
    fn profiling_requires_explicit_opt_in() {
        assert!(!profile_requested(None));
        assert!(!profile_requested(Some(std::ffi::OsStr::new("0"))));
        assert!(!profile_requested(Some(std::ffi::OsStr::new("true"))));
        assert!(profile_requested(Some(std::ffi::OsStr::new("1"))));
    }

    #[test]
    fn sent_accounting_excludes_unsubscribed_frames() {
        let mut profile = HostProfile::new();
        profile.sent(100, true, 0);
        profile.sent(200, true, 2);
        profile.sent(300, false, 1);
        assert_eq!(profile.send_attempts, 3);
        assert_eq!(profile.recipients, 3);
        assert_eq!((profile.sent_exact, profile.sent_exact_bytes), (1, 200));
        assert_eq!((profile.sent_video, profile.sent_video_bytes), (1, 300));
    }

    #[test]
    fn unrelated_video_ack_cannot_release_exact_frame() {
        let mut controller = VideoFrameController::new(0);
        controller.send_conn_ids = HashSet::from([7, 8]);
        let mut received = HashSet::from([7, 99]);
        assert_eq!(controller.acknowledged_count(&received), 1);
        assert!(!controller.all_sent_peers_acknowledged(&received));
        received.insert(8);
        assert!(controller.all_sent_peers_acknowledged(&received));
    }
}
