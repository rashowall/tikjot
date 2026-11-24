import AppKit
import SwiftUI

/// Main window, settings, onboarding and recovery windows (AppKit-managed: tikjot is a menu-bar app
/// that shows a Dock icon only while a window is open).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private var main: NSWindow?
    private var settings: NSWindow?
    private var onboarding: NSWindow?
    private var recovery: NSWindow?

    func showMain(_ model: AppModel) {
        if main == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "tikjot"
            w.identifier = NSUserInterfaceItemIdentifier("main")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.minSize = NSSize(width: 760, height: 560)
            w.isReleasedWhenClosed = false
            // Demo mode (screenshots, UI tests) never touches the user's saved window frame.
            if !model.demo { w.setFrameAutosaveName("tikjot.main") }
            let h = NSHostingController(rootView: MainView().environment(model).themed(model))
            h.sizingOptions = []
            w.contentViewController = h
            w.setContentSize(NSSize(width: 1240, height: 820))
            w.delegate = self
            if model.demo || !w.setFrameUsingName("tikjot.main") { w.center() }
            main = w
            watchTrafficLights(w)
        }
        present(main!)
        Self.placeTrafficLights(main!)
    }

    // MARK: Traffic lights inside the glass sidebar

    /// macOS 26: the glass sidebar floats 8 pt inside the window, so the window buttons move into it — concentric
    /// with its corner — instead of sitting on its edge (the way Electron's `trafficLightPosition` does it: a taller
    /// title-bar container, buttons centred in it). AppKit lays the buttons out again on resize, key changes and
    /// full screen, so this is re-applied then.
    static let trafficLightInset: CGFloat = 19

    static func placeTrafficLights(_ w: NSWindow) {
        guard LiquidGlass.isAvailable, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton), let titlebar = close.superview,
              let container = titlebar.superview else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
        let inset = trafficLightInset
        let height = close.frame.height + 2 * inset
        var f = container.frame
        if f.height != height || f.minY != w.frame.height - height {
            f.size.height = height
            f.origin.y = w.frame.height - height
            container.frame = f
        }
        let dx = inset - close.frame.minX
        for b in buttons {
            var o = b.frame.origin
            o.x += dx
            o.y = titlebar.isFlipped ? inset : height - inset - b.frame.height
            if o != b.frame.origin { b.setFrameOrigin(o) }
        }
    }

    private var trafficLightObservers: [NSObjectProtocol] = []

    private func watchTrafficLights(_ w: NSWindow) {
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                          NSWindow.didExitFullScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                                          NSWindow.didBecomeMainNotification]
        for n in names {
            trafficLightObservers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak w] _ in
                MainActor.assumeIsolated { if let w { Self.placeTrafficLights(w) } }
            })
        }
    }

    func showSettings(_ model: AppModel, tab: SettingsTab? = nil) {
        if let tab { model.settingsTab = tab }
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = model.settingsTab.title
            w.identifier = NSUserInterfaceItemIdentifier("settings")
            // The SwiftUI toolbar draws the title and the tabs on one surface (design "Settings · …").
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            let h = NSHostingController(rootView: SettingsView().environment(model).themed(model))
            h.sizingOptions = [.preferredContentSize]
            // The toolbar sits under the transparent title bar (traffic lights over it), so no title-bar inset.
            h.safeAreaRegions = []
            w.contentViewController = h
            w.delegate = self
            w.center()
            settings = w
        }
        present(settings!)
    }

    func showOnboarding(_ model: AppModel) {
        if onboarding == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OnboardingView().environment(model).themed(model))
            w.delegate = self
            w.center()
            onboarding = w
        }
        present(onboarding!)
    }

    func closeOnboarding() {
        onboarding?.close()
        onboarding = nil
    }

    func showCantOpen(_ reason: CantOpenView.Reason = .keyMissing) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: CantOpenView(reason: reason))
        w.delegate = self
        w.center()
        recovery = w
        present(w)
    }

    func closeRecovery() { recovery?.close(); recovery = nil }

    private func present(_ w: NSWindow) {
        // Captures render in the background: no Dock icon, no focus stolen from whatever you are doing.
        if Self.quiet { w.orderFrontRegardless(); return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// `-capture` runs (scripts/capture.sh) never take focus.
    static let quiet = LaunchFlags.args.contains("-capture")

    var mainIsVisible: Bool { main?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async {
            // Only our own windows count, and never the one that is closing.
            let anyVisible = [self.main, self.settings, self.onboarding, self.recovery].contains { $0 !== closing && $0?.isVisible == true }
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
        if (notification.object as? NSWindow) === onboarding {
            onboarding = nil
            // Closed after connecting Jira: setup is done, don't greet again on the next launch.
            if let m = AppDelegate.shared?.model, !m.settings.onboardingDone, !m.data.instances.isEmpty {
                m.updateSettings { $0.onboardingDone = true }
            }
        }
    }
}

extension View {
    /// Applies Settings › Appearance (System / Light / Dark).
    func themed(_ model: AppModel) -> some View { modifier(ThemeModifier(model: model)) }
}

struct ThemeModifier: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        content.preferredColorScheme(model.settings.appearance == "dark" ? .dark : model.settings.appearance == "light" ? .light : nil)
            .environment(\.locale, Locale(identifier: model.language))
            .tint(DS.C.brand)
    }
}
