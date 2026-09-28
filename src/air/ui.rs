use crate::{client::QualityStatus, ui_session_interface::InvokeUiSession};
use base::message_proto::*;
use hbb_common::rendezvous_proto::ConnType;
#[derive(Clone, Default)]
pub struct NativeUi;
// File transfer, chat, and recording are not enabled by this UI.
#[allow(unused_variables)]
impl InvokeUiSession for NativeUi {
    fn set_cursor_data(&self, _cd: CursorData) {}

    fn set_cursor_id(&self, _id: String) {}

    fn set_cursor_position(&self, _cp: CursorPosition) {}

    fn set_display(&self, x: i32, y: i32, w: i32, h: i32, cursor_embedded: bool, scale: f64) {
        *super::DISPLAY_ORIGIN.lock().unwrap() = (x, y);
        if w > 0 && h > 0 {
            unsafe {
                super::ffi::air_input_dimensions(w as _, h as _);
            }
        }
    }

    fn switch_display(&self, display: &SwitchDisplay) {
        *super::DISPLAY_ORIGIN.lock().unwrap() = (display.x, display.y);
        if display.width > 0 && display.height > 0 {
            unsafe {
                super::ffi::air_input_dimensions(display.width as _, display.height as _);
            }
        }
    }

    fn set_peer_info(&self, peer_info: &PeerInfo) {
        super::shell::mark_connected();
        super::control::hello();
        super::audio::request_on_connected();
    }

    fn set_displays(&self, displays: &Vec<DisplayInfo>) {}

    fn set_platform_additions(&self, data: &str) {}

    fn on_connected(&self, conn_type: ConnType) {}

    fn update_privacy_mode(&self) {}

    fn set_permission(&self, name: &str, value: bool) {}

    fn close_success(&self) {}

    fn update_quality_status(&self, qs: QualityStatus) {}

    fn set_connection_type(&self, is_secured: bool, direct: bool, stream_type: &str) {
        super::status(if is_secured {
            "RustDesk Air — encrypted session — ⌃⌥⌘Esc exits"
        } else {
            "Connection refused: encryption required"
        });
    }

    fn set_fingerprint(&self, fingerprint: String) {}

    fn job_error(&self, id: i32, err: String, file_num: i32) {}

    fn job_done(&self, id: i32, file_num: i32) {}

    fn clear_all_jobs(&self) {}

    fn new_message(&self, msg: String) {}

    fn update_transfer_list(&self) {}

    fn load_last_job(&self, cnt: i32, job_json: &str, auto_start: bool) {}

    fn update_folder_files(
        &self,
        id: i32,
        entries: &Vec<FileEntry>,
        path: String,
        is_local: bool,
        only_count: bool,
    ) {
    }

    fn confirm_delete_files(&self, id: i32, i: i32, name: String) {}

    fn override_file_confirm(
        &self,
        id: i32,
        file_num: i32,
        to: String,
        is_upload: bool,
        is_identical: bool,
    ) {
    }

    fn update_block_input_state(&self, on: bool) {}

    fn job_progress(&self, id: i32, file_num: i32, speed: f64, finished_size: f64) {}

    fn adapt_size(&self) {}

    fn on_rgba(&self, display: usize, rgba: &mut scrap::ImageRgb) {}

    fn msgbox(&self, msgtype: &str, title: &str, text: &str, link: &str, retry: bool) {
        if super::shell::handle_unavailable_auth_prompt(msgtype) { return; }
        let message = format!("{title}: {text}");
        if msgtype.contains("error") {
            if title == "Login Error" { super::shell::fatal_auth(); }
            super::shell::record_ui_error(&message);
            super::control::disconnected();
            super::error_status(&message);
        } else {
            super::status(&message);
        }
    }

    #[cfg(any(target_os = "android", target_os = "ios"))]
    fn clipboard(&self, content: String) {}

    fn cancel_msgbox(&self, tag: &str) {}

    fn switch_back(&self, id: &str) {}

    fn portable_service_running(&self, running: bool) {}

    fn on_voice_call_started(&self) {
        hbb_common::log::info!("Air microphone capture started for active Pro input");
    }

    fn on_voice_call_closed(&self, reason: &str) {
        if super::audio::capture_allowed() {
            super::status("RustDesk Air — Air microphone unavailable on Pro; check BlackHole 2ch and microphone permission");
        }
    }

    fn on_voice_call_waiting(&self) {}

    fn on_voice_call_incoming(&self) {}

    fn get_rgba(&self, display: usize) -> *const u8 {
        std::ptr::null()
    }

    fn next_rgba(&self, display: usize) {}

    #[cfg(all(feature = "vram", feature = "flutter"))]
    fn on_texture(&self, display: usize, texture: *mut std::ffi::c_void) {}

    fn set_multiple_windows_session(&self, sessions: Vec<WindowsSession>) {}

    fn set_current_display(&self, disp_idx: i32) {}

    #[cfg(feature = "flutter")]
    fn is_multi_ui_session(&self) -> bool {
        false
    }

    fn update_record_status(&self, start: bool) {}

    fn printer_request(&self, id: i32, path: String) {}

    fn handle_screenshot_resp(&self, sid: String, msg: String) {}

    fn handle_terminal_response(&self, response: TerminalResponse) {}
}
