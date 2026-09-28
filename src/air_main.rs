fn main() {
    #[cfg(target_os = "macos")]
    if let Err(error) = librustdesk::air::run() {
        librustdesk::air::report_error(&format!("RustDesk Air: {error}"));
        std::process::exit(1);
    }
    #[cfg(not(target_os = "macos"))]
    compile_error!("RustDesk Air requires macOS");
}
