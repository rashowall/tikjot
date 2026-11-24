import SwiftUI
import JiraKit
import SyncEngine
import TikjotDomain
import TikjotHolidays
import TikjotPersistence

/// First launch (§11.7, design "Onboarding · shorter"): Welcome → Connect Jira (skippable) → Work time → Import your
/// worklogs → Projects (only when the import found some) → You're set. On the first evening a single nudge asks you
/// to send the day (`BackgroundServices.checkReminders`).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    /// Raw values are the design's step numbers, which captures use (`-openOnboarding -onboardingStep n`):
    /// 1 welcome · 2 connect Jira · 3 work time · 4 import (4b "nothing found" is the same step) · 5 projects · 6 ready.
    enum Step: Int, CaseIterable { case welcome = 1, jira, work, importHistory, projects, done }
    @State private var step: Step = .welcome
    @State private var connected: JiraInstance?
    /// Direction of the last step change: forward slides in from the right, back from the left.
    @State private var forward = true
    /// The one evening reminder on the last step (ticked: macOS is asked for notifications when you finish).
    @State private var remindTonight = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let edgeIn: Edge = forward ? .trailing : .leading
        let edgeOut: Edge = forward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: edgeIn).combined(with: .opacity),
                           removal: .move(edge: edgeOut).combined(with: .opacity))
    }

    private func go(_ s: Step, forward f: Bool) {
        forward = f
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.88)) { step = s }
    }

    private var isSetup: Bool { step != .welcome && step != .done }

    // Design: content top-aligned under the title bar; setup steps (jira…projects) on $bg with a step head and a
    // footer with a hairline; welcome and ready on $surface.
    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcomeStep
                case .jira: jiraStep
                case .work: WorkStep(head: setupHead)
                case .importHistory: ImportStep(instance: connected, head: setupHead)
                case .projects: ProjectsStep(head: setupHead)
                case .done: doneStep
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding.step.\(String(describing: step))")
            .id(step)
            .transition(stepTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, isSetup ? 40 : 60).padding(.top, isSetup ? 8 : 10)
            .clipped()
            if step != .importHistory && step != .projects { footer }
        }
        // The window is the 720 × 540 board, title bar (32 pt) included: content 508 below it, the
        // background runs under the title bar.
        .frame(width: 720, height: 508)
        .background((isSetup ? DS.C.bg : DS.C.surface).ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .onboardingNext)) { _ in next() }
        .onReceive(NotificationCenter.default.publisher(for: .onboardingBack)) { _ in back() }
        .onAppear {
            // First launch: suggest the holiday country from the Mac's region (the stored default stays SK).
            if !model.settings.onboardingDone && model.settings.holidayCountry == "SK" {
                let suggested = HolidayEngine.defaultCountry(forRegion: Locale.current.region?.identifier)
                if suggested != "SK" { model.updateSettings { $0.holidayCountry = suggested } }
            }
            let a = LaunchFlags.args
            if let i = a.firstIndex(of: "-onboardingStep"), a.indices.contains(i + 1), let n = Int(a[i + 1]), let s = Step(rawValue: n) {
                // Captures of the later steps show the Jira path (the demo has a connection).
                if s.rawValue > Step.jira.rawValue { connected = model.activeInstances.first }
                // The demo's projects already cover its keys: give the projects capture what an import would find.
                if s == .projects, model.demo, model.unmappedKeys().isEmpty, let id = connected?.id {
                    model.pendingProjectSuggestions = ["SHOP": ("Webshop", id), "HR": ("People", id), "MKT": ("Marketing", id), "LAB": ("Innovation lab", id)]
                }
                step = s
            }
        }
    }

    /// "Step N of M" head above a setup step's title (design W8zLgy): 24 × 6 active pill, 8 × 6 others.
    private var setupHead: some View {
        let flow = setupFlow
        let index = flow.firstIndex(of: step) ?? 0
        return HStack(spacing: 6) {
            ForEach(0..<flow.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3).fill(i <= index ? DS.C.brand : DS.C.border).frame(width: i == index ? 24 : 8, height: 6)
            }
            Text(String(localized: "Step \(index + 1) of \(flow.count)")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text3).padding(.leading, 2)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch step {
            case .welcome:
                Spacer()
                Button { next() } label: { Label(String(localized: "Get started"), systemImage: "arrow.right") }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.next")
            case .jira:
                Button(String(localized: "Back")) { back() }.buttonStyle(.pill).accessibilityIdentifier("onboarding.back")
                Spacer()
                Button(String(localized: "Or continue without Jira — connect later in Settings")) { connected = nil; go(.work, forward: true) }
                    .buttonStyle(LinkButtonStyle(color: DS.C.text3)).font(DS.F.caption)
                    .accessibilityIdentifier("onboarding.withoutJira")
                Button { NotificationCenter.default.post(name: .onboardingConnect, object: nil) } label: { Label(String(localized: "Connect"), systemImage: "powerplug") }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            case .work:
                Button(String(localized: "Back")) { back() }.buttonStyle(.pill).accessibilityIdentifier("onboarding.back")
                Spacer()
                Button { next() } label: { HStack(spacing: 6) { Text(String(localized: "Continue")); Image(systemName: "arrow.right") } }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.next")
            case .importHistory, .projects:
                // These steps draw their own actions (they depend on the import / create the projects).
                EmptyView()
            case .done:
                Button(String(localized: "Back")) { back() }.buttonStyle(.pill).accessibilityIdentifier("onboarding.back")
                Spacer()
                Button { openTikjot() } label: { Label(String(localized: "Open tikjot"), systemImage: "macwindow") }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.openTikjot")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .frame(minHeight: 64)
        .overlay(alignment: .top) { if isSetup { Rectangle().fill(DS.C.border).frame(height: 1) } }
    }

    /// Your path: without Jira no import and no projects. With Jira the projects step counts until the import shows
    /// it isn't needed — the last step has no counter, so a skipped "4 of 4" never shows.
    private var setupFlow: [Step] {
        let jira = connected != nil || step == .jira
        return [.jira, .work] + (jira ? [.importHistory, .projects] : [])
    }

    private func next() {
        switch step {
        case .work: go(connected == nil ? .done : .importHistory, forward: true)
        case .importHistory: go(model.unmappedKeys().isEmpty ? .done : .projects, forward: true)
        default: go(Step(rawValue: step.rawValue + 1) ?? .done, forward: true)
        }
    }

    private func back() {
        switch step {
        case .done: go(connected == nil ? .work : (model.unmappedKeys().isEmpty ? .importHistory : .projects), forward: false)
        default: go(Step(rawValue: step.rawValue - 1) ?? .welcome, forward: false)
        }
    }

    // Design "1 Welcome" (W8w32): one card instead of three — 320 × 240 art, display 26/800, 14 pt body.
    private var welcomeStep: some View {
        VStack(spacing: 12) {
            Illustration(name: "illOnboardTrack", width: 320)
            Text(String(localized: "Welcome to tikjot")).font(DS.F.display(26, .heavy))
            Text(String(localized: "Track work with one click from the menu bar, fix your day like a calendar, and send it to Jira when you're ready. Setup takes about two minutes."))
                .font(.system(size: 14)).lineSpacing(7).foregroundStyle(DS.C.text2).multilineTextAlignment(.center).frame(maxWidth: 470)
        }
        .frame(maxWidth: .infinity)
    }

    private var jiraStep: some View {
        ScrollView { VStack(alignment: .leading, spacing: 12) {
            setupHead
            Text(String(localized: "Connect your Jira")).font(DS.F.display(24, .heavy))
            Text(String(localized: "tikjot reads tasks and your own worklogs, and sends only what you review. Data Center / Server uses a personal access token (PAT)."))
                .font(DS.F.body).foregroundStyle(DS.C.text2)
            ConnectJiraForm(existing: nil, done: {}, compact: true) { inst in
                connected = inst
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { go(.work, forward: true) }
            }
        }.padding(.trailing, 8) }
        .scrollIndicators(.automatic)
    }

    /// Design "6 Ready" (FjOIr, beta feedback row 5): a menu-bar strip with tikjot highlighted, an arrow up, the title
    /// with your name, what's ready, the two places tikjot works in and the one evening reminder.
    private var doneStep: some View {
        let first = (model.activeInstances.first?.displayName ?? "").split(separator: " ").first.map(String.init)
        let hotkey = model.settings.hotkeyOpen
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75"); Image(systemName: "magnifyingglass")
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text("tikjot").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(DS.C.onBrand).padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(DS.C.brand))
                Text("\(Fmt.weekdayShort(model.today)) \(Fmt.time(Clock.now))").font(.system(size: 11))
            }
            .font(.system(size: 11)).foregroundStyle(DS.C.text2)
            .padding(.horizontal, 14).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.C.surface2))
            Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.C.brand)
            Text(first.map { String(localized: "You're set, \($0)") } ?? String(localized: "You're set")).font(DS.F.display(28, .heavy))
            Text(summary + String(localized: "tikjot works in two places:"))
                .font(.system(size: 14)).lineSpacing(5).foregroundStyle(DS.C.text2).multilineTextAlignment(.center).frame(maxWidth: 500)
            HStack(alignment: .top, spacing: 12) {
                ForEach(TwoPlaces.allCases, id: \.self) { p in
                    TwoPlacesLine(place: p, hotkey: hotkey, tile: 32)
                        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(DS.C.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.C.border))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if model.jiraConnected {
                // The one evening nudge (design hOI5c). Ticked, macOS is asked for notifications when you finish.
                Toggle(isOn: $remindTonight) {
                    Text(Self.firstNudgeDay(model) == model.today
                         ? String(localized: "Tonight tikjot reminds you once: “Send today to Jira · it takes 2 minutes”.")
                         : String(localized: "At the end of your next workday tikjot reminds you once: “Send today to Jira · it takes 2 minutes”."))
                        .font(.system(size: 12)).foregroundStyle(DS.C.text)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(DS.C.brandSoft))
                .accessibilityIdentifier("onboarding.remindTonight")
            }
            if model.menuBarHidden {
                BannerView(kind: .warning, icon: "menubar.rectangle",
                           text: String(localized: "Your menu bar is full, so macOS hides tikjot's icon. Move it to the right end — or use ⌥⌘T and the main window."),
                           action: String(localized: "Move to the right")) { MenuBarController.shared?.moveToRightEnd() }
                    .frame(maxWidth: 440)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// "4 projects are ready and your history is imported: balance +4h 19m since 1 Sep. " (with its trailing space).
    private var summary: String {
        let n = model.data.projects.filter { !$0.archived }.count
        let imported = model.data.entries.contains { $0.source == .imported }
        if imported, let start = model.data.instances.compactMap(\.historyStartDate).min() {
            let bal = DurationFormat.signed(model.ledger.cumulativeBalance(since: start, opening: model.settings.openingBalance))
            let since = Fmt.dayMonth(start)
            return (n > 0 ? String(localized: "\(n) projects are ready and your history is imported: balance \(bal) since \(since).")
                          : String(localized: "Your history is imported: balance \(bal) since \(since).")) + " "
        }
        return n > 0 ? String(localized: "\(n) projects are ready") + ". " : ""
    }

    /// The day of the one evening nudge: today while its working day has more than half an hour to go, else the next workday.
    static func firstNudgeDay(_ model: AppModel) -> LocalDate {
        let cal = model.dayCalendar
        let minutes = Calendar.current.component(.hour, from: Clock.now) * 60 + Calendar.current.component(.minute, from: Clock.now)
        var d = model.today
        if cal.isWorkday(d) && !cal.isDayOff(d) && minutes < model.schedule.period(on: d).workdayEnd - 30 { return d }
        for _ in 0..<14 {
            d = d.adding(days: 1)
            if cal.isWorkday(d) && !cal.isDayOff(d) { break }
        }
        return d
    }

    /// Both places once (beta feedback row 5): the main window on today with the one-time "Two places" card, then
    /// the popover drops down from the menu-bar icon like ⌥⌘T — the timer's field (idle) or the task switcher (running).
    private func openTikjot() {
        finish()
        let m = model
        // Demo: nothing remembered for the everyday app.
        if !m.demo { UserDefaults.standard.set(true, forKey: TwoPlacesCard.pendingKey) }
        m.selectedDay = m.today
        m.mainSelection = .day
        AppDelegate.shared?.windows.showMain(m)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MenuBarController.shared?.showPopover()
            if m.runningEntry == nil { m.focusTimerDescription() } else { m.popoverEditing = .picker(.timer) }
        }
    }

    private func finish() {
        model.updateSettings { $0.onboardingDone = true }
        // Demo: no real notifications, nothing remembered for the everyday app.
        if remindTonight && model.jiraConnected && !model.demo {
            UserDefaults.standard.set(Self.firstNudgeDay(model).description, forKey: NotificationService.firstDayNudgeKey)
            if NotificationService.shared.authorized != true { Task { _ = await NotificationService.shared.requestAuthorization() } }
        }
        AppDelegate.shared?.windows.closeOnboarding()
        AppDelegate.shared?.services?.applyLaunchAtLogin()
    }
}

extension Notification.Name {
    static let onboardingNext = Notification.Name("tikjot.onboardingNext")
    static let onboardingBack = Notification.Name("tikjot.onboardingBack")
    static let onboardingConnect = Notification.Name("tikjot.onboardingConnect")
}

// MARK: Two places (beta feedback row 5)

/// Where tikjot works: you track in the menu bar, you fix and send in the window.
enum TwoPlaces: CaseIterable { case menuBar, window }

/// One place: an icon tile, its title and what you do there (Ready step tiles and the main window's card).
struct TwoPlacesLine: View {
    let place: TwoPlaces
    let hotkey: String
    /// Icon tile side: 32 on the Ready step, 28 in the card.
    var tile: CGFloat = 28

    var body: some View {
        HStack(alignment: tile > 28 ? .top : .center, spacing: 12) {
            Image(systemName: place == .menuBar ? "timer" : "macwindow")
                .font(.system(size: tile / 2, weight: .medium)).foregroundStyle(DS.C.brand)
                .frame(width: tile, height: tile)
                .background(RoundedRectangle(cornerRadius: tile / 4).fill(DS.C.brandSoft))
            VStack(alignment: .leading, spacing: tile > 28 ? 3 : 1) {
                Text(place == .menuBar ? String(localized: "In the menu bar — track") : String(localized: "In the tikjot window — fix & send"))
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(DS.C.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch place {
        case .menuBar: hotkey.isEmpty ? String(localized: "Start, switch, stop") : String(localized: "Start, switch, stop · \(hotkey) from anywhere")
        case .window: String(localized: "Fix your day like a calendar and send it to Jira")
        }
    }
}

/// Shown once in the main window (Day), right after onboarding's "Open tikjot": the same two places, "Got it".
struct TwoPlacesCard: View {
    @Environment(AppModel.self) private var model
    /// Set by onboarding's "Open tikjot", cleared by "Got it".
    static let pendingKey = "tikjot.twoPlacesCard"
    @AppStorage(Self.pendingKey) private var pending = false

    var body: some View {
        if pending && model.mainSelection == .day {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "Two places, one job")).font(DS.F.display(18, .heavy))
                ForEach(TwoPlaces.allCases, id: \.self) { TwoPlacesLine(place: $0, hotkey: model.settings.hotkeyOpen) }
                HStack {
                    Spacer()
                    Button(String(localized: "Got it")) { withAnimation(.easeOut(duration: 0.2)) { pending = false } }
                        .buttonStyle(.primaryPill)
                        .accessibilityIdentifier("main.twoPlaces.gotIt")
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 8)
            .transition(.opacity)
        }
    }
}

/// Work time (pre-filled): hours, workdays, working hours, holidays. A carried-over balance is set only in
/// Settings › Work time (beta feedback row 1: "balance" isn't explained yet at this point).
struct WorkStep<Head: View>: View {
    @Environment(AppModel.self) private var model
    let head: Head
    @State private var hours = 8.0
    @State private var workdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var start = Clock.now
    @State private var end = Clock.now

    // Design (o7LMFe): one grouped card like Settings › Work time.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            head
            Text(String(localized: "Your work time")).font(DS.F.display(24, .heavy))
            Text(String(localized: "So tikjot knows your expected hours — how many hours a day should have. You can change it later.")).font(DS.F.body).foregroundStyle(DS.C.text2)
            SettingsSection {
                SettingsRow(label: String(localized: "Hours per day")) {
                    LengthField(label: "", seconds: Binding(get: { Int(hours * 3600) }, set: { hours = Double($0) / 3600 }), step: 1800, range: 3600...12 * 3600).frame(width: 90)
                }
                SettingsRow(label: String(localized: "Workdays")) {
                    HStack(spacing: 4) { ForEach(LocalDate.weekdayOrder, id: \.self) { d in workday(d) } }
                }
                SettingsRow(label: String(localized: "Working hours"), hint: String(localized: "For reminders and for placing time typed into the week")) {
                    HStack(spacing: 6) {
                        TimeField(label: "", date: $start, day: model.today).frame(width: 84)
                        Text("–").foregroundStyle(DS.C.text3)
                        TimeField(label: "", date: $end, day: model.today).frame(width: 84)
                    }
                }
                SettingsRow(label: String(localized: "Public holidays")) {
                    SettingsPopup(selection: Binding(get: { model.settings.holidayCountry }, set: { v in model.updateSettings { $0.holidayCountry = v } }),
                                  options: HolidayEngine.countries(sortedFor: model.language).map { ($0, HolidayEngine.countryName($0, language: model.language)) },
                                  extra: [("NONE", String(localized: "None"))])
                }
            }
        }
        .onAppear {
            let p = model.schedule.current
            hours = p.dailyHours; workdays = p.workdays
            start = model.today.at(minutes: p.workdayStart, in: .current)
            end = model.today.at(minutes: p.workdayEnd, in: .current)
        }
        .onDisappear(perform: save)
    }

    private func workday(_ d: Int) -> some View {
        let on = workdays.contains(d)
        let date = LocalDate(year: 2026, month: 9, day: 27 + d)
        let letter = Fmt.locale.identifier.hasPrefix("sk") ? String(Fmt.weekdayShort(date).prefix(2)) : Calendar.current.veryShortStandaloneWeekdaySymbols[d % 7]
        return Button { if on { workdays.remove(d) } else { workdays.insert(d) } } label: {
            Text(letter).font(.system(size: 10, weight: .bold)).frame(width: 26, height: 26)
                .foregroundStyle(on ? DS.C.onBrand : DS.C.text3)
                .background(Circle().fill(on ? DS.C.brand : DS.C.surface2))
                .contentShape(Circle())
        }
        .buttonStyle(.dot)
        .accessibilityLabel(Fmt.weekday(date))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func save() {
        var s = model.schedule
        let sm = Calendar.current.component(.hour, from: start) * 60 + Calendar.current.component(.minute, from: start)
        let em = Calendar.current.component(.hour, from: end) * 60 + Calendar.current.component(.minute, from: end)
        // First setup: the contract applies to all history.
        s.change(from: LocalDate(year: 2000, month: 1, day: 1)) { $0.dailyHours = hours; $0.workdays = workdays; $0.workdayStart = sm; $0.workdayEnd = em }
        var c = Changes(); c.upsertSchedule = s.periods
        model.applySilently(c)
    }
}

/// Import your worklogs (design XJ9uF, nothing found U3adP): start date + presets, what was found, one button.
struct ImportStep<Head: View>: View {
    @Environment(AppModel.self) private var model
    let instance: JiraInstance?
    let head: Head
    @State private var from = Clock.now
    @State private var preset: Int?
    @State private var preview: SyncEngine.ImportPreview?
    @State private var counting = false
    @State private var running = false
    @State private var finished = false
    @State private var error: String?

    private var inst: JiraInstance? { instance ?? model.activeInstances.first }
    private var fromDay: LocalDate { LocalDate(from, calendar: .current) }
    /// Last month can still be sent (the default then includes it).
    private var lastMonthOpen: Bool { Nudges.importStart(today: model.today, lock: model.lock) < model.today.firstOfMonth }
    /// Nothing found and a longer window exists: offer "Try this year".
    private var canTryYear: Bool { preset != Self.thisYear && presetDate(Self.thisYear) < fromDay }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            head
            Text(String(localized: "Import your worklogs")).font(DS.F.display(24, .heavy))
            Text(lastMonthOpen
                 ? String(localized: "So your balance and statistics are right from day one. Last month is included while it's still open (until \(Fmt.dayMonth(model.lock.editableUntil(model.today.firstOfMonth.adding(months: -1))))). Nothing is sent back.")
                 : String(localized: "So your balance and statistics are right from day one. Nothing is sent back."))
                .font(DS.F.body).foregroundStyle(DS.C.text2)
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Start from")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                HStack(spacing: 8) {
                    Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(DS.C.text3)
                    DateFieldButton(date: Binding(get: { fromDay }, set: { from = Fmt.date($0); if !matchesPreset { preset = nil } }), width: 160, range: Date.distantPast...Date())
                }
                .disabled(running || finished)
            }
            HStack(spacing: 8) {
                // While last month is open: This month · Last + this month · This year; once closed: Last month ·
                // This month · This year. The default (the middle one) is where the history can still be sent.
                if lastMonthOpen {
                    chip(Self.thisMonth, String(localized: "This month"))
                    chip(Self.lastMonth, String(localized: "Last + this month"))
                } else {
                    chip(Self.lastMonth, String(localized: "Last month"))
                    chip(Self.thisMonth, String(localized: "This month"))
                }
                chip(Self.thisYear, String(localized: "This year"))
            }
            .disabled(running || finished)
            Well {
                VStack(spacing: 6) {
                    if finished {
                        let n = model.data.entries.filter { $0.source == .imported && LocalDate($0.start, calendar: .current) >= fromDay }.count
                        let secs = model.data.entries.filter { $0.source == .imported && LocalDate($0.start, calendar: .current) >= fromDay }.reduce(0) { $0 + $1.duration(now: model.now) }
                        row(String(localized: "Imported"), String(localized: "\(n) worklogs · \(DurationFormat.short(secs))"))
                        row(String(localized: "Jira projects in them"), "\(preview?.projects.count ?? 0)" + ((preview?.projects.isEmpty ?? true) ? "" : String(localized: " — you'll name them next")))
                    } else if let p = preview, p.tasks == 0 {
                        // Nothing there: an honest zero, and a longer window instead of a disabled "Import from 0 tasks".
                        row(String(localized: "No worklogs of yours since \(Fmt.dayMonthYear(fromDay))."), "0")
                        if canTryYear {
                            HStack { Text(String(localized: "Your history may start earlier — try a longer range")).font(.system(size: 12)).foregroundStyle(DS.C.text2); Spacer() }
                        }
                    } else if let p = preview {
                        let secs = Int((Double(p.tasks) * 0.5).rounded(.up))
                        row(String(localized: "Tasks with your worklogs"), "\(p.tasks)")
                        row(String(localized: "Jira projects in them"), "\(p.projects.count)" + (p.projects.isEmpty ? "" : String(localized: " — you'll name them next")))
                        row(String(localized: "Takes about"), secs < 60 ? String(localized: "\(max(10, secs)) seconds · you can keep working")
                                                                        : String(localized: "\(Int((Double(secs) / 60).rounded(.up))) min · you can keep working"))
                    } else {
                        HStack { ProgressView().controlSize(.small); Text(counting ? String(localized: "Looking at your Jira…") : "").font(DS.F.caption).foregroundStyle(DS.C.text3); Spacer() }
                    }
                }
            }
            if running, let p = model.refreshing {
                let ofTotal = String(localized: "of \(p.total) tasks")   // its own plural string ("of 1 task")
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))) {
                    Text(String(localized: "\(p.done) \(ofTotal) · you can keep working")).font(DS.F.caption)
                }
                .tint(DS.C.brand)
            }
            if let error { BannerView(kind: .danger, icon: "exclamationmark.triangle", text: error, action: String(localized: "Try again")) { run() } }
            Spacer(minLength: 0)
            // Footer (design y3Wup5): Back and Skip left, the import right; the hairline spans the window.
            HStack(spacing: 10) {
                backButton
                if finished {
                    Spacer()
                    Button { NotificationCenter.default.post(name: .onboardingNext, object: nil) } label: { HStack(spacing: 6) { Text(String(localized: "Continue")); Image(systemName: "arrow.right") } }
                        .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                } else if preview?.tasks == 0 && !running {
                    // Nothing found (U3adP): go on without history, or look further back.
                    if canTryYear {
                        Button(String(localized: "Continue without history")) { skip() }.buttonStyle(.pill)
                        Spacer()
                        Button { applyPreset(Self.thisYear) } label: { Label(String(localized: "Try this year"), systemImage: "calendar") }
                            .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                    } else {
                        Spacer()
                        Button { skip() } label: { HStack(spacing: 6) { Text(String(localized: "Continue without history")); Image(systemName: "arrow.right") } }
                            .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button(String(localized: "Skip")) { skip() }.buttonStyle(.pill).disabled(running)
                    Spacer()
                    Button(action: run) {
                        Label(running ? String(localized: "Importing…") : (preview.map { String(localized: "Import from \($0.tasks) tasks") } ?? String(localized: "Import")),
                              systemImage: "icloud.and.arrow.down")
                    }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction).disabled(running || preview == nil)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(DS.C.border).frame(height: 1) }
            .padding(.horizontal, -40)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { applyPreset(lastMonthOpen ? Self.lastMonth : Self.thisMonth) }
        .task(id: fromDay) { await count() }
    }

    private static var lastMonth: Int { 0 }
    private static var thisMonth: Int { 1 }
    private static var thisYear: Int { 2 }

    private var matchesPreset: Bool { preset.map { presetDate($0) == fromDay } ?? false }

    private func presetDate(_ i: Int) -> LocalDate {
        let t = model.today
        switch i {
        case Self.thisMonth: return t.firstOfMonth
        case Self.thisYear: return t.firstOfYear
        default: return t.firstOfMonth.adding(months: -1)
        }
    }

    private func skip() {
        NotificationCenter.default.post(name: .onboardingNext, object: nil)
    }

    /// Back to Work time (beta feedback row 2) — not while the import runs.
    private var backButton: some View {
        Button(String(localized: "Back")) { NotificationCenter.default.post(name: .onboardingBack, object: nil) }
            .buttonStyle(.pill).disabled(running)
            .accessibilityIdentifier("onboarding.back")
    }

    private func applyPreset(_ i: Int) {
        preset = i
        from = Fmt.date(presetDate(i))
    }

    private func chip(_ i: Int, _ title: String) -> some View {
        Button { applyPreset(i) } label: {
            Text(title).font(.system(size: 12, weight: preset == i ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(preset == i ? DS.C.brandText : DS.C.text)
                .capsuleSurface(preset == i ? DS.C.brandSoft : DS.C.surface, border: preset == i ? DS.C.brand : DS.C.border,
                                lineWidth: preset == i ? 1.5 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.chip)
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a).font(.system(size: 12)).foregroundStyle(DS.C.text2); Spacer(); Text(b).font(.system(size: 12, weight: .semibold)) }
    }

    private func count() async {
        guard let inst, !finished else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }
        counting = true
        preview = nil
        do {
            preview = try await model.engine.previewImport(instanceId: inst.id, from: fromDay)
            error = nil
            model.markAllReachable()
        } catch let e as JiraError {
            error = e.display
        } catch {}
        counting = false
    }

    private func run() {
        guard var inst else { return }
        inst.historyStartDate = fromDay
        inst.syncCursor = nil
        var c = Changes(); c.upsertInstances = [inst]; model.applySilently(c)
        running = true
        error = nil
        Task {
            do {
                model.refreshing = (0, max(1, preview?.tasks ?? 1))
                let r = try await model.engine.refresh(instanceId: inst.id) { p in
                    Task { @MainActor in if case .issues(let d, let tot) = p { model.refreshing = (d, tot) } }
                }
                model.pendingProjectSuggestions.merge(r.unmappedKeys.map { ($0.key, ($0.value, inst.id)) }) { a, _ in a }
                model.markAllReachable()
                finished = true
            } catch let e as JiraError {
                self.error = String(localized: "Import stopped — what came in is kept. \(e.display)")
            } catch {
                self.error = String(localized: "Import stopped — what came in is kept. \(error.localizedDescription)")
            }
            model.refreshing = nil
            running = false
        }
    }
}

/// Your projects (design xeJqx, c0J4w), shown only when the import found Jira projects: the shared proposal list —
/// colour picked, name editable, billable by a click, a checkbox to leave one out. Continue creates the ticked ones.
struct ProjectsStep<Head: View>: View {
    @Environment(AppModel.self) private var model
    let head: Head
    @State private var items: [(UUID, String)] = []
    @State private var choices = ProjectProposalChoices()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            head
            Text(String(localized: "Your projects")).font(DS.F.display(24, .heavy))
            Text(String(localized: "Found in your worklogs: \(items.count) Jira projects. Name them the way you know them — e.g. “Payments” instead of “ABC”. Colours are picked for you; change anything later in Projects."))
                .font(DS.F.body).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                ProjectProposalList(items: items, choices: $choices)
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(String(localized: "Back")) { NotificationCenter.default.post(name: .onboardingBack, object: nil) }.buttonStyle(.pill)
                    .accessibilityIdentifier("onboarding.back")
                Spacer()
                Button { create() } label: { HStack(spacing: 6) { Text(String(localized: "Continue")); Image(systemName: "arrow.right") } }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.next")
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(DS.C.border).frame(height: 1) }
            .padding(.horizontal, -40)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Back and forth keeps what you typed; rows a re-import added come in ticked.
            items = model.proposalItems()
            for (k, v) in ProjectProposalChoices(items: items, model: model).names where choices.names[k] == nil { choices.names[k] = v }
        }
    }

    private func create() {
        model.createProposedProjects(items, choices: choices)
        NotificationCenter.default.post(name: .onboardingNext, object: nil)
    }
}
