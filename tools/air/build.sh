#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"
: "${VCPKG_ROOT:?Set VCPKG_ROOT to a vcpkg installation with libvpx, libyuv, aom, and opus}"
export MACOSX_DEPLOYMENT_TARGET=12.3
# ScreenCaptureKit audio uses cidre's native Xcode targets.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
target="${1:-aarch64-apple-darwin}"
case "$target" in aarch64-apple-darwin|x86_64-apple-darwin) ;; *) echo "Unsupported target" >&2; exit 2 ;; esac
features=air-native
if [[ "$target" == aarch64-apple-darwin ]]; then features+=,screencapturekit; fi
cargo build --locked --release --features "$features" --bin rustdesk-air --target "$target"
target_dir="${CARGO_TARGET_DIR:-$repo/target}"
bash tools/air/package.sh "$target_dir/$target/release/rustdesk-air" "$repo/dist/$target"
