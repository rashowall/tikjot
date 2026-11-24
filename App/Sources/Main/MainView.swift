import SwiftUI
import SyncEngine
import TikjotDomain
import TikjotPersistence

/// Main window: sidebar · content (· inspector in Day) (§11.3). Window sizes: ≥1180 full,
/// 900–1180 floating inspector, <900 icon sidebar (§11.4 "Window sizes").
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let compactSidebar = geo.size.width < 900
            HStack(spacing: 0) {
                if LiquidGlass.isAvailable {
                    // macOS 26 (design "Main · Day · Liquid Glass"): a floating glass sidebar over the window background.
                    Sidebar(compact: compactSidebar)
                        .glassSurface(RoundedRectangle(cornerRadius: DS.R.window, style: .continuous), fill: DS.C.surface2,
                                      tint: DS.C.surface2.opacity(0.45))
                        .padding(.leading, 8).padding(.vertical, 8).padding(.trailing, 2)
                        .frame(width: compactSidebar ? 64 : 230)
                } else {
                    Sidebar(compact: compactSidebar)
                        .frame(width: compactSidebar ? 64 : 230)
                    Divider().opacity(0.5)
                }
                VStack(spacing: 0) {
                    MainBanners()
                    content(width: geo.size.width - (compactSidebar ? 64 : 230))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("screen.\(model.mainSelection.rawValue)")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.C.bg)
            }
        }
        // Chart and balance hover cards draw above everything in the window (sidebar and screens).
        .tooltipHost()
        .background(LiquidGlass.isAvailable ? DS.C.bg : DS.C.surface2)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 24) }
        .surfaceSheet(item: $model.reviewRequest) { req in
            ReviewSheet(request: req).environment(model)
        }
        // ⌘K and ⌘1–6 live in the View menu, Keyboard Shortcuts in Help (TikjotApp, audit U9).
        .surfaceSheet(isPresented: $model.showCommandBar) { CommandBar().environment(model) }
        .surfaceSheet(isPresented: $model.showShortcuts) { ShortcutsSheet() }
        .onAppear {
            KeyCommands.shared.install(model: model) { model.showShortcuts = true }
            DebugUI.open("commandBar") { model.showCommandBar = true }
            DebugUI.open("shortcuts") { model.showShortcuts = true }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch model.mainSelection {
        case .day: DayScreen(availableWidth: width)
        case .week: WeekScreen()
        case .month: MonthScreen()
        case .unsent: UnsentScreen()
        case .statistics: StatisticsScreen()
        case .projects: ProjectsScreen()
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 44) // traffic lights
            ForEach(MainSection.allCases) { s in
                SidebarItem(section: s, compact: compact)
            }
            Spacer()
            if compact {
                if let r = model.runningEntry {
                    CompactRunning(entry: r)
                } else {
                    CompactStart()
                }
            } else {
                SidebarSummary()
            }
        }
        .padding(.horizontal, LiquidGlass.isAvailable ? (compact ? 3 : 6) : (compact ? 8 : 10)) // the glass panel adds its own inset
        .padding(.bottom, 10)
    }
}

extension MainSection {
    var title: String {
        switch self {
        case .day: return String(localized: "Day")
        case .week: return String(localized: "Week")
        case .month: return String(localized: "Month")
        case .unsent: return String(localized: "Unsent")
        case .statistics: return String(localized: "Statistics")
        case .projects: return String(localized: "Projects")
        }
    }

    var icon: String {
        switch self {
        case .day: return "sun.max"
        case .week: return "calendar"
        case .month: return "calendar.day.timeline.left"
        case .unsent: return "paperplane"
        case .statistics: return "chart.bar.xaxis"
        case .projects: return "folder"
        }
    }
}

struct SidebarItem: View {
    @Environment(AppModel.self) private var model
    let section: MainSection
    var compact: Bool
    @State private var hover = false

    var body: some View {
        let active = model.mainSelection == section
        Button { model.mainSelection = section } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(active ? DS.C.brand : DS.C.brandSoft)
                    Image(systemName: section.icon).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? DS.C.onBrand : DS.C.brand)
                }
                .frame(width: 22, height: 22)
                if !compact {
                    Text(section.title).font(DS.F.bodyMedium).foregroundStyle(active ? DS.C.brandText : DS.C.text)
                    Spacer()
                    // Days not in Jira, a solid brand pill when something needs you — hidden at 0 (variant V1, 2026-10-06).
                    if section == .unsent, model.jiraConnected {
                        UnsentCountBadge(badge: model.unsentBadge, calmFill: DS.C.surface)
                    }
                }
            }
            .padding(.horizontal, compact ? 9 : 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(active ? DS.C.brandSoft : (hover ? DS.C.surface2 : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
        .onHover { hover = $0 }
        .help(compact ? section.title : "")
        .accessibilityLabel(section.title)
        .accessibilityIdentifier("sidebar.\(section.rawValue)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Bottom of the sidebar (decided 2026-10-02; Utilization moved to Statistics 2026-10-06): Running · Today · Balance · Not in Jira.
struct SidebarSummary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let l = model.ledger
            let t = model.today
            let worked = l.worked(t), fund = l.fund(t), inJira = l.inJira(t)
            let month = DateRange.month(of: t)
            let bal = l.liveBalance(month, since: model.dataStart)
            let notInJira = max(0, l.worked(DateRange(month.start, t)) - l.inJira(DateRange(month.start, t)))
            VStack(alignment: .leading, spacing: 10) {
                if let r = model.runningEntry {
                    // Storyboard A · 5 / B · 4: the running row slides in (8 px, fade) and collapses on stop.
                    MiniCapsule(entry: r).transition(.slideFade(reduceMotion))
                } else {
                    if let a = model.absences(on: t).first(where: { $0.unit == .hours && isNow($0) }), let ty = model.absenceType(a.typeId) {
                        HStack {
                            Image(systemName: ty.icon).foregroundStyle(DS.C.brandText)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(localized: "Away now")).font(DS.F.captionMedium)
                                Text(ty.name).font(DS.F.caption).foregroundStyle(DS.C.text3)
                            }
                        }
                    }
                    MiniStart().transition(.slideFade(reduceMotion))
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(String(localized: "Today")).font(.system(size: 12)).foregroundStyle(DS.C.text2)
                        Spacer()
                        if worked > fund && fund > 0 {
                            Text(DurationFormat.overClock(worked - fund)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.successText)
                        }
                        let today = "\(DurationFormat.hm(worked)) / \(DurationFormat.short(fund))"
                        Text(today).font(.system(size: 12, weight: .semibold, design: .monospaced)).rolls(today)
                    }
                    GeometryReader { g in
                        let w = g.size.width
                        let f = max(fund, 1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.C.surface2)
                            Capsule().fill(DS.C.brand.opacity(0.45)).frame(width: w * min(1, CGFloat(worked) / CGFloat(f)))
                            Capsule().fill(DS.C.brand).frame(width: w * min(1, CGFloat(inJira) / CGFloat(f)))
                            if worked > fund && fund > 0 {
                                Capsule().fill(DS.C.ringOvertime).frame(width: w * min(1, CGFloat(worked - fund) / CGFloat(f))).offset(x: w - w * min(1, CGFloat(worked - fund) / CGFloat(f)))
                            }
                        }
                    }
                    .frame(height: 4)
                }
                let balanceHelp = model.monthBalanceHelp(month)
                row(String(localized: "Balance · \(Fmt.monthName(t))"), DurationFormat.signed(bal), bal < 0 ? DS.C.warningText : DS.C.successText, chip: true)
                    .chartTooltip("sidebar.balance", balanceHelp, accessible: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(balanceHelp.accessibilityText)
                if model.jiraConnected {
                    row(String(localized: "Not in Jira · \(Fmt.monthName(t))"), DurationFormat.hm(notInJira), notInJira > 0 ? DS.C.warningText : DS.C.text2)
                }
                // Utilization lives in Statistics only (simplicity pass 2026-10-06).
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
            .animation(Motion.pick(reduceMotion, Motion.spring), value: model.runningEntry?.id)
        }
    }

    private func isNow(_ a: Absence) -> Bool {
        guard let sm = a.startMinutes else { return false }
        let s = a.date.at(minutes: sm, in: .current)
        return model.now >= s && model.now < s.addingTimeInterval(TimeInterval(a.amountSeconds))
    }

    // Design `sidebar/summary` (svSP3): labels 12 text-secondary, values mono 12/600; the balance is `balance/pill`.
    private func row(_ label: String, _ value: String, _ color: Color, chip: Bool = false) -> some View {
        HStack {
            // "Balance · October" → "Balance" when the pill needs the room.
            ViewThatFits(in: .horizontal) {
                Text(label).fixedSize()
                Text(label.components(separatedBy: " · ").first ?? label).lineLimit(1)
            }
            .font(.system(size: 12)).foregroundStyle(DS.C.text2)
            Spacer(minLength: 4)
            if chip {
                BalancePill(text: value, negative: value.hasPrefix("−") || value.hasPrefix("-"))
            } else {
                Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(color).rolls(value)
            }
        }
    }
}

/// `capsule/mini`: description + task left, coral pill time | stop right. Clicking the time selects the running block.
struct MiniCapsule: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    @State private var anchor = PopoverAnchor.Box()

    var body: some View {
        HStack(spacing: 4) {
            Button {
                // Edit or switch right here — the same timer as in the menu bar.
                MenuBarController.shared?.showPopover(from: anchor.view)
                model.popoverEditing = .picker(.timer)
            } label: {
                // Design `capsule/mini` (O1rRV): description 12/700, task line key mono 10/700 + name 10.
                VStack(alignment: .leading, spacing: 1) {
                    DescriptionLabel(text: entry.description.isEmpty ? model.taskLabel(for: entry) : entry.description, font: .system(size: 12, weight: .bold))
                    if let i = model.issue(for: entry) {
                        HStack(spacing: 4) {
                            Circle().fill(DS.project(model.project(entry.projectId)?.color ?? "slate")).frame(width: 6, height: 6)
                            KeyName(key: i.key, name: i.summary,
                                    nameFont: .system(size: 10), nameColor: DS.C.text2, spacing: 4, minName: 24, stacked: false)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.row)
            .help(String(localized: "Switch task or edit"))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                TimePill(elapsed: Int(Clock.now.timeIntervalSince(entry.start)), showSeconds: false, compact: true,
                         timeAction: {
                             model.selectedDay = model.today
                             model.mainSelection = .day
                             model.selectedEntryIds = [entry.id]
                         }, stop: { model.stop() })
            }
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 5)
        .frame(height: 42)
        .background(Capsule().fill(DS.C.tickSoft))
        .background(PopoverAnchor(box: anchor))
    }
}

/// Idle twin of `MiniCapsule`: starts a timer from the main window (the same popover, attached to the sidebar) —
/// tracking never depends on the menu-bar icon being visible.
struct MiniStart: View {
    @Environment(AppModel.self) private var model
    @State private var anchor = PopoverAnchor.Box()
    @State private var hover = false

    var body: some View {
        Button {
            MenuBarController.shared?.showPopover(from: anchor.view)
            model.focusTimerDescription()   // the description field with your recent work
        } label: {
            HStack(spacing: 6) {
                Text(String(localized: "Start a timer")).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.text2)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Kbd(text: model.settings.hotkeyOpen).opacity(hover ? 1 : 0.8)
                Image(systemName: "play").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.onBrand)
                    .frame(width: 26, height: 26).background(Circle().fill(DS.C.brand))
            }
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
            .capsuleSurface(DS.C.surface2, border: hover ? DS.C.borderStrong : DS.C.border)
            .contentShape(Capsule())
        }
        .buttonStyle(.rowPress)
        .onHover { hover = $0 }
        .background(PopoverAnchor(box: anchor))
        .accessibilityLabel(String(localized: "Start a timer"))
        .accessibilityIdentifier("sidebar.start")
    }
}

/// Collapsed sidebar, idle: a round play button.
struct CompactStart: View {
    @Environment(AppModel.self) private var model
    @State private var anchor = PopoverAnchor.Box()

    var body: some View {
        Button {
            MenuBarController.shared?.showPopover(from: anchor.view)
            model.focusTimerDescription()
        } label: {
            Image(systemName: "play").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.C.onBrand)
                .frame(width: 34, height: 34).background(Circle().fill(DS.C.brand))
                .frame(width: 48)
        }
        .buttonStyle(.dot)
        .background(PopoverAnchor(box: anchor))
        .help(String(localized: "Start a timer"))
        .accessibilityLabel(String(localized: "Start a timer"))
    }
}

/// Gives SwiftUI controls an AppKit view for the timer popover to hang from.
struct PopoverAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box
    func makeNSView(context: Context) -> NSView { let v = NSView(); box.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

/// Collapsed sidebar: vertical coral pill (time over the stop zone).
struct CompactRunning: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 6) {
                Text(DurationFormat.clock(Int(Clock.now.timeIntervalSince(entry.start)))).font(DS.F.monoMedium).foregroundStyle(DS.C.onTickStrong)
                Button { model.stop() } label: {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(DS.C.onTickStrong, lineWidth: 1.5).frame(width: 10, height: 10)
                        .frame(width: 26, height: 26).background(Circle().fill(DS.C.onTickStrong.opacity(0.14)))
                }
                .buttonStyle(.dot)
            }
            .padding(.vertical, 10).frame(width: 48)
            .background(Capsule().fill(DS.C.tickStrong))
        }
    }
}

// MARK: Banners (one at a time: conflicts › signed out › menu bar hidden › offline › time-zone mismatch)

struct MainBanners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Once after onboarding: the menu bar tracks, this window fixes and sends.
        TwoPlacesCard()
        // The away question waits here too until answered (audit U3) — the same card as in the popover.
        if let away = model.awayCard, model.mainSelection == .day {
            AwayCard(prompt: away.prompt, owner: away.owner).frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 8)
        }
        Group {
            if model.conflictCount > 0 {
                BannerView(kind: .danger, icon: "arrow.left.arrow.right",
                           text: String(localized: "\(model.conflictCount) worklogs changed in Jira and here. Nothing is sent until you choose."),
                           action: String(localized: "Show")) { model.mainSelection = .unsent; model.unsentFilterNeedsYou = true }
            } else if let inst = model.signedOutInstances.first {
                BannerView(kind: .warning, icon: "key", text: String(localized: "Jira signed you out (\(inst.name)) — your token may have expired. Tracking and editing still work; sending waits."),
                           action: String(localized: "Renew token")) { model.requestTokenRenewal(inst.id) }
            } else if model.menuBarHidden && !model.dismissedMenuBarHint {
                BannerView(kind: .info, icon: "menubar.rectangle",
                           text: String(localized: "Your menu bar is full, so macOS hides tikjot's icon. Start timers here or with \(model.settings.hotkeyOpen) — or move tikjot to the right end of the menu bar."),
                           action: String(localized: "Move to the right")) { MenuBarController.shared?.moveToRightEnd() }
            } else if model.offline {
                // A company sign-in page instead of data usually means this Mac reaches Jira outside the VPN (e.g. a
                // stale DNS answer after the VPN dropped) — reconnecting the VPN fixes it; tikjot can't from the sandbox.
                if case .signInPage = model.lastRefreshError {
                    BannerView(kind: .calm, icon: "lock.shield",
                               text: String(localized: "Jira answered with your company's sign-in page — this Mac reaches it outside the VPN. Turn the VPN off and on again. Everything works here; sending resumes by itself."),
                               action: String(localized: "Try again")) { Task { await model.refreshAll() } }
                } else {
                    BannerView(kind: .calm, icon: "wifi.slash",
                               text: String(localized: "Jira can't be reached — check your connection or VPN. Everything works here; sending resumes by itself."),
                               action: String(localized: "Try again")) { Task { await model.refreshAll() } }
                }
            } else if let tz = model.timeZoneMismatch {
                BannerView(kind: .info, icon: "globe", text: String(localized: "Your Jira profile uses \(tz). Days follow this Mac (\(TimeZone.current.identifier))."),
                           action: String(localized: "OK")) { model.dismissedTimeZoneWarning = true }
            } else if !model.jiraConnected && model.mainSelection == .day {
                BannerView(kind: .calm, icon: "link", text: String(localized: "Without Jira your time is safe here. Connect Jira when you're ready to send."),
                           action: String(localized: "Connect Jira")) { AppDelegate.shared?.windows.showSettings(model, tab: .jira) }
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
        if let p = model.refreshing, p.total > 1 {
            HStack(spacing: 8) {
                ProgressView(value: Double(p.done), total: Double(p.total)).progressViewStyle(.linear).tint(DS.C.brand).frame(maxWidth: 220)
                Text(String(localized: "Updating from Jira · \(p.done) of \(p.total)")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 6)
        }
    }
}

extension AppModel {
    var conflictCount: Int { data.groups.filter { $0.syncState == .conflict && !lock.isLocked($0.localDate, today: today) }.count }

    var timeZoneMismatch: String? {
        guard !dismissedTimeZoneWarning, let tz = activeInstances.compactMap(\.jiraTimeZone).first,
              let jt = TimeZone(identifier: tz), jt.secondsFromGMT() != TimeZone.current.secondsFromGMT() else { return nil }
        return tz
    }
}
