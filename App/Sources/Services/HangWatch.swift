import AppKit
import Darwin

/// Logs when the main thread stops answering for 2 s or more — the spinning cursor macOS shows over the menu bar
/// icon (beta 2026-10-13: a tester saw it, with icons jumping, during a Teams call with camera on two screens; we
/// couldn't reproduce it). A background queue pings the main queue every second; the stall is logged once the main
/// thread answers again, with how long it took and what was on screen. Uptime doesn't count sleep, so a sleeping Mac
/// isn't a stall.
///
/// Beta 2026-10-14: the first log showed the stalls but not their cause, and macOS caught tikjot at 50 % CPU for
/// minutes laying out the popover. So while the main thread is stuck (at about 2, 5 and 10 s), and when tikjot has
/// used more than 40 % CPU over a minute, the main thread's call stack is logged too: library + offset per frame
/// (tikjot's own frames symbolicate with the release's dSYM: `atos -o tikjot.app.dSYM -l 0x100000000 <0x100000000+off>`).
enum HangWatch {
    private static let queue = DispatchQueue(label: "tikjot.hangwatch", qos: .utility)
    /// All below only touched on `queue` (`mainThread` set once before the timer starts).
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    /// Uptime (ns) of the ping the main thread hasn't answered yet; nil when it answered.
    nonisolated(unsafe) private static var pending: UInt64?
    /// Stack samples already taken during the current stall.
    nonisolated(unsafe) private static var samplesThisStall = 0
    nonisolated(unsafe) private static var mainThread: thread_act_t = 0
    /// Frames are written here while the main thread is suspended — no allocation then (it may hold the malloc lock).
    nonisolated(unsafe) private static let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
    private static let maxFrames = 48
    /// Process CPU time (s) at uptime (s), one reading every 10 s, the last minute of them.
    nonisolated(unsafe) private static var cpuReadings: [(uptime: Double, cpu: Double)] = []
    nonisolated(unsafe) private static var ticks = 0
    nonisolated(unsafe) private static var lastCPUReport = -Double.infinity

    static let threshold: UInt64 = 2_000_000_000
    /// Seconds into a stall when the stack is sampled.
    private static let sampleAt: [Double] = [2, 5, 10]

    @MainActor
    static func start() {
        let main = mach_thread_self()
        queue.async {
            guard timer == nil else { return }
            mainThread = main
            frames.initialize(repeating: 0, count: maxFrames)   // first touch here, not while main is suspended
            _ = addressMask
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 1, leeway: .milliseconds(300))
            t.setEventHandler(handler: ping)
            t.resume()
            timer = t
        }
        logDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { logDisplays() }
        }
    }

    // MARK: Displays

    /// Beta 2026-10-22: the two-monitor hang (#117) is still there on one tester's Mac and not on any we have — so
    /// the log says what the displays are (size, scale, refresh, colour profile, separate Spaces), at launch and on
    /// every change.
    @MainActor private static var lastDisplays = ""

    @MainActor
    private static func logDisplays() {
        let d = displays()
        guard d != lastDisplays else { return }
        lastDisplays = d
        Log.info("displays: " + d)
    }

    @MainActor
    private static func displays() -> String {
        let list = NSScreen.screens.enumerated().map { i, s in
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            var parts = ["\(i + 1) \(s.localizedName) \(Int(s.frame.width))×\(Int(s.frame.height)) pt @\(Int(s.backingScaleFactor))x",
                         "\(s.maximumFramesPerSecond) Hz", s.colorSpace?.localizedName ?? "no colour space"]
            if let id, CGDisplayIsBuiltin(id) != 0 { parts.append("built-in") }
            if let id, CGDisplayIsInMirrorSet(id) != 0 { parts.append("mirrored") }
            return parts.joined(separator: ", ")
        }
        return list.joined(separator: " · ") + "; separate Spaces \(NSScreen.screensHaveSeparateSpaces ? "yes" : "no")"
    }

    /// Which screen each of tikjot's visible windows is on ("icon 2, popover 2, main 1").
    @MainActor
    private static func windowScreens(_ mb: MenuBarController?) -> String {
        let popover = mb?.popover.contentViewController?.view.window
        let icon = mb?.item.button?.window
        let names = NSApp.windows.filter(\.isVisible).map { w -> String in
            let name = w === icon ? "icon" : w === popover ? "popover" : (w.identifier?.rawValue ?? "other")
            let screen = w.screen.flatMap { NSScreen.screens.firstIndex(of: $0) }.map { String($0 + 1) } ?? "none"
            return "\(name) \(screen)"
        }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    /// On `queue`.
    private static func ping() {
        ticks += 1
        if ticks % 10 == 0 { checkCPU() }
        if let sent = pending {
            // Still waiting: the main thread is stuck — look at what it is doing.
            let waited = Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1e9
            if samplesThisStall < sampleAt.count, waited >= sampleAt[samplesThisStall] {
                samplesThisStall += 1
                Log.error(String(format: "main thread stuck %.0f s: ", waited) + mainStack())
            }
            return
        }
        let sent = DispatchTime.now().uptimeNanoseconds
        pending = sent
        DispatchQueue.main.async {
            let answered = DispatchTime.now().uptimeNanoseconds
            let stalled = answered &- sent
            if stalled >= threshold { MainActor.assumeIsolated { report(seconds: Double(stalled) / 1e9) } }
            queue.async { pending = nil; samplesThisStall = 0 }
        }
    }

    @MainActor
    private static func report(seconds: Double) {
        let mb = MenuBarController.shared
        let x = mb?.item.button?.window?.frame.minX ?? -1
        let state = [
            "screens \(NSScreen.screens.count)",
            "popover \(mb?.popover.isShown == true ? "open" : "closed")",
            "timer \(mb?.model.runningEntry != nil ? (mb?.breathing == true ? "running, dot breathing" : "running, dot still") : "idle")",
            "menu bar x \(Int(x))",
            "main window \(NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == "main" } ? "open" : "closed")",
            "frontmost \(NSApp.isActive ? "yes" : "no")",
            "windows on screens: \(windowScreens(mb))",
        ].joined(separator: ", ")
        Log.error(String(format: "main thread stalled %.1f s (%@)", seconds, state))
    }

    // MARK: CPU

    /// On `queue`, every 10 s: more than 40 % CPU over the last minute → log it with three looks at the main thread
    /// (at most every 10 minutes). macOS itself only reports 50 % over three minutes.
    private static func checkCPU() {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return }
        let cpu = Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        let now = ProcessInfo.processInfo.systemUptime
        cpuReadings.append((now, cpu))
        cpuReadings.removeAll { now - $0.uptime > 65 }
        guard let first = cpuReadings.first, now - first.uptime >= 55, now - lastCPUReport > 600 else { return }
        let share = (cpu - first.cpu) / (now - first.uptime)
        guard share > 0.4 else { return }
        lastCPUReport = now
        var looks: [String] = []
        for i in 0..<3 {
            if i > 0 { usleep(150_000) }
            looks.append(mainStack())
        }
        Log.error(String(format: "high CPU %.0f %% over %.0f s; main thread: ", share * 100, now - first.uptime)
                  + looks.joined(separator: " ‖ "))
    }

    // MARK: Main thread stack

    /// On `queue`. Suspends the main thread for the few microseconds it takes to copy its frame-pointer chain.
    private static func mainStack() -> String {
        let n = captureMain()
        guard n > 0 else { return "(no stack)" }
        var out: [String] = []
        var previous = ""
        var repeats = 0
        for i in 0..<n {
            let s = describe(frames[i])
            if s == previous { repeats += 1; continue }
            if repeats > 0 { out.append("×\(repeats + 1)"); repeats = 0 }
            out.append(s)
            previous = s
        }
        return out.joined(separator: " < ")
    }

    /// Copies the main thread's return addresses into `frames`; returns how many. Nothing here allocates.
    private static func captureMain() -> Int {
        guard mainThread != 0, thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainThread) }
        var n = 0
        var fp: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        frames[0] = UInt(state.__pc) & addressMask; n = 1
        frames[1] = UInt(state.__lr) & addressMask; n = 2
        fp = UInt(state.__fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(mainThread, x86_THREAD_STATE64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        frames[0] = UInt(state.__rip); n = 1
        fp = UInt(state.__rbp)
        #endif
        // Each frame record: [saved frame pointer, return address]. Read with vm_read_overwrite so a bad pointer
        // ends the walk instead of crashing.
        var record: (UInt, UInt) = (0, 0)
        while n < maxFrames, fp != 0, fp % 8 == 0 {
            var got: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &record) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(16), vm_address_t(UInt(bitPattern: $0)), &got)
            }
            guard ok == KERN_SUCCESS, got == 16 else { break }
            let ret = record.1 & addressMask
            guard ret != 0 else { break }
            frames[n] = ret; n += 1
            guard record.0 > fp else { break }   // stacks grow down: the caller's frame is higher
            fp = record.0
        }
        return n
    }

    /// Strips pointer-authentication bits (system code is arm64e).
    private static let addressMask: UInt = 0x0000_7FFF_FFFF_FFFF

    private static func describe(_ pc: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0, let base = info.dli_fbase else { return String(format: "0x%lx", pc) }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let offset = pc - UInt(bitPattern: base)
        if let sym = info.dli_sname, image != "tikjot" {
            var name = String(cString: sym)
            if name.count > 60 { name = String(name.prefix(60)) + "…" }
            return "\(image) \(name)"
        }
        return String(format: "%@+0x%lx", image, offset)
    }
}
