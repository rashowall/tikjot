import AppKit
import Combine
import SwiftUI
import TikjotDomain
import TikjotPersistence

/// Status item + popover — the everyday surface (§11.1).
/// Idle = template glyph; running = tick glyph + coral dot + elapsed time (`● 1:23`).
///
/// Energy (storyboard E): idle there is no timer at all — the item only changes when the data does. While a timer
/// runs, a 1 s timer (with tolerance) refreshes the text, which is only re-set when the minute changes. The dot is a
/// `CALayer` on the button's layer whose breathing (opacity 1 → 0.55 → 1, 2.4 s, sine in-out) is a repeating Core
/// Animation run by the render server, not by our process. It pauses (steady 100 %) after 10 s without user input,
/// and is steady with Reduce Motion.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static weak var shared: MenuBarController?
    let model: AppModel
    private(set) var item: NSStatusItem
    let popover = NSPopover()
    private var timer: Timer?
    private var warning = false
    private var hosting: PopoverHostingController?
    private var lastTitle = ""
    private var lastImageRunning: Bool?
    /// What the item shows (idle / running + digit count). Its width must not change while the popover is open,
    /// or the popover (anchored to the item) slides sideways — the change waits until it closes.
    private var shownShape = ""
    /// The live dot (storyboard E · 1).
    private var dot: CALayer?
    private(set) var breathing = false
    /// The screen whose menu bar holds the icon (it moves with the active display when there are several).
    private var iconScreen: Int?
    static let dotSize: CGFloat = 6
    /// The small brand dot on the icon when something needs you (Unsent badge, variant V1 — the menu bar stays quiet
    /// otherwise: no count). Re-checked when the data changes and at most once a minute while a timer runs.
    private var needsYou = false
    private var needsYouCheckedAt: Date?
    private var needsYouLayer: CALayer?
    private var needsYouText = ""
    static let needsYouSize: CGFloat = 6

    init(model: AppModel) {
        self.model = model
        Self.prepareFirstPosition()
        item = Self.makeItem()
        super.init()
        MenuBarController.shared = self
        configureButton()

        let root = AnyView(PopoverView().environment(model).themed(model))
        let h = PopoverHostingController(rootView: root)
        h.sizingOptions = [.preferredContentSize]
        hosting = h
        popover.contentViewController = h
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        update()
        model.onDataChange.append { [weak self] in
            self?.needsYouCheckedAt = nil
            self?.update()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        watchVisibility()
    }

    // MARK: Place in the menu bar

    /// macOS keeps the item's place (and the user's ⌘-drag) under this name.
    static let autosaveName = "tikjot"
    private static var positionKey: String { "NSStatusItem Preferred Position \(autosaveName)" }
    /// The place macOS gives items before an autosave name existed.
    private static let legacyPositionKey = "NSStatusItem Preferred Position Item-0"

    /// New items land at the left end, the first to vanish behind the notch when the menu bar is full. On the very
    /// first launch tikjot asks for the right end instead (next to Control Center); a place the user chose stays.
    private static func prepareFirstPosition() {
        let d = UserDefaults.standard
        guard d.object(forKey: positionKey) == nil else { return }
        if let old = d.object(forKey: legacyPositionKey) {
            d.set(old, forKey: positionKey)
        } else {
            d.set(Double(1), forKey: positionKey)
        }
    }

    private static func makeItem() -> NSStatusItem {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        i.autosaveName = autosaveName
        i.isVisible = true
        return i
    }

    private func configureButton() {
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("tikjot")
        item.button?.imagePosition = .imageLeading
    }

    /// "Move to the right": re-creates the item at the right end of the menu bar (next to Control Center), so a
    /// full menu bar hides some other app's icon instead of tikjot.
    func moveToRightEnd() {
        if popover.isShown { popover.performClose(nil) }
        hideDot()
        needsYouLayer?.removeFromSuperlayer()
        needsYouLayer = nil
        NSStatusBar.system.removeStatusItem(item)
        UserDefaults.standard.set(Double(1), forKey: Self.positionKey)
        item = Self.makeItem()
        configureButton()
        lastTitle = ""
        lastImageRunning = nil
        shownShape = ""
        update()
        watchVisibility()
    }

    // MARK: Hidden by a full menu bar

    /// Debug/capture: behave as if the menu bar had no room.
    private let pretendHidden = LaunchFlags.args.contains("-pretendMenuBarHidden")
    private var visibilityObservers: [NSObjectProtocol] = []
    private var visibilityCheck: DispatchWorkItem?
    private var checkedOnce = false

    private func watchVisibility() {
        for o in visibilityObservers { NotificationCenter.default.removeObserver(o) }
        visibilityObservers = []
        let nc = NotificationCenter.default
        let again: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.scheduleVisibilityCheck() } }
        visibilityObservers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: again))
        if let w = item.button?.window {
            // Other apps' icons coming and going move ours.
            visibilityObservers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main, using: again))
            let moved: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.iconMoved() } }
            visibilityObservers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main, using: moved))
            visibilityObservers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main, using: again))
        }
        iconScreen = nil
        iconMoved()   // where it starts
        scheduleVisibilityCheck(after: 1.5)
    }

    private func scheduleVisibilityCheck(after delay: TimeInterval = 0.8) {
        visibilityCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkVisibility() } }
        visibilityCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Whether the icon really sits where you can see it. A full menu bar leaves the newest icons behind the
    /// notch or past the screen's edge — macOS gives no signal, so we look at where the item's window ended up.
    /// Only the horizontal place counts: an auto-hiding menu bar moves it up, which is not "hidden".
    var isVisibleInMenuBar: Bool {
        if pretendHidden { return false }
        guard item.isVisible, let w = item.button?.window, w.isVisible else { return false }
        let f = w.frame
        guard f.width > 0, let screen = NSScreen.screens.first(where: { f.midX >= $0.frame.minX && f.midX <= $0.frame.maxX }) else { return false }
        if f.minX < screen.frame.minX || f.maxX > screen.frame.maxX { return false }
        if let right = screen.auxiliaryTopRightArea, screen.auxiliaryTopLeftArea != nil, f.minX < right.minX - 1 { return false }
        return true
    }

    private func checkVisibility() {
        let hidden = !isVisibleInMenuBar
        guard hidden != model.menuBarHidden || !checkedOnce else { return }
        checkedOnce = true
        model.menuBarHidden = hidden
        Log.info("menu bar icon \(hidden ? "hidden" : "visible") at x \(Int(item.button?.window?.frame.minX ?? -1))")
        guard hidden else { return }
        // Once a day at most: the banner in the main window and the hint in Settings stay as long as it lasts.
        let d = UserDefaults.standard
        let today = model.today.description
        if d.string(forKey: "menuBarHiddenNotified") != today {
            d.set(today, forKey: "menuBarHiddenNotified")
            NotificationService.shared.menuBarHidden(hotkey: model.settings.hotkeyOpen)
        }
    }

    /// With several displays the icon moves to the active display's menu bar. Beta 2026-10-15 (two monitors,
    /// macOS 14.5): the app hung for seconds in AppKit's display switch (`_activeDisplayChanged`) — almost always
    /// with the popover open, and never without tikjot. The popover closes when the icon changes screens (as
    /// system menus do), and each switch is logged with what was up, next to the stall it may cause.
    /// Beta 2026-10-22 (0.9.8, owner saw it): the popover blinked in one screen's menu bar, then the spinning cursor
    /// for 30 s. It hangs from its own anchor now (`showPopover`), so it no longer rides along with the icon, and it
    /// closes at once here, without the closing animation.
    private func iconMoved() {
        guard let f = item.button?.window?.frame else { return }
        let screen = NSScreen.screens.firstIndex { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) }
        guard let screen, screen != iconScreen else { return }
        let first = iconScreen == nil
        iconScreen = screen
        guard !first, NSScreen.screens.count > 1 else { return }
        let wasOpen = popover.isShown
        if wasOpen {
            popover.animates = false   // back on in popoverDidClose
            popover.performClose(nil)
        }
        Log.info("menu bar moved to screen \(screen + 1) (popover \(wasOpen ? "closed by tikjot" : "closed"), dot \(breathing ? "breathing" : "still"))")
    }

    /// The breathing dot can be switched off for a test: `defaults write com.tikjot.mac menuBarDotBreathes -bool NO`
    /// (beta 2026-10-15: to learn whether it plays a part in the two-monitor hang before taking it away).
    static var dotBreathes: Bool { UserDefaults.standard.object(forKey: "menuBarDotBreathes") as? Bool ?? true }

    /// Runs only while a timer runs (idle → no wake-ups at all).
    private func setTicking(_ on: Bool) {
        if on, timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !on {
            timer?.invalidate()
            timer = nil
        }
    }

    func setWarning(_ on: Bool) {
        warning = on
        update()
    }

    func update() {
        guard let button = item.button else { return }
        refreshNeedsYou()
        let running = model.runningEntry
        let shape: String = {
            guard let r = running else { return "idle" + (warning ? "!" : "") }
            let time = model.settings.menuBarShowsTime ? DurationFormat.clock(Int(Clock.now.timeIntervalSince(r.start))) : ""
            return "run" + String(time.count) + (warning ? "!" : "")
        }()
        if popover.isShown && !shownShape.isEmpty && shape != shownShape {
            setTicking(running != nil)
            return
        }
        shownShape = shape
        if lastImageRunning != (running != nil) || button.image == nil {
            let img = NSImage(named: running == nil ? "MenuBarTemplate" : "MenuBarTick")
            img?.isTemplate = true
            img?.size = NSSize(width: 18, height: 18)
            button.image = img
            lastImageRunning = running != nil
        }
        setTicking(running != nil)
        if let r = running {
            let elapsed = Int(Clock.now.timeIntervalSince(r.start))
            let time = model.settings.menuBarShowsTime ? " " + DurationFormat.clock(elapsed) : ""
            let key = "dot" + time + (warning ? "!" : "") + needsYouText
            if key != lastTitle {
                // A transparent "●" keeps the dot's room in the text; the visible dot is the layer on top of it.
                let s = NSMutableAttributedString()
                s.append(NSAttributedString(string: " ", attributes: [.font: Self.dotFont]))
                s.append(NSAttributedString(string: "●", attributes: [.foregroundColor: NSColor.clear, .font: Self.dotFont]))
                s.append(NSAttributedString(string: time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]))
                if warning { s.append(NSAttributedString(string: " ⚠", attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
                button.attributedTitle = s
                lastTitle = key
                button.setAccessibilityValue("Running \(DurationFormat.hm(elapsed))" + needsYouText)
            }
            showDot(in: button)
        } else {
            hideDot()
            let t = warning ? " ⚠" : ""
            if t != lastTitle { button.title = t; lastTitle = t }
            button.setAccessibilityValue("Idle" + needsYouText)
        }
        showNeedsYou(in: button)
    }

    // MARK: Needs-you dot (Unsent badge, variant V1)

    private func refreshNeedsYou() {
        let now = Clock.now
        guard needsYouCheckedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        needsYouCheckedAt = now
        let b = model.unsentBadge
        needsYou = b.needsYou && !b.isHidden
        needsYouText = needsYou ? ", " + UnsentCountBadge.text(b) : ""
    }

    private func showNeedsYou(in button: NSStatusBarButton) {
        guard needsYou else {
            needsYouLayer?.removeFromSuperlayer()
            needsYouLayer = nil
            return
        }
        button.wantsLayer = true
        guard let host = button.layer else { return }
        let d: CALayer
        if let existing = needsYouLayer {
            d = existing
        } else {
            d = CALayer()
            d.cornerRadius = Self.needsYouSize / 2
            d.actions = ["position": NSNull(), "bounds": NSNull()]
            host.addSublayer(d)
            needsYouLayer = d
        }
        // Brand, resolved for the menu bar's own appearance (light #4B36D6 / dark #9C8CFF; variant V1, 2026-10-06).
        var color = NSColor.controlAccentColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (NSColor(named: "brand") ?? .controlAccentColor).cgColor
        }
        d.backgroundColor = color
        // On the icon's top-right corner.
        button.layoutSubtreeIfNeeded()
        let img = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let s = Self.needsYouSize
        let y = button.isFlipped ? img.minY : img.maxY - s
        d.frame = CGRect(x: (img.maxX - s + 1).rounded(), y: y.rounded(), width: s, height: s)
        d.contentsScale = button.window?.backingScaleFactor ?? 2
    }

    // MARK: Live dot (storyboard E)

    private static let dotFont = NSFont.systemFont(ofSize: 9)

    private func showDot(in button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let host = button.layer else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let d: CALayer
        if let existing = dot {
            d = existing
        } else {
            d = CALayer()
            d.cornerRadius = Self.dotSize / 2
            d.backgroundColor = (NSColor(named: "tick") ?? .systemPink).cgColor
            d.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
            host.addSublayer(d)
            dot = d
            breathing = false
            if !reduce {
                // Storyboard A · 6: fades in (200 → 400 ms), then breathes.
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.beginTime = CACurrentMediaTime() + 0.2
                fade.duration = 0.2
                fade.fillMode = .backwards
                fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                d.add(fade, forKey: "fadeIn")
            }
        }
        // Position over the transparent "●" in the title.
        button.layoutSubtreeIfNeeded()
        let title = button.cell?.titleRect(forBounds: button.bounds) ?? button.bounds
        let lead = NSAttributedString(string: " ", attributes: [.font: Self.dotFont]).size().width
        let glyph = NSAttributedString(string: "●", attributes: [.font: Self.dotFont]).size().width
        let s = Self.dotSize
        d.frame = CGRect(x: (title.minX + lead + glyph / 2 - s / 2).rounded(), y: (button.bounds.midY - s / 2).rounded(), width: s, height: s)
        d.contentsScale = button.window?.backingScaleFactor ?? 2

        // Breathing pauses after 10 s without user input (dimmed screen, other app in front) and with Reduce Motion.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let shouldBreathe = !reduce && idle < 10 && Self.dotBreathes
        if shouldBreathe != breathing {
            breathing = shouldBreathe
            if shouldBreathe {
                let b = CABasicAnimation(keyPath: "opacity")
                b.fromValue = 1
                b.toValue = 0.55
                b.duration = 1.2
                b.autoreverses = true
                b.repeatCount = .infinity
                b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut) // sine-like in-out
                b.beginTime = d.convertTime(CACurrentMediaTime(), from: nil) + (d.animation(forKey: "fadeIn") == nil ? 0 : 0.4)
                d.add(b, forKey: "breathe")
            } else {
                d.removeAnimation(forKey: "breathe")
            }
        }
    }

    private func hideDot() {
        guard let d = dot else { return }
        dot = nil
        breathing = false
        d.removeAllAnimations()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { d.removeFromSuperlayer(); return }
        // Storyboard B · 4: fades out (200 → 400 ms).
        CATransaction.begin()
        CATransaction.setCompletionBlock { d.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.2
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        d.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    @objc func togglePopover(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else if ProcessInfo.processInfo.systemUptime - closedAt > 0.4 {
            showPopover()
        }
        // else: the press on the icon already closed it (the icon isn't the popover's anchor) — it stays closed.
    }

    /// Uptime when the popover last started closing.
    private var closedAt: TimeInterval = -1

    /// Opens the timer. `anchor`: the control it belongs to (the main window's sidebar), else under the menu-bar
    /// icon — or, when a full menu bar hides the icon, the top right of the screen, where the icon would be.
    /// Under the icon it hangs from a strip of our own (`anchorWindow`) placed where the icon is, not from the icon:
    /// with two displays the icon moves to the other menu bar and AppKit would carry the popover along (#117, beta
    /// 2026-10-22).
    func showPopover(from anchor: NSView? = nil) {
        if popover.isShown { popover.close() }
        let view: NSView
        var edge = NSRectEdge.minY
        if let anchor, anchor !== item.button, anchor.window?.isVisible == true {
            view = anchor
            edge = .maxX
        } else if isVisibleInMenuBar, let f = item.button?.window?.frame {
            view = placeAnchor(NSRect(x: f.minX, y: f.minY, width: f.width, height: 1))
        } else {
            view = fallbackAnchor()
        }
        model.now = Clock.now
        model.popoverOpenedAt = Clock.now
        setWarning(false)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        guard !WindowManager.quiet else { return }
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopover() { popover.performClose(nil) }

    /// An invisible strip at the bottom of the menu bar for the popover to hang from: under the icon, or near the
    /// menu bar's right end when the icon is hidden.
    private lazy var anchorWindow: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.identifier = NSUserInterfaceItemIdentifier("popoverAnchor")
        return w
    }()

    private func placeAnchor(_ frame: NSRect) -> NSView {
        anchorWindow.setFrame(frame, display: false)
        anchorWindow.orderFrontRegardless()
        return anchorWindow.contentView!
    }

    private func fallbackAnchor() -> NSView {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        return placeAnchor(NSRect(x: vf.maxX - 240, y: vf.maxY - 1, width: 1, height: 1))
    }

    private func showMenu() {
        let menu = NSMenu()
        // Icons like the app menu's on macOS 26 (owner 2026-10-14: Check for Updates had none); older macOS hides them.
        func add(_ title: String, _ action: Selector, _ key: String, _ symbol: String) {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            i.target = self
            if #available(macOS 26, *) { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        }
        add("Open tikjot", #selector(openMain), "", "macwindow")
        add("Settings…", #selector(openSettings), ",", "gearshape")
        if Updates.available { add(String(localized: "Check for Updates…"), #selector(checkForUpdates), "", Updates.icon) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit tikjot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func openMain() { AppDelegate.shared?.windows.showMain(model) }
    @objc func openSettings() { AppDelegate.shared?.windows.showSettings(model) }
    @objc func checkForUpdates() { Updates.checkNow() }

    func popoverWillClose(_ notification: Notification) {
        closedAt = ProcessInfo.processInfo.systemUptime
    }

    func popoverDidClose(_ notification: Notification) {
        popover.animates = true
        model.popoverEditing = nil
        anchorWindow.orderOut(nil)
        update()   // apply a width change that waited for the popover
    }
}

/// The popover follows its content's size (`.preferredContentSize`). Beta 2026-10-14: macOS caught tikjot laying the
/// popover out again and again for minutes (50 % CPU), and a tester saw it blink with the spinning cursor — a size
/// that keeps changing makes the popover resize, which lays the content out, which changes the size. Sub-point
/// changes are ignored, and more than 8 changes within a second stop resizing until it calms down (logged once).
final class PopoverHostingController: NSHostingController<AnyView> {
    private var recent: [TimeInterval] = []
    private var tripped = false

    override var preferredContentSize: NSSize {
        get { super.preferredContentSize }
        set {
            let size = NSSize(width: newValue.width.rounded(), height: newValue.height.rounded())
            let old = super.preferredContentSize
            guard abs(size.width - old.width) >= 1 || abs(size.height - old.height) >= 1 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            recent = recent.filter { now - $0 < 1 } + [now]
            if recent.count > 8 {
                if !tripped {
                    Log.error("popover size loop (\(Int(old.height)) ↔ \(Int(size.height)) pt) — resizing paused")
                    tripped = true
                }
                // The last size still lands, once it has been quiet for a second.
                pending = size
                settle?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let p = self.pending else { return }
                        self.pending = nil
                        self.tripped = false
                        self.recent = []
                        self.preferredContentSize = p
                    }
                }
                settle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
                return
            }
            super.preferredContentSize = size
        }
    }
    private var pending: NSSize?
    private var settle: DispatchWorkItem?
}
