import SwiftUI
import TikjotDomain
import TikjotPersistence

/// The menu-bar popover (R4): header · capsule · day cards · bottom line (§11.1, §11.8 "Popover anatomy").
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @State private var scrolled = false
    /// Height cap (beta 2026-10-08, row 11): the popover grows with its content up to ¾ of the screen.
    @State private var maxHeight = PopoverHeight.base

    private var editing: PopoverEditing? { model.popoverEditing }

    var body: some View {
        VStack(spacing: 0) {
            if scrolled && editing == nil {
                CompactHeader().padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            } else {
                PopoverHeader()
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                    .faded(editing != nil)
            }
            PopoverBanners().padding(.horizontal, 12)
            if let away = model.awayCard {
                AwayCard(prompt: away.prompt, owner: away.owner).padding(.horizontal, 12).padding(.bottom, 8)
            }
            // Never squeezed: a multi-line description stays whole while the task step is open — the day list,
            // which scrolls, gives up the room (owner 2026-10-22: only two of four lines showed).
            CapsuleArea().padding(.horizontal, 12).fixedSize(horizontal: false, vertical: true)
            if editing == .absence {
                AbsenceForm(compact: true) { model.popoverEditing = nil }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                    .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.brand, lineWidth: 1.5))
                    .padding(12)
            } else {
                if !model.mondayHoles.isEmpty && editing == nil {
                    MondayCheckCard().padding(.horizontal, 12).padding(.top, 8)
                }
                // Built anew each time the popover opens, at today: a list reused across opens could stay drawn
                // scrolled under the capsule while it took itself for the top, until a restart (beta 2026-10-21).
                DayList(scrolled: $scrolled).id(model.popoverOpenedAt)
            }
            PopoverBottom()
                .padding(.horizontal, 16).padding(.vertical, 10)
                .faded(editing != nil && editing != .menu)
        }
        .frame(width: 420)
        .frame(maxHeight: maxHeight)
        .environment(\.popoverMaxHeight, maxHeight)
        // Re-measured each time the popover opens (the menu bar may be on another screen by then).
        .onAppear { maxHeight = PopoverHeight.cap() }
        .onChange(of: model.popoverOpenedAt) { _, _ in maxHeight = PopoverHeight.cap(); scrolled = false }
        .tooltipHost()   // the balance's hover card
        // The gear menu shows ⌘, / ⌘Q and the window icon ⌘O, but menu-item shortcuts only fire while that menu
        // is open — these make them work whenever the popover is.
        .background {
            Group {
                Button("") { MenuBarController.shared?.closePopover(); AppDelegate.shared?.windows.showMain(model) }.keyboardShortcut("o")
                Button("") { MenuBarController.shared?.closePopover(); AppDelegate.shared?.windows.showSettings(model) }.keyboardShortcut(",")
                Button("") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        // macOS 26 (design "Popover · Liquid Glass"): the popover's own glass shows through a 70 % background;
        // cards, capsule and header keep their solid surfaces, so text contrast is unchanged.
        .background(LiquidGlass.isAvailable ? DS.C.bg.opacity(0.7) : DS.C.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popover")
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 52) }
        .onKeyPress(.escape) {
            if model.popoverEditing != nil { model.popoverEditing = nil; return .handled }
            return .ignored
        }
    }
}

// MARK: Height

/// The popover's height cap: ¾ of the visible height of the screen with the menu-bar icon, never below the old
/// 640 (width stays 420; no setting — owner 2026-10-08). Outside the running app (snapshots) it stays 640.
enum PopoverHeight {
    static let base: CGFloat = 640
    /// Header, capsule and bottom line — what the day list leaves room for (640 − 460 before).
    static let chrome: CGFloat = 180

    @MainActor
    static func cap() -> CGFloat {
        guard let mbc = MenuBarController.shared,
              let screen = mbc.item.button?.window?.screen ?? NSScreen.main else { return base }
        return max(base, (screen.visibleFrame.height * 0.75).rounded())
    }
}

private struct PopoverMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = PopoverHeight.base
}

extension EnvironmentValues {
    var popoverMaxHeight: CGFloat {
        get { self[PopoverMaxHeightKey.self] }
        set { self[PopoverMaxHeightKey.self] = newValue }
    }
}

// MARK: Header

/// The moment of the day decides the illustration and greeting (§11.1 "Header illustration by moment").
struct Moment {
    var illustration: String
    var title: String
    var subtitle: String
    var tint: Color?

    @MainActor
    static func current(_ m: AppModel) -> Moment {
        let today = m.today
        let l = m.ledger
        let worked = l.worked(today)
        let fund = l.fund(today)
        let cal = m.dayCalendar
        let weekday = Fmt.weekday(today)
        let entries = l.workEntries(on: today)
        let status = l.dayStatus(today, lock: m.lock, jiraConnected: m.jiraConnected)
        let period = m.schedule.period(on: today)
        let minutes = Calendar.current.component(.hour, from: m.now) * 60 + Calendar.current.component(.minute, from: m.now)

        if worked > 0, status == .allInJira, m.runningEntry == nil, m.jiraConnected {
            let n = l.lines(on: today).filter { !$0.isNoIssue }.count
            return Moment(illustration: "illSentSmall", title: String(localized: "\(weekday) is in Jira"),
                          subtitle: DurationFormat.hm(worked) + " · " + String(localized: "\(n) worklogs") + " · " + String(localized: "see you tomorrow"), tint: DS.C.successSoft)
        }
        if let h = cal.holidays[today] {
            return Moment(illustration: "illHolidaySmall", title: h.name, subtitle: String(localized: "Public holiday · nothing expected today"))
        }
        let abs = m.absences(on: today)
        if let a = abs.first(where: { $0.unit == .day }), let t = m.absenceType(a.typeId) {
            let ill: String
            switch t.builtin {
            case .sickLeave: ill = "illSickDaySmall"
            case .childCare: ill = "illChildCareSmall"
            default: ill = "illVacationSmall"
            }
            return Moment(illustration: ill, title: t.name, subtitle: String(localized: "\(weekday) · whole day off"))
        }
        if let a = abs.first(where: { $0.unit == .hours && $0.startMinutes != nil }), let sm = a.startMinutes {
            let start = today.at(minutes: sm, in: m.timeCalendar)
            let end = start.addingTimeInterval(TimeInterval(a.amountSeconds))
            if m.now >= start && m.now < end && m.runningEntry == nil {
                return Moment(illustration: "illDoctorSmall", title: String(localized: "At the doctor"),
                              subtitle: String(localized: "\(Fmt.time(start))–now · back at \(Fmt.time(end))"))
            }
        }
        if cal.dayType(today) == .weekend && entries.isEmpty {
            return Moment(illustration: "illWeekendSmall", title: weekday, subtitle: String(localized: "Day off · any time counts as overtime"))
        }
        if entries.isEmpty {
            return Moment(illustration: "illMorningSmall", title: String(localized: "Good morning"),
                          subtitle: String(localized: "\(weekday) · expected \(DurationFormat.short(fund)) · nothing yet"))
        }
        if worked > fund && fund > 0 && m.runningEntry == nil || minutes >= period.workdayEnd {
            // Only what blocks sending, with its unit (audit U1).
            let need = NeedsYouText.items(m.needsYou(on: today))
            let sub = String(localized: "\(DurationFormat.hm(worked)) of \(DurationFormat.short(fund))") + (need.map { " · " + $0 } ?? "")
            if worked > fund + 3600 {
                return Moment(illustration: "illEveningSmall", title: String(localized: "Long day"),
                              subtitle: String(localized: "\(DurationFormat.hm(worked)) of \(DurationFormat.short(fund)) · +\(DurationFormat.hm(worked - fund)) overtime"))
            }
            return Moment(illustration: "illEveningSmall", title: String(localized: "Nearly done"), subtitle: sub)
        }
        if m.runningEntry == nil, let last = entries.last?.end {
            let gap = m.now.timeIntervalSince(last)
            if gap > 20 * 60 && gap < 120 * 60 && minutes >= 11 * 60 && minutes <= 15 * 60 {
                return Moment(illustration: "illBreakSmall", title: String(localized: "Back from lunch"),
                              subtitle: String(localized: "\(DurationFormat.hm(worked)) of \(DurationFormat.short(fund))"))
            }
        }
        let expected = l.liveFund(today)
        let onTrack = worked >= expected - 15 * 60 ? String(localized: "on track") : String(localized: "\(DurationFormat.short(expected - worked)) behind")
        return Moment(illustration: "illWorkingSmall", title: weekday,
                      subtitle: String(localized: "\(DurationFormat.hm(worked)) of \(DurationFormat.short(fund)) · \(onTrack)"))
    }
}

struct PopoverHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let moment = Moment.current(model)
            let l = model.ledger
            let today = model.today
            // Design `popover/header` (rj0WN): 84 × 63 art, gap 10, padding 6/8/2/4, title display 17/800.
            HStack(spacing: 10) {
                Illustration(name: moment.illustration, width: 84, loops: 1).frame(width: 84, height: 63)
                VStack(alignment: .leading, spacing: 2) {
                    Text(moment.title).font(DS.F.header).foregroundStyle(DS.C.text).lineLimit(1)
                    Text(moment.subtitle).font(DS.F.caption).foregroundStyle(DS.C.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                DayRing(worked: l.worked(today), fund: l.fund(today),
                        allInJira: moment.tint != nil, dayOff: l.fund(today) == 0, size: 52, lineWidth: 4.7)
            }
            .padding(.top, 6).padding(.trailing, 8).padding(.bottom, 2).padding(.leading, 4)
            .padding(moment.tint == nil ? 0 : 6)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(moment.tint ?? .clear))
        }
    }
}

/// Slim header after scrolling (R4 #10): small ring + today's total.
struct CompactHeader: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let l = model.ledger
        let t = model.today
        HStack(spacing: 8) {
            DayRing(worked: l.worked(t), fund: l.fund(t), size: 18, lineWidth: 2.5, showLabel: false)
            Text("\(Fmt.weekday(t)) · \(DurationFormat.hm(l.worked(t))) of \(DurationFormat.short(l.fund(t)))")
                .font(DS.F.bodySemibold)
            Spacer()
            Text(DurationFormat.signed(l.dayBalance(t))).font(DS.F.mono).foregroundStyle(DS.C.text3)
        }
    }
}

// MARK: Banners — the popover shows only "signed out" (the away card sits below); offline, in-app reminders and
// refresh progress live in the main window / notifications (simplicity pass 2026-10-06).

struct PopoverBanners: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let inst = model.signedOutInstances.first {
            // Usually an expired API token — Jira's 401 is how tikjot finds out (no expiry dates kept).
            BannerView(kind: .warning, icon: "key", text: String(localized: "Jira signed you out (\(inst.name)) — your token may have expired. Tracking still works."),
                       action: String(localized: "Renew token")) {
                MenuBarController.shared?.closePopover()
                model.requestTokenRenewal(inst.id)
            }
            .padding(.bottom, 8)
        }
    }
}

struct BannerView: View {
    enum Kind { case calm, warning, danger, info }
    let kind: Kind
    let icon: String
    let text: String
    var action: String?
    var perform: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(iconColor)
            Text(text).font(DS.F.caption).foregroundStyle(DS.C.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(action, action: perform).buttonStyle(.pill(.secondary, height: DS.H.small))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(fill))
    }

    private var fill: Color {
        switch kind {
        case .calm: return DS.C.surface2
        case .warning: return DS.C.warningSoft
        case .danger: return DS.C.dangerSoft
        case .info: return DS.C.brandSoft
        }
    }

    private var iconColor: Color {
        switch kind {
        case .calm: return DS.C.text2
        case .warning: return DS.C.warning
        case .danger: return DS.C.danger
        case .info: return DS.C.brand
        }
    }
}

// MARK: Bottom line

struct PopoverBottom: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let l = model.ledger
        let bal = l.liveBalance(DateRange.month(of: model.today), since: model.dataStart)
        // Design `popover/bottom` (S4BPjj) as footer C (beta 2026-10-08, row 9): gear menu + window icon left, the
        // balance, then Review & send alone on the right edge — nothing important behind a ••• any more.
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Menu {
                    Button(String(localized: "Settings…")) {
                        MenuBarController.shared?.closePopover()
                        AppDelegate.shared?.windows.showSettings(model)
                    }.keyboardShortcut(",")
                    Button(String(localized: "Add absence…")) { model.popoverEditing = .absence }
                    Divider()
                    Button(String(localized: "Quit tikjot")) { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.C.text3)
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Settings, absence, quit"))
                .accessibilityLabel(String(localized: "Settings"))
                Button {
                    MenuBarController.shared?.closePopover()
                    AppDelegate.shared?.windows.showMain(model)
                } label: {
                    Image(systemName: "macwindow").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.C.text3)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.icon)
                .help(String(localized: "Open tikjot (⌘O)"))
                .accessibilityLabel(String(localized: "Open tikjot"))
            }
            // Hover: how the balance comes about (expected, worked as in Jira, running balance).
            let help = model.monthBalanceHelp(DateRange.month(of: model.today))
            HStack(spacing: 10) {
                Text(String(localized: "Balance · \(Fmt.monthName(model.today))")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                let balText = DurationFormat.signed(bal)
                Text(balText).font(.system(size: 11, design: .monospaced)).foregroundStyle(bal < 0 ? DS.C.warningText : DS.C.successText)
                    .rolls(balText).signFlip(bal < 0)
            }
            .chartTooltip("popover.balance", help, accessible: false)
            .accessibilityElement(children: .combine)
            .accessibilityHint(help.accessibilityText)
            Spacer(minLength: 4)
            if model.jiraConnected {
                let badge = model.unsentBadge
                if !model.unsentDays().isEmpty || !badge.isHidden {
                    // No count in the button (owner, 2026-10-06: keep the popover simple) — the day cards already say
                    // what needs you; the count lives in the main window's sidebar.
                    Button { model.openReviewFromPopover() } label: {
                        Label(String(localized: "Review & send"), systemImage: "paperplane").font(.system(size: 12, weight: .bold))
                            .fixedSize()
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 30).glassy)
                    .help(badge.isHidden ? "" : UnsentCountBadge.text(badge))
                    .accessibilityValue(badge.isHidden ? "" : UnsentCountBadge.text(badge))
                }
            } else {
                Button(String(localized: "Connect Jira")) {
                    MenuBarController.shared?.closePopover()
                    AppDelegate.shared?.windows.showSettings(model, tab: .jira)
                }
                .buttonStyle(.pill)
            }
        }
    }
}

// MARK: Toast

struct ToastView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let t = model.toast {
            HStack(spacing: 10) {
                Text(t.text).font(DS.F.bodyMedium).foregroundStyle(DS.C.surface).lineLimit(2)
                if let p = t.progress { Text(p).font(DS.F.mono).foregroundStyle(DS.C.inverseSecondary) }
                if t.undoable {
                    Button(String(localized: "Undo")) { model.undo(); model.toast = nil }
                        .buttonStyle(LinkButtonStyle(color: DS.C.brandInverse)).font(DS.F.bodySemibold)
                }
                if let title = t.actionTitle, let a = t.action {
                    Button(title) { a(); model.toast = nil }.buttonStyle(LinkButtonStyle(color: DS.C.brandInverse)).font(DS.F.bodySemibold)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.text.opacity(0.96)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
}

// MARK: Away while the timer ran (§7.2, §11.9)

struct AwayCard: View {
    @Environment(AppModel.self) private var model
    let prompt: AwayPrompt
    let owner: AwayOwner
    @State private var picking = false

    // Audit U3: the usual answer first — stop when you left (no restart); keep it, or give the time to another task.
    // Beta 2026-10-18: after a switch the card names the entry it's about and acts on it, not on the new timer;
    // × = keep it.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(DS.F.bodySemibold).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.keepAway() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(DS.C.text2)
                    .help(String(localized: "Keep it as it is"))
                    .accessibilityLabel(String(localized: "Close"))
                    .accessibilityIdentifier("away.close")
            }
            Text(detail).font(DS.F.caption).foregroundStyle(DS.C.text2)
            if picking {
                TaskPicker(allowNoTask: true) { i, p in model.giveAway(to: i, projectId: p) } onCancel: { picking = false }
            } else {
                HStack {
                    Button(finished == nil ? String(localized: "Keep running") : String(localized: "Keep it")) { model.keepAway() }.buttonStyle(.pill)
                    Button(String(localized: "Give it to…")) { picking = true }.buttonStyle(.pill)
                    Spacer(minLength: 0)
                    if finished == nil {
                        Button(String(localized: "Stop at \(Fmt.time(prompt.from))")) { model.stopAtAway() }.buttonStyle(.primaryPill)
                            .help(String(localized: "Ends the timer when you left; nothing restarts"))
                    } else {
                        Button(String(localized: "Remove \(DurationFormat.hm(prompt.seconds))")) { model.stopAtAway() }.buttonStyle(.primaryPill)
                            .help(String(localized: "Takes the time away out of that entry; the running timer isn't touched"))
                            .accessibilityIdentifier("away.remove")
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.warningSoft))
    }

    private var finished: TimeEntry? {
        if case .finished(let e) = owner { return e }
        return nil
    }

    private var title: String {
        let time = DurationFormat.hm(prompt.seconds)
        if let e = finished {
            return prompt.slept ? String(localized: "Your Mac slept \(time) during \(model.awayTaskName(e))")
                                : String(localized: "You were away \(time) from \(model.awayTaskName(e))")
        }
        return prompt.slept ? String(localized: "Your Mac slept \(time)") : String(localized: "You were away \(time)")
    }

    private var detail: String {
        let range = Fmt.range(prompt.from, prompt.to)
        if let e = finished {
            let what = e.description.isEmpty ? model.taskLabel(for: e) : e.description
            return String(localized: "\(range) · counted on “\(what)”.")
        }
        return String(localized: "\(range) while the timer ran.")
    }
}

// MARK: Monday check (§11.11)

struct MondayCheckCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(DS.C.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Last week has a hole")).font(DS.F.bodySemibold)
                    Text(model.mondayHoles.map { Fmt.short($0) }.joined(separator: ", ") + " · " + String(localized: "nothing tracked"))
                        .font(DS.F.caption).foregroundStyle(DS.C.text2)
                }
                Spacer()
                Button { model.mondayHoles = [] } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.C.text3).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.icon)
                .help(String(localized: "Dismiss"))
                .accessibilityLabel(String(localized: "Dismiss"))
            }
            // Audit U9: both fixes visible, not behind a menu.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(String(localized: "Open day")) { if let d = model.mondayHoles.first { model.openDay(d) } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                Button(String(localized: "Add absence…")) { model.absenceDraftDays = model.mondayHoles; model.popoverEditing = .absence }
                    .buttonStyle(.pill(.primary, height: DS.H.small))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.warningSoft))
    }
}
