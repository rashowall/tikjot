import SwiftUI
import TikjotDomain

/// `toolbar/period` (decided 2026-10-02): ‹ › Title ⌄ (date picker) + fund line · Today · "N need you" chip ·
/// Worked · In Jira · Balance · + Add ▾ · Review & send.
struct PeriodToolbar<AddMenu: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String
    let todayTitle: String
    let range: DateRange
    let step: (Int) -> Void
    let goToday: () -> Void
    /// Days that need you in this period (blockers only, audit U1): "4 days need you" (design QllBZ).
    var needYou: Int = 0
    var needYouAction: () -> Void = {}
    var balanceLabel: String = String(localized: "balance")
    /// Month: how the balance comes about (tooltip + VoiceOver hint).
    var balanceHelp: TooltipContent?
    let addTitle: String
    let addAction: () -> Void
    @ViewBuilder let addMenu: AddMenu
    let review: () -> Void
    var compact = false
    @State private var picker = false

    var body: some View {
        let l = model.ledger
        let lastDay = min(range.end, model.today)
        let worked = lastDay >= range.start ? l.worked(DateRange(range.start, lastDay)) : 0
        let inJira = lastDay >= range.start ? l.inJira(DateRange(range.start, lastDay)) : 0
        let balance = range.count == 1 ? l.dayBalance(range.start) : l.liveBalance(range, since: model.dataStart)
        let locked = model.lock.isLocked(range.end, today: model.today)
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.icon)
                    .accessibilityLabel(String(localized: "Previous"))
                    .accessibilityIdentifier("period.prev")
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.icon)
                    .accessibilityLabel(String(localized: "Next"))
                    .accessibilityIdentifier("period.next")
            }
            .foregroundStyle(DS.C.text2)
            // macOS 26: ‹ › sit in one glass capsule (design "Liquid Glass" row); flat as before on 14–15.
            .padding(.horizontal, LiquidGlass.isAvailable ? 3 : 0).padding(.vertical, LiquidGlass.isAvailable ? 2 : 0)
            .modifier(GlassCapsuleIfAvailable())
            Button { picker.toggle() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        // Design: display 20/700, −0.3 tracking, never shortened; chevron 14 text-secondary.
                        Text(title).font(DS.F.screenTitle).tracking(-0.3).foregroundStyle(DS.C.text).lineLimit(1).fixedSize()
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.text2)
                    }
                    Text(subtitle).font(DS.F.caption).foregroundStyle(DS.C.text2).lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(.row)
            .accessibilityLabel(title)
            .accessibilityValue(subtitle)
            .accessibilityIdentifier("period.title")
            .onAppear { DebugUI.open("datePicker") { picker = true } }
            .surfacePopover(isPresented: $picker, arrowEdge: .bottom) {
                MiniMonthPicker(selected: range.start) { d in model.selectedDay = d; picker = false }
                    .environment(model).padding(12)
            }
            Button(todayTitle, action: goToday).buttonStyle(PillButtonStyle().glassy).accessibilityIdentifier("period.today")
            Spacer(minLength: 8)
            if locked {
                Chip(text: String(localized: "Locked"), icon: "lock.fill")
            } else if needYou > 0 && model.jiraConnected {
                Button(action: needYouAction) {
                    HStack(spacing: 6) {
                        NeedsYouDot(size: 7)
                        Text(NeedsYouText.days(needYou))
                            .font(.system(size: 12, weight: .semibold))
                    }
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(Capsule().fill(DS.C.warningSoft))
                        .foregroundStyle(DS.C.text)
                }
                .buttonStyle(.chip)
            }
            if !compact {
                // The numbers never wrap: in a narrow window they step aside (the title and actions stay).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        stat(DurationFormat.hm(worked), String(localized: "worked"))
                        if model.jiraConnected { stat(DurationFormat.hm(inJira), String(localized: "in Jira")) }
                        balanceStat(balance)
                    }
                    .fixedSize()
                    balanceStat(balance).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            if !locked {
                HStack(spacing: 0) {
                    Button(action: addAction) { Label(addTitle, systemImage: "plus").fixedSize().padding(.horizontal, 10).frame(height: DS.H.regular) }
                        .buttonStyle(.segment)
                        .accessibilityIdentifier("period.add")
                    Divider().frame(height: 18)
                    Menu { addMenu } label: { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
                        .accessibilityLabel(String(localized: "More to add"))
                        .accessibilityIdentifier("period.addMenu")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.C.text)
                .glassSurface(Capsule(), fill: DS.C.surface, border: DS.C.border, interactive: true)
                if model.jiraConnected {
                    // macOS 26: Review & send is the tinted glass capsule.
                    Button(action: review) { Label(String(localized: "Review & send"), systemImage: "paperplane").fixedSize() }
                        .buttonStyle(PillButtonStyle.primaryPill.glassy)
                        // Faded when the period has nothing to send (design: weekend, empty and holiday days).
                        .disabled(!model.unsentDays().contains { range.contains($0) })
                        .accessibilityIdentifier("period.review")
                } else {
                    Button(String(localized: "Connect Jira")) { AppDelegate.shared?.windows.showSettings(model, tab: .jira) }
                        .buttonStyle(.primaryPill)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private func balanceStat(_ balance: Seconds) -> some View {
        if let balanceHelp {
            stat(DurationFormat.signed(balance), balanceLabel)
                .chartTooltip("toolbar.balance", balanceHelp, accessible: false)
                .accessibilityElement(children: .combine)
                .accessibilityHint(balanceHelp.accessibilityText)
        } else {
            stat(DurationFormat.signed(balance), balanceLabel)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(DS.F.number(13)).foregroundStyle(DS.C.text).rolls(value)
            Text(label).font(.system(size: 10)).foregroundStyle(DS.C.text3).lineLimit(1).fixedSize()
        }
    }
}

/// Date picker (§7.3): Mon-first mini month with ISO weeks; only days that need you get an amber dot.
struct MiniMonthPicker: View {
    @Environment(AppModel.self) private var model
    @State var month: LocalDate
    let selected: LocalDate
    let pick: (LocalDate) -> Void
    @State private var hover: LocalDate?

    init(selected: LocalDate, pick: @escaping (LocalDate) -> Void) {
        _month = State(initialValue: selected.firstOfMonth)
        self.selected = selected
        self.pick = pick
    }

    /// Design W9Wl9: month title ‹ › Today, ISO weeks, amber needs-you dots, the legend with what a dot means,
    /// and a card for the hovered day (the picked day until you hover one).
    var body: some View {
        let first = month.firstOfMonth.startOfWeek
        let focus = hover ?? selected
        VStack(alignment: .leading, spacing: 8) {
            CalendarHead(month: $month) { pick(model.today) }
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("").frame(width: 28)
                    ForEach(0..<7) { i in
                        Text(Fmt.weekdayShort(first.adding(days: i)).prefix(2)).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.C.text3).frame(width: 36)
                    }
                }
                .padding(.bottom, 4)
                ForEach(0..<6) { w in
                    let wk = first.adding(days: w * 7)
                    if wk <= month.lastOfMonth {
                        GridRow {
                            Text("\(wk.weekNumber)").font(.system(size: 9, design: .monospaced)).foregroundStyle(DS.C.text3).frame(width: 28)
                            ForEach(0..<7) { i in dayCell(wk.adding(days: i), focused: focus) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(DS.C.warning).frame(width: 7, height: 7)
                    Text(String(localized: "needs you")).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.text)
                }
                Text(String(localized: "Only days that still need something get a dot: not sent, failed, or a workday with nothing tracked. Today gets one only when the day is over. Hover a day for details."))
                    .font(DS.F.caption).foregroundStyle(DS.C.text3).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8).padding(.horizontal, 4).padding(.bottom, 2)
            .overlay(alignment: .top) { Rectangle().fill(DS.C.border).frame(height: 1) }
            dayCard(focus)
        }
        .frame(width: 292)
    }

    private func dayCell(_ d: LocalDate, focused: LocalDate) -> some View {
        let inMonth = d.month == month.month
        return CalendarDayCell(day: d, month: month, outlined: d == focused, dot: inMonth && !model.needsYou(on: d).isEmpty, pick: pick)
            .onHover { if $0 && d >= month.firstOfMonth { hover = d } }
    }

    /// "Mon 28 Sep · nothing tracked" / "workday, expected 8h · add entries or an absence · editable until 5 Oct".
    private func dayCard(_ d: LocalDate) -> some View {
        let l = model.ledger
        let worked = l.worked(d)
        let need = model.needsYou(on: d)
        let type = model.dayCalendar.dayType(d)
        var parts: [String] = []
        let kind = model.dayCalendar.holidays[d]?.name
            ?? (type == .weekend ? String(localized: "weekend") : String(localized: "workday"))
        parts.append("\(kind), " + String(localized: "expected \(DurationFormat.short(l.fund(d)))"))
        if !need.emptyDays.isEmpty { parts.append(String(localized: "add entries or an absence")) }
        else if let n = NeedsYouText.items(need) { parts.append(n) }
        if model.lock.isLocked(d, today: model.today) { parts.append(String(localized: "locked")) }
        else if d < model.today.firstOfMonth { parts.append(String(localized: "editable until \(Fmt.dayMonth(model.lock.editableUntil(d)))")) }
        return HStack(spacing: 8) {
            Image(systemName: need.isEmpty ? "calendar" : "calendar.badge.exclamationmark").font(.system(size: 12)).foregroundStyle(DS.C.text2)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Fmt.short(d)) · \(worked > 0 ? DurationFormat.hm(worked) : String(localized: "nothing tracked"))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.text).lineLimit(1)
                Text(parts.joined(separator: " · ")).font(DS.F.caption).foregroundStyle(DS.C.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface2))
    }
}

/// Glass capsule behind a control group on macOS 26; nothing on 14–15.
struct GlassCapsuleIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !LiquidGlass.forceFlat {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
        }
    }
}
