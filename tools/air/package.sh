#!/bin/bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: bash tools/air/package.sh /path/to/rustdesk-air /path/to/output-folder" >&2
  exit 2
fi
binary="$1"
destination="$2"
package_version="${AIR_PACKAGE_VERSION:-0.2.67}"
package_build="${AIR_PACKAGE_BUILD:-69}"
[[ "$package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$package_build" =~ ^[0-9]+$ ]] || {
  echo "Invalid Air package version or build" >&2; exit 1;
}
repo="$(cd "$(dirname "$0")/../.." && pwd)"
[[ -f "$binary" ]] || { echo "Binary not found: $binary" >&2; exit 1; }
signed_preview=false
if [[ -n "${AIR_SIGNING_KEYCHAIN:-}${AIR_SIGNING_LEAF_SHA1:-}${AIR_SIGNING_LEAF_SHA256:-}${AIR_SIGNING_PUBLIC_CERT:-}" ]]; then
  [[ -n "${AIR_SIGNING_KEYCHAIN:-}" && -n "${AIR_SIGNING_LEAF_SHA1:-}" && -n "${AIR_SIGNING_LEAF_SHA256:-}" && -n "${AIR_SIGNING_PUBLIC_CERT:-}" ]] || {
    echo "Incomplete private signing settings" >&2; exit 1;
  }
  [[ -f "$AIR_SIGNING_KEYCHAIN" && ! -L "$AIR_SIGNING_KEYCHAIN" && -f "$AIR_SIGNING_PUBLIC_CERT" && ! -L "$AIR_SIGNING_PUBLIC_CERT" ]] || {
    echo "Private signing keychain or public certificate is unavailable" >&2; exit 1;
  }
  [[ "$AIR_SIGNING_LEAF_SHA1" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo "Invalid certificate fingerprint" >&2; exit 1; }
  [[ "$AIR_SIGNING_LEAF_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || { echo "Invalid certificate SHA-256" >&2; exit 1; }
  configured_leaf="$(/bin/echo -n "$AIR_SIGNING_LEAF_SHA1" | /usr/bin/tr '[:lower:]' '[:upper:]')"
  public_leaf="$(/usr/bin/openssl x509 -in "$AIR_SIGNING_PUBLIC_CERT" -noout -fingerprint -sha1 | /usr/bin/cut -d= -f2 | /usr/bin/tr -d : | /usr/bin/tr '[:lower:]' '[:upper:]')"
  [[ "$public_leaf" == "$configured_leaf" ]] || { echo "Public certificate fingerprint differs from configured signing identity" >&2; exit 1; }
  public_leaf_sha256="$(/usr/bin/openssl x509 -in "$AIR_SIGNING_PUBLIC_CERT" -outform DER | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ "$public_leaf_sha256" == "$AIR_SIGNING_LEAF_SHA256" ]] || { echo "Public certificate SHA-256 differs from configured signing identity" >&2; exit 1; }
  signed_preview=true
fi
mkdir -p "$destination"
for role in Client Host; do
  bundle="$destination/RustDesk Air $role.app"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  cp "$binary" "$bundle/Contents/MacOS/rustdesk-air"
  cp "$repo/LICENCE" "$bundle/Contents/Resources/LICENCE"
  cp "$repo/src/air/TouchEvents-LICENSE.md" "$bundle/Contents/Resources/TouchEvents-LICENSE.md"
  cp "$repo/libs/cpal-air/LICENSE" "$bundle/Contents/Resources/CPAL-LICENSE"
  cp "$repo/flutter/macos/Runner/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Clear dict" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string rustdesk-air" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string dev.rustdesk.air.$role" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string RustDesk Air $role" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $package_build" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $package_version" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 12.3" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string Connect the paired MacBook Air and Pro over your local network." "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :NSScreenCaptureUsageDescription string Stream the built-in Retina display to your paired MacBook Air." "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string Use the Air microphone in apps on your paired Pro during a remote session." "$bundle/Contents/Info.plist"
  signing_options=(--identifier "dev.rustdesk.air.$role")
  if [[ "$role" == Host ]]; then
    /usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string Move and restore Finder windows while Remote Mode is active." "$bundle/Contents/Info.plist"
    signing_options+=(--entitlements "$repo/tools/air/host-entitlements.plist")
  fi
  if $signed_preview; then
    leaf="$(/bin/echo -n "$configured_leaf" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    requirement="identifier \"dev.rustdesk.air.$role\" and certificate leaf = H\"$leaf\""
    /usr/bin/codesign --force --sign "$configured_leaf" --keychain "$AIR_SIGNING_KEYCHAIN" "${signing_options[@]}" --requirements "=designated => $requirement" --timestamp=none "$bundle"
    /usr/bin/codesign --verify -R "=$requirement" "$bundle"
    actual_requirement="$(/usr/bin/codesign --display -r - "$bundle" 2>&1 | /usr/bin/awk '/^designated => /{print}')"
    [[ "$actual_requirement" == "designated => $requirement" ]] || { echo "Bundle designated requirement differs from pinned identity" >&2; exit 1; }
  else
    codesign --force --sign - "${signing_options[@]}" "$bundle"
  fi
  codesign --verify --deep --strict "$bundle"
done
