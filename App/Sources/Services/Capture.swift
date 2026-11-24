#if DEBUG
import AppKit
import SwiftUI

/// Debug aid: renders the popover / a window to PNG in-process (no screen-recording permission needed).
/// `-capture popover|main|settings|onboarding <path.png>` (repeatable via `-captureAfter <seconds>`).
@MainActor
enum Capture {
    static func run(args: [String]) {
        if args.contains("-diag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let c = WidgetBridge.container
                let snap = WidgetBridge.read()
                var lines = ["groupID=\(WidgetBridge.groupID)", "container=\(c?.path ?? "nil")",
                             "snapshot=\(snap != nil)", "worked=\(snap?.worked ?? -1)", "running=\(snap?.running?.description ?? "-")"]
                lines.append("db=\(Paths.database.path) exists=\(FileManager.default.fileExists(atPath: Paths.database.path))")
                let dir = URL(fileURLWithPath: "/private/tmp/tikjot-captures")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("diag.txt"), atomically: true, encoding: .utf8)
                if args.contains("-captureQuit") { NSApp.terminate(nil) }
            }
        }
        guard let i = args.firstIndex(of: "-capture"), args.indices.contains(i + 2) else { return }
        let target = args[i + 1], path = args[i + 2]
        let delay = args.firstIndex(of: "-captureAfter").flatMap { Double(args[$0 + 1]) } ?? 3
        // -captureSeries <count> <ms>: several frames name-1.png … (to check motion).
        if let si = args.firstIndex(of: "-captureSeries"), args.indices.contains(si + 2), let count = Int(args[si + 1]), let ms = Double(args[si + 2]) {
            for k in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(k) * ms / 1000) {
                    let v = target == "sheet" ? NSApp.windows.compactMap(\.attachedSheet).first?.contentView
                        : target == "popover" ? MenuBarController.shared?.popover.contentViewController?.view
                        : NSApp.windows.first { $0.isVisible && $0.frame.width > 500 && !$0.className.contains("StatusBar") }?.contentView
                    if let v { write(v, to: (path as NSString).deletingPathExtension + "-\(k + 1).png") }
                    if k == count - 1 && args.contains("-captureQuit") { NSApp.terminate(nil) }
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let view: NSView?
            switch target {
            case "popover": view = MenuBarController.shared?.popover.contentViewController?.view
            case "window": view = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue != "main" && $0.frame.width > 500 && !$0.className.contains("StatusBar") && !$0.className.contains("Popover") }?.contentView
            case "sheet": view = NSApp.windows.compactMap(\.attachedSheet).first?.contentView
            // A popover opened inside the main window (filters, pickers) — not the menu-bar one.
            case "popwin": view = NSApp.windows.first { $0.isVisible && $0.className.contains("Popover") && $0 !== MenuBarController.shared?.popover.contentViewController?.view.window }?.contentView
            default: view = NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0.className.contains("StatusBar")) && $0.frame.width > 500 }?.contentView
            }
            if let v = view { write(v, to: path) }
            if args.contains("-captureQuit") { NSApp.terminate(nil) }
        }
    }

    static func write(_ v: NSView, to path: String) {
        // A field focused from a launch flag selects its text; a capture shows the caret at the end instead.
        if let ed = v.window?.firstResponder as? NSTextView, ed.isFieldEditor { ed.setSelectedRange(NSRange(location: ed.string.utf16.count, length: 0)) }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            // Debug builds may write here (sandbox exception in tikjot-debug.entitlements).
            let dir = URL(fileURLWithPath: "/private/tmp/tikjot-captures")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent((path as NSString).lastPathComponent))
        }
    }
}
#endif
