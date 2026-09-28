// A bounded, ordinary window captured by the real Pro host during LAN tests.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3, ["idle", "small", "scroll", "motion"].contains(args[1]),
      let duration = Double(args[2]), duration >= 10, duration <= 120 else {
    fputs("Usage: air-workload idle|small|scroll|motion 10..120\n", stderr)
    exit(2)
}
let mode = args[1]
let began = ProcessInfo.processInfo.systemUptime

final class Workload: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        let offset = mode == "scroll" ? (elapsed * 90).truncatingRemainder(dividingBy: 26) : 0
        for row in 0..<23 {
            let line = String(format: "%02d  Exact pixels • Retina text • unchanged regions stay on GPU", row)
            line.draw(at: NSPoint(x: 18, y: CGFloat(row * 26) - offset), withAttributes: attributes)
        }
        if mode == "small" {
            NSColor.systemRed.setFill()
            NSRect(x: 20 + (elapsed * 150).truncatingRemainder(dividingBy: 650),
                   y: 220, width: 40, height: 40).fill()
        }
        if mode == "motion" {
            for row in 0..<10 {
                for column in 0..<16 {
                    NSColor(calibratedHue: (Double(row * 16 + column) / 160 + elapsed / 4)
                        .truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.85, alpha: 1).setFill()
                    NSRect(x: column * 50, y: row * 50, width: 50, height: 50).fill()
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
guard let screen = NSScreen.screens.first(where: {
    guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
    return CGDisplayIsBuiltin(number.uint32Value) != 0
}) else { fputs("Built-in screen unavailable\n", stderr); exit(1) }
let rect = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 50, width: 800, height: 500)
let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "RustDesk Air — \(mode) test — closes automatically"
window.isReleasedWhenClosed = false
let view = Workload(frame: NSRect(origin: .zero, size: rect.size))
window.contentView = view
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
    if ProcessInfo.processInfo.systemUptime - began >= duration || !window.isVisible {
        app.terminate(nil)
    }
    if mode != "idle" { view.needsDisplay = true }
}
app.run()
