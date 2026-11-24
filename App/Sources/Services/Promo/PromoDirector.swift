#if DEBUG
import AppKit
import TikjotDomain

/// Promo video (dev builds only): `-promo <scene>` plays one scene of the demo app with real clicks and keys
/// (in-process events, so the app's own hover, press and motion show) while PromoRecorder records its windows.
/// Writes /private/tmp/tikjot-captures/promo-<scene>.mov and promo-<scene>.json (cursor path, clicks, keys;
/// seconds from the first frame, points from the recorded area's top-left) for the edit.
@MainActor
final class PromoDirector {
    private let model: AppModel
    private let scene: String
    private let recorder = PromoRecorder()
    private var area = NSRect.zero
    private var events: [[String: Any]] = []
    private var cursor = NSPoint.zero
    private var eventNumber = 0
    private static let dir = URL(fileURLWithPath: "/private/tmp/tikjot-captures")

    static func run(args: [String], model: AppModel) {
        guard model.demo, let i = args.firstIndex(of: "-promo"), args.indices.contains(i + 1) else { return }
        let d = PromoDirector(model: model, scene: args[i + 1])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))   // demo data in place
            do { try await d.play() } catch { Log.info("promo \(d.scene) failed: \(error)") }
            NSApp.terminate(nil)
        }
    }

    private init(model: AppModel, scene: String) { self.model = model; self.scene = scene }

    // MARK: Scenes

    private func play() async throws {
        switch scene {
        case "morning": try await morning()
        case "switch": try await switchTask()
        case "away": try await away()
        case "notask": try await noTask()
        case "evening": try await evening()
        case "send": try await send()
        case "stats": try await stats()
        case "week": try await week()
        case "month": try await month()
        default: Log.info("promo: unknown scene \(scene)")
        }
    }

    /// ⌥⌘T → type → an earlier entry comes up with its task → ↩ → the time starts.
    private func morning() async throws {
        let pop = try await popoverFrame()
        try await record(pop.insetBy(dx: -60, dy: -60))
        await wait(1.2)
        log(["type": "key", "keys": "⌥⌘T"])
        AppDelegate.shared?.menuBar?.showPopover()
        model.focusTimerDescription()
        await wait(1.0)
        await type("Retry", cps: 7)
        await wait(0.9)
        key(125, "↓")
        await wait(0.6)
        key(36, "↩")
        await wait(4.0)
        try await finish()
    }

    /// Running since 10:05; ▶ on an earlier entry switches to it.
    private func switchTask() async throws {
        let pop = try await openPopover()
        try await record(pop.insetBy(dx: -60, dy: -60))
        cursor = inPopover(330, 700)
        await wait(0.8)
        await move(to: inPopover(200, 322), over: 0.9)
        await wait(0.5)
        await click(at: inPopover(383, 327))
        await wait(3.2)
        try await finish()
    }

    /// Back from lunch with the timer still running: "You were away" → Stop at 12:05.
    private func away() async throws {
        let pop = try await openPopover()
        try await record(pop.insetBy(dx: -60, dy: -60))
        cursor = inPopover(300, 420)
        await wait(1.4)
        await click(at: inPopover(342, 168))
        await wait(2.6)
        try await finish()
    }

    /// An entry without a task: one click, the task list suggests the right one, ↩.
    private func noTask() async throws {
        let pop = try await openPopover()
        try await record(pop.insetBy(dx: -60, dy: -60))
        cursor = inPopover(300, 560)
        await wait(0.8)
        await click(at: inPopover(150, 325))
        await wait(1.1)
        await type("budget", cps: 8)
        await wait(0.8)
        key(36, "↩")
        await wait(2.4)
        try await finish()
    }

    /// The Day window, calm: the pointer drifts down the day's blocks (their hover shows), nothing is changed.
    private func evening() async throws {
        let w = await openMain(.day, day: LocalDate("2026-10-06")!)
        try await record(w.frame.insetBy(dx: -70, dy: -70))
        cursor = inWindow(w, 900, 760)
        await wait(0.8)
        await move(to: inWindow(w, 640, 150), over: 1.6)
        await wait(0.6)
        await move(to: inWindow(w, 600, 340), over: 1.4)
        await wait(0.6)
        await move(to: inWindow(w, 620, 600), over: 1.6)
        await wait(0.6)
        await move(to: inWindow(w, 980, 300), over: 1.4)
        await wait(0.8)
        try await finish()
    }

    /// Review & send → the sheet → Send → sending, the plane.
    private func send() async throws {
        let w = await openMain(.day, day: LocalDate("2026-10-06")!)
        try await record(w.frame.insetBy(dx: -70, dy: -70))
        cursor = inWindow(w, 900, 500)
        await wait(0.8)
        await click(at: inWindow(w, 1150, 31))
        await wait(1.6)
        guard let sheet = w.attachedSheet else { throw CocoaError(.featureUnsupported) }
        await click(at: inWindow(sheet, 455, 459))
        await wait(5.5)
        try await finish()
    }

    /// The week as a grid: type a duration straight into an empty cell; the totals follow.
    private func week() async throws {
        let w = await openMain(.week, day: LocalDate("2026-10-06")!)
        try await record(w.frame.insetBy(dx: -70, dy: -70))
        cursor = inWindow(w, 980, 640)
        await wait(0.8)
        await click(at: inWindow(w, 762, 253))
        await wait(0.6)
        await type("1h30", cps: 6)
        await wait(1.0)
        key(36, "↩")
        await wait(2.4)
        try await finish()
    }

    /// The month: a slow pass along the running balance (its tooltips come up), then down the days.
    private func month() async throws {
        let w = await openMain(.month, day: LocalDate("2026-09-30")!)
        try await record(w.frame.insetBy(dx: -70, dy: -70))
        cursor = inWindow(w, 700, 700)
        await wait(0.6)
        // Along the chart's baseline (columns 124–218 pt), so the pointer passes over the columns.
        await move(to: inWindow(w, 420, 170), over: 0.9)
        await wait(0.5)
        await move(to: inWindow(w, 900, 170), over: 1.6)
        await wait(0.8)
        try await finish()
    }

    /// Statistics: a slow pass over the charts (their tooltips come up).
    private func stats() async throws {
        let w = await openMain(.statistics, day: model.today)
        try await record(w.frame.insetBy(dx: -70, dy: -70))
        cursor = inWindow(w, 600, 760)
        await wait(0.8)
        await move(to: inWindow(w, 781, 330), over: 1.0)
        await wait(0.9)
        await move(to: inWindow(w, 853, 340), over: 0.5)
        await wait(0.9)
        await move(to: inWindow(w, 1080, 400), over: 0.7)
        await wait(0.9)
        await move(to: inWindow(w, 420, 704), over: 0.9)
        await wait(1.4)
        try await finish()
    }

    // MARK: Recording

    /// Shows the popover once to learn where it sits, then closes it (the scene opens it on camera).
    private func popoverFrame() async throws -> NSRect {
        AppDelegate.shared?.menuBar?.showPopover()
        await wait(0.6)
        guard let w = AppDelegate.shared?.menuBar?.popover.contentViewController?.view.window else { throw CocoaError(.featureUnsupported) }
        let f = w.frame
        AppDelegate.shared?.menuBar?.closePopover()
        await wait(0.4)
        return f
    }

    /// The menu-bar strip above `r` (the status item with its time sits there).
    private func menuBarStrip(over r: NSRect) -> NSRect {
        guard let s = NSScreen.screens.first(where: { $0.frame.intersects(r) }) ?? NSScreen.main else { return r }
        return NSRect(x: r.minX, y: s.visibleFrame.maxY, width: r.width, height: s.frame.maxY - s.visibleFrame.maxY)
    }

    private func record(_ r: NSRect) async throws {
        area = r.integral
        try await recorder.start(rect: area, url: Self.dir.appendingPathComponent("promo-\(scene).mov"))
        for _ in 0..<60 where recorder.firstFrame == nil { await wait(0.05) }
        await wait(0.4)
    }

    private func finish() async throws {
        await recorder.stop()
        let t0 = recorder.firstFrame ?? 0
        let out = events.map { e -> [String: Any] in var x = e; x["t"] = ((e["host"] as? Double) ?? 0) - t0; x["host"] = nil; return x }
        var doc: [String: Any] = ["scene": scene, "width": area.width, "height": area.height, "events": out]
        // Where the app's content sits in the recording (points, top-left origin): the popover's, else the main window's.
        let content: NSView? = AppDelegate.shared?.menuBar?.popover.isShown == true
            ? AppDelegate.shared?.menuBar?.popover.contentViewController?.view
            : NSApp.windows.first { $0.identifier?.rawValue == "main" }?.contentView
        if let v = content, let w = v.window {
            let r = w.convertToScreen(v.convert(v.bounds, to: nil))
            doc["content"] = ["x": Double(r.minX - area.minX), "y": Double(area.maxY - r.maxY), "w": Double(r.width), "h": Double(r.height)]
        }
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.dir.appendingPathComponent("promo-\(scene).json"))
    }

    private func log(_ e: [String: Any]) {
        var x = e
        x["host"] = PromoRecorder.hostNow
        events.append(x)
    }

    /// Area-local point (top-left origin) for the edit.
    private func local(_ p: NSPoint) -> [String: Double] { ["x": Double(p.x - area.minX), "y": Double(area.maxY - p.y)] }

    // MARK: Input

    private func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    private func type(_ text: String, cps: Double = 9) async {
        for ch in text {
            key(0, String(ch), chars: String(ch))
            await wait(1 / cps * Double.random(in: 0.7...1.3))
        }
    }

    private func key(_ code: UInt16, _ label: String, chars: String? = nil, mods: NSEvent.ModifierFlags = []) {
        // A small popover (the week cell's preview) takes the keys while it's up.
        let pop = NSApp.windows.first { $0.isVisible && $0.className.contains("Popover") && $0.frame.width < 520 && $0 !== AppDelegate.shared?.menuBar?.popover.contentViewController?.view.window }
        guard let w = pop ?? NSApp.keyWindow else { return }
        if !w.isKeyWindow { w.makeKey() }
        let c = chars ?? Self.keyChars[code] ?? ""
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c,
                                        isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        if chars == nil { log(["type": "key", "keys": label]) }
    }

    private static let keyChars: [UInt16: String] = [
        125: String(UnicodeScalar(NSDownArrowFunctionKey)!), 126: String(UnicodeScalar(NSUpArrowFunctionKey)!),
        36: "\r", 48: "\t", 53: "\u{1b}",
    ]

    /// Moves the (drawn-in-the-edit) cursor along an eased path; the app gets real mouse-moved events, so hover shows.
    private func move(to p: NSPoint, over s: Double = 0.6) async {
        let from = cursor
        let steps = max(1, Int(s * 60))
        for k in 1...steps {
            let x = Double(k) / Double(steps)
            let e = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
            let q = NSPoint(x: from.x + (p.x - from.x) * e, y: from.y + (p.y - from.y) * e)
            cursor = q
            // The real pointer too: the window server's enter/exit events are what popover rows hover on.
            if let top = NSScreen.screens.first?.frame.maxY { CGWarpMouseCursorPosition(CGPoint(x: q.x, y: top - q.y)) }
            mouse(.mouseMoved, at: q)
            log(["type": "move", "p": local(q)])
            await wait(1 / 60)
        }
    }

    private func click(at p: NSPoint) async {
        await move(to: p)
        await wait(0.12)
        log(["type": "down", "p": local(p)])
        mouse(.leftMouseDown, at: p)
        await wait(0.09)
        mouse(.leftMouseUp, at: p)
        log(["type": "up", "p": local(p)])
    }

    private func drag(from a: NSPoint, to b: NSPoint, over s: Double = 0.9) async {
        await move(to: a)
        await wait(0.12)
        mouse(.leftMouseDown, at: a)
        log(["type": "down", "p": local(a)])
        let steps = max(1, Int(s * 60))
        for k in 1...steps {
            let x = Double(k) / Double(steps)
            let e = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
            let q = NSPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            cursor = q
            mouse(.leftMouseDragged, at: q)
            log(["type": "move", "p": local(q)])
            await wait(1 / 60)
        }
        mouse(.leftMouseUp, at: b)
        log(["type": "up", "p": local(b)])
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint) {
        guard let w = window(at: p) else { return }
        eventNumber += 1
        guard let e = NSEvent.mouseEvent(with: type, location: w.convertPoint(fromScreen: p), modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                         eventNumber: eventNumber, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        // One queue for everything, so a drag never overtakes its mouse-down; popovers don't track moves by default.
        w.acceptsMouseMovedEvents = true
        NSApp.postEvent(e, atStart: false)
    }

    /// The front-most of this app's visible windows under `p` (global coordinates).
    private func window(at p: NSPoint) -> NSWindow? {
        // Popovers float above everything but aren't always in orderedWindows.
        NSApp.windows.first { $0.isVisible && $0.className.contains("Popover") && $0.frame.contains(p) }
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.frame.contains(p) }
            ?? NSApp.windows.first { $0.isVisible && $0.frame.contains(p) }
    }

    /// Opens the popover and waits for it to settle.
    private func openPopover() async throws -> NSRect {
        AppDelegate.shared?.menuBar?.showPopover()
        await wait(0.8)
        guard let w = AppDelegate.shared?.menuBar?.popover.contentViewController?.view.window else { throw CocoaError(.featureUnsupported) }
        return w.frame
    }

    /// The main window, centred, 1240 × 820, on `section` / `day`.
    private func openMain(_ section: MainSection, day: LocalDate) async -> NSWindow {
        model.selectedDay = day
        model.mainSelection = section
        AppDelegate.shared?.windows.showMain(model)
        await wait(0.6)
        let w = NSApp.windows.first { $0.identifier?.rawValue == "main" }!
        if let s = w.screen ?? NSScreen.main {
            let size = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1240, height: 820)).size
            w.setFrame(NSRect(x: s.visibleFrame.midX - size.width / 2, y: s.visibleFrame.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        await wait(1.2)
        return w
    }

    /// A point in a window's content (points from its top-left, as in the captures) → global.
    private func inWindow(_ w: NSWindow, _ x: CGFloat, _ y: CGFloat) -> NSPoint {
        guard let v = w.contentView else { return .zero }
        return w.convertPoint(toScreen: v.convert(NSPoint(x: x, y: v.isFlipped ? y : v.bounds.height - y), to: nil))
    }

    /// A point in the popover's content (points from its top-left, as in the captures) → global.
    private func inPopover(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        guard let v = AppDelegate.shared?.menuBar?.popover.contentViewController?.view, let w = v.window else { return .zero }
        let local = NSPoint(x: x, y: v.isFlipped ? y : v.bounds.height - y)
        return w.convertPoint(toScreen: v.convert(local, to: nil))
    }
}
#endif
