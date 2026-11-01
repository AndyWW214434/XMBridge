#if DEBUG
import AppKit
import MDRKit
import SwiftUI

/// Debug builds only: `XMBridge --demo xm5|xm6|disconnected` opens the popover content in a window, filled with sample
/// device replies, for working on the UI without headphones.
@MainActor
enum DemoMode {
    static func startIfRequested(_ controller: HeadphoneController) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo") else { return }
        let model = index + 1 < arguments.count ? arguments[index + 1] : "xm6"

        // `--demo disconnected` shows the device picker as it is.
        if model != "disconnected" {
            var state = HeadphoneState()
            (model == "xm5" ? xm5Replies : xm6Replies).forEach { state.apply($0) }
            controller.showDemo(state)
        }

        DispatchQueue.main.async {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "XMBridge Demo (\(model.uppercased()))"
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(controller))
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            demoWindow = window

            // `--snapshot <file.png>` saves the window content and quits.
            if let snapshot = arguments.firstIndex(of: "--snapshot"), snapshot + 1 < arguments.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    saveSnapshot(of: window, to: arguments[snapshot + 1])
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Captures the window from the window server (an app may capture its own windows without permission).
    /// CGWindowListCreateImage is looked up at runtime because newer SDKs no longer expose it to Swift.
    private static func saveSnapshot(of window: NSWindow, to path: String) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let options = CGWindowListOption.optionIncludingWindow.rawValue
        let imageOptions = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        guard let image = createImage(.null, options, UInt32(window.windowNumber), imageOptions)?.takeRetainedValue() else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static var demoWindow: NSWindow?

    private static func text(_ op: UInt8, _ type: UInt8, _ value: String) -> [UInt8] {
        [op, type, UInt8(value.utf8.count)] + Array(value.utf8)
    }

    private static func support(_ ids: [UInt8]) -> [UInt8] {
        [0x07, 0x00, UInt8(ids.count)] + ids.flatMap { [$0, 0x01] }
    }

    private static func presetCapability(_ presets: [(UInt8, String)]) -> [UInt8] {
        let entries = presets.flatMap { id, name in [id, UInt8(name.utf8.count)] + Array(name.utf8) }
        return [0x51, 0x00, 0x0a, 0x0d, UInt8(presets.count)] + entries
    }

    static let xm5Replies: [[UInt8]] = [
        text(0x05, 0x01, "WH-1000XM5"),
        text(0x05, 0x02, "2.2.0"),
        support([0x12, 0x20, 0x23, 0x25, 0x50, 0x6b, 0xe2, 0xf1, 0xfc]),
        [0x13, 0x02, 0x02],
        [0x23, 0x00, 0x41, 0x01],
        [0x67, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14],
        [0x57, 0x00, 0xa0, 0x06, 0x0d, 0x0c, 0x0a, 0x09, 0x0b, 0x0e],
        [0xe7, 0x01, 0x00],
        [0xf7, 0x0c, 0x01, 0x01],
        [0xf7, 0x01, 0x00],
        [0x27, 0x05, 0x10, 0x00],
    ]

    static let xm6Replies: [[UInt8]] = [
        text(0x05, 0x01, "WH-1000XM6"),
        text(0x05, 0x02, "2.1.0"),
        support([0x12, 0x20, 0x23, 0x25, 0x50, 0x6d, 0xe2, 0xf1, 0xfc]),
        [0x13, 0x02, 0x10],
        [0x23, 0x00, 0x4e, 0x00],
        [0x67, 0x19, 0x01, 0x01, 0x01, 0x00, 0x0c, 0x00, 0x00],
        // The XM6 sends its preset list without names.
        presetCapability([(0x00, ""), (0x30, ""), (0x31, ""), (0x32, ""), (0x33, ""), (0x20, ""), (0xa0, ""), (0xa1, ""), (0xa2, "")]),
        [0x57, 0x00, 0xa0, 0x0a, 0x08, 0x08, 0x07, 0x06, 0x05, 0x05, 0x06, 0x07, 0x08, 0x07],
        [0xe7, 0x01, 0x01],
        [0xf7, 0x0c, 0x00, 0x01],
        [0xfb, 0x0c, 0x00, 0x01],
        [0xf7, 0x01, 0x00],
        [0x27, 0x05, 0x10, 0x00],
    ]
}
#endif
