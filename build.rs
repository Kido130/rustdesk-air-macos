#[cfg(windows)]
fn build_windows() {
    let file = "src/platform/windows.cc";
    let file2 = "src/platform/windows_delete_test_cert.cc";
    cc::Build::new().file(file).file(file2).compile("windows");
    println!("cargo:rustc-link-lib=WtsApi32");
    println!("cargo:rerun-if-changed={}", file);
    println!("cargo:rerun-if-changed={}", file2);
}

#[cfg(target_os = "macos")]
fn build_mac() {
    let file = "src/platform/macos.mm";
    let mut b = cc::Build::new();
    if let Ok(os_version::OsVersion::MacOS(v)) = os_version::detect() {
        let v = v.version;
        if v.contains("10.14") {
            b.flag("-DNO_InputMonitoringAuthStatus=1");
        }
    }
    b.flag("-std=c++17").file(file).compile("macos");
    println!("cargo:rerun-if-changed={}", file);
}

#[cfg(all(windows, feature = "inline"))]
fn build_manifest() {
    use std::io::Write;
    if std::env::var("PROFILE").unwrap() == "release" {
        let mut res = winres::WindowsResource::new();
        res.set_icon("res/icon.ico")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("res/manifest.xml");
        match res.compile() {
            Err(e) => {
                write!(std::io::stderr(), "{}", e).unwrap();
                std::process::exit(1);
            }
            Ok(_) => {}
        }
    }
}

// bionic only exports getifaddrs()/freeifaddrs() from API 24, while the jniLibs
// are built against the API 21 sysroot (flutter/ndk_*.sh). webrtc-util calls
// them, so without this the android link fails on undefined symbols.
fn build_android_ifaddrs() {
    let file = "src/platform/android_ifaddrs.c";
    cc::Build::new().file(file).compile("android_ifaddrs");
    println!("cargo:rerun-if-changed={}", file);
}

fn install_android_deps() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    if target_os != "android" {
        return;
    }
    let mut target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    if target_arch == "x86_64" {
        target_arch = "x64".to_owned();
    } else if target_arch == "x86" {
        target_arch = "x86".to_owned();
    } else if target_arch == "aarch64" {
        target_arch = "arm64".to_owned();
    } else {
        target_arch = "arm".to_owned();
    }
    let target = format!("{}-android", target_arch);
    let vcpkg_root = std::env::var("VCPKG_ROOT").unwrap();
    let mut path: std::path::PathBuf = vcpkg_root.into();
    if let Ok(vcpkg_root) = std::env::var("VCPKG_INSTALLED_ROOT") {
        path = vcpkg_root.into();
    } else {
        path.push("installed");
    }
    path.push(target);
    println!(
        "cargo:rustc-link-search={}",
        path.join("lib").to_str().unwrap()
    );
    println!("cargo:rustc-link-lib=ndk_compat");
    println!("cargo:rustc-link-lib=c++");
    println!("cargo:rustc-link-lib=OpenSLES");
}

fn main() {
    hbb_common::gen_version();
    install_android_deps();
    #[cfg(all(windows, feature = "inline"))]
    build_manifest();
    #[cfg(windows)]
    build_windows();
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    if target_os == "macos" {
        #[cfg(feature = "air-native")]
        {
            cc::Build::new().cpp(true).flag("-std=c++17").flag("-fobjc-arc")
                .flag("-fmodules").flag("-mmacosx-version-min=12.3")
                .file("src/air/mic_demand.mm").file("src/air/renderer.mm").file("src/air/capture.mm").file("src/air/display.mm").file("src/air/cursor.mm").file("src/air/input.mm").file("src/air/dockswipe27.mm").file("src/air/tests/capture_v2.mm").file("src/air/tests/keyboard_probe.mm").file("src/air/tests/cursor_path_probe.mm").file("src/air/shell.mm").file("src/air/spaces.mm").file("src/air/whole_space_swap.mm").file("src/air/overlay.mm")
                .compile("rustdesk_air_native");
            cc::Build::new().file("src/air/TouchEvents.c").compile("air_touch_events");
            for file in ["src/air/spaces.mm", "src/air/spaces.h", "src/air/whole_space_swap.mm", "src/air/whole_space_swap.h", "src/air/overlay.mm", "src/air/overlay.h", "src/air/dockswipe27.mm", "src/air/dockswipe27.h"] {
                println!("cargo:rerun-if-changed={file}");
            }
            for framework in ["AppKit", "MetalKit", "Metal", "CoreVideo", "CoreMedia", "VideoToolbox", "ScreenCaptureKit", "IOSurface", "IOKit", "Security"] {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
            for file in ["src/air/mic_demand.mm", "src/air/native.h", "src/air/renderer.mm", "src/air/capture.mm", "src/air/display.mm", "src/air/cursor.mm", "src/air/input.mm", "src/air/tests/capture_v2.mm", "src/air/tests/capture_v2.h", "src/air/tests/keyboard_probe.mm", "src/air/tests/cursor_path_probe.mm", "src/air/TouchEvents.c", "src/air/TouchEvents.h", "src/air/IOHIDEventData.h", "src/air/IOHIDEventTypes.h", "src/air/shell.mm", "src/air/shell.h"] {
                println!("cargo:rerun-if-changed={file}");
            }
        }
        #[cfg(target_os = "macos")]
        build_mac();
        println!("cargo:rustc-link-lib=framework=ApplicationServices");
    }
    if target_os == "android" {
        build_android_ifaddrs();
    }
    println!("cargo:rerun-if-changed=build.rs");
}
