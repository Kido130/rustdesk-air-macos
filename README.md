# RustDesk Air

An independent macOS fork of [RustDesk](https://github.com/rustdesk/rustdesk) for using a MacBook Air as a low-power remote screen and input device for a MacBook Pro. This project is not affiliated with the RustDesk team.

## What it does

- Renders the remote desktop on the Air through Metal. H.264 and H.265 video use VideoToolbox hardware decoding.
- Offers Exact Lossless changed-region streaming and an adaptive Smooth + Sharp mode for motion.
- Captures the Pro's built-in display, with a top-edge Space chooser and **Reload Spaces** menu item.
- Sends keyboard, trackpad, pointer, clipboard and session audio over an encrypted connection. Tries direct LAN routes before configured Tailscale routes.
- Provides a full-screen Air client with Control–Option–Command–Escape as the emergency exit.

## Get the apps

Download the matching **Apple Silicon Host** and **Intel Air Client** archives from [Releases](https://github.com/Kido130/rustdesk-air-macos/releases). Unzip each archive and move the app to Applications. These preview builds are signed but not Apple-notarized. macOS may ask you to approve opening them and grant Screen Recording, Accessibility, Local Network, and microphone permissions where needed.

1. Open **RustDesk Air Host** on the Pro.
2. Export an Air pairing file from the Host and transfer it privately to the Air.
3. Open **RustDesk Air Client** on the Air, import the pairing file, and connect.
4. During a session, move the pointer to the top edge for the Spaces menu. Choose **Reload Spaces** there if the Space list fails to load.

**Keep the pairing file private.** It contains the Host identity and connection secret. No pairing file, credential, or personal network address is shipped in this repository or the release archives.

## Status

Development preview for macOS 12.3 or later. The video and input baseline has been tested on an Apple Silicon Pro and an Intel Air. The 0.2.101 Reload Spaces code passed native menu and state tests and both architecture release builds; live recovery on the Air is still being verified. Test on your own machines before relying on window migration or restoration for important work.

## Build from source

Clone with submodules and set `VCPKG_ROOT` to a vcpkg installation with the dependencies listed by the build script. On macOS with Xcode:

```sh
git clone --recurse-submodules https://github.com/Kido130/rustdesk-air-macos.git
cd rustdesk-air-macos
bash tools/air/build.sh aarch64-apple-darwin   # Apple Silicon Host
bash tools/air/build.sh x86_64-apple-darwin    # Intel Air Client
```

The app bundles are created under `dist/`. The build script uses ad hoc signing unless a local signing identity is configured. Never commit pairing files or signing material.

## License and attribution

This fork preserves the RustDesk copyright notices and [GNU AGPL version 3 license](LICENCE). It includes third-party components under their own licenses, including [TouchEvents](src/air/TouchEvents-LICENSE.md) and [CPAL](libs/cpal-air/LICENSE). Source for the release binaries is this repository and its pinned public submodule.
