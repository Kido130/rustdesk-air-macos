# RustDesk Air

An independent macOS fork of [RustDesk](https://github.com/rustdesk/rustdesk) for using a MacBook Air as a low-power remote screen and input device for a MacBook Pro. This project is not affiliated with the RustDesk team.

## What it does

- Renders the remote desktop on the Air through Metal. H.264 and H.265 video use VideoToolbox hardware decoding.
- Offers Exact Lossless changed-region streaming and an adaptive Smooth + Sharp mode for motion.
- Captures the Pro's built-in display, with a top-edge Space chooser and **Reload Spaces** menu item.
- Sends keyboard, trackpad, pointer, clipboard and session audio over an encrypted connection. Tries direct LAN routes before configured Tailscale routes.
- Provides a full-screen Air client with Control–Option–Command–Escape as the emergency exit.

## Download and install

The current [0.2.102 preview release](https://github.com/Kido130/rustdesk-air-macos/releases/tag/v0.2.102-preview) supports macOS 12.3 or later. Download **both** app archives from its **Assets** section. GitHub's automatic “Source code” archives are for developers; they are not installable apps.

| Computer | Download | App inside |
| --- | --- | --- |
| Apple Silicon MacBook Pro | [RustDesk-Air-Host-Apple-Silicon-0.2.102.zip](https://github.com/Kido130/rustdesk-air-macos/releases/download/v0.2.102-preview/RustDesk-Air-Host-Apple-Silicon-0.2.102.zip) | `RustDesk Air Host.app` |
| Intel MacBook Air | [RustDesk-Air-Client-Intel-0.2.102.zip](https://github.com/Kido130/rustdesk-air-macos/releases/download/v0.2.102-preview/RustDesk-Air-Client-Intel-0.2.102.zip) | `RustDesk Air Client.app` |

On each Mac, double-click its downloaded ZIP, then move the app inside to **Applications**. Open the Host on the Pro and the Client on the Air. These builds are signed but **not Apple-notarized**. If macOS blocks an app, first try to open it, then go to **System Settings → Privacy & Security → Open Anyway** for that app. [Apple explains this exception](https://support.apple.com/en-us/102445); only use it for a download you trust. The release also provides [SHA256SUMS](https://github.com/Kido130/rustdesk-air-macos/releases/download/v0.2.102-preview/SHA256SUMS) if you want to compare your downloaded archive's SHA-256 using `shasum -a 256`.

### Connect the two Macs

1. On the Pro, open **RustDesk Air Host**. Click **Allow screen recording…** if capture is blocked. Approve the macOS prompt, then reopen the Host if it still cannot capture. Also allow the Host **Accessibility** and **Local Network** access in System Settings → Privacy & Security when requested.
2. In the Host window, click **Export Air pairing file…** and save `RustDesk Air Pairing.json`. Transfer it privately to the Air, such as by AirDrop. **Anyone with this file can use its connection secret; do not publish it.**
3. On the Air, open **RustDesk Air Client** and select that pairing file when prompted. Drag the Client app from Applications to the Dock for quick access. Allow **Accessibility**, **Input Monitoring**, and **Local Network** access if macOS asks; reopen the Client after changing those permissions.
4. In the quality dialog, choose **Smooth + Sharp** for adaptive motion or **Exact Lossless** for lossless updates. **Remote Mode** captures Air keyboard and trackpad input. The three Remote Spaces and individual finger options are marked experimental and start off.
5. The Client connects using direct LAN routes first, then configured Tailscale routes. During a session, move the pointer to the top edge for the Spaces menu and **Reload Spaces**. Press **Control–Option–Command–Escape** to leave Remote Mode.

If the Air shows no picture, check the Host's Screen Recording permission and reopen it. If the Air cannot connect, check that both Macs are awake and on the same LAN, or configure Tailscale on both before retrying. The pairing file is not included in the repository or release archives. To update, quit both apps and replace their app bundles with the corresponding new release archives; keep the pairing file private.

## Status

Development preview for macOS 12.3 or later. The video and input baseline has been tested on an Apple Silicon Pro and an Intel Air. The 0.2.101 Reload Spaces code passed native menu and state tests; live recovery on the Air is still being verified. Version 0.2.102 adds Fn and extended-key packet coverage on both architectures. Test on your own machines before relying on window migration or restoration for important work.

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
