Vendored from rustdesk-org/cpal osx-screencapturekit commit 96d4da121b7d949677ac5b6887413a9185fd7f39

The optional air-exclude-own-audio feature excludes this process from ScreenCaptureKit audio so microphone output routed to a virtual input cannot echo into the remote speaker stream. Non-Air builds retain upstream behavior. Original Apache license retained.
