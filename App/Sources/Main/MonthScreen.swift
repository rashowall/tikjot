import SwiftUI
import TikjotDomain

/// Month = ledger (variant A) with a running-balance curve and week bands (§11.3).
struct MonthScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showAbsence = false
    @State private var hoverDay: LocalDate?

    private var month: DateRange { DateRange.month(of: model.selectedDay) }

    var body: some View {
        @Bindable var model = model
        let m = month
        let locked = model.lock.isLocked(m.end, today: model.today)
        VStack(spacing: 0) {
            PeriodToolbar(
                title: Fmt.monthYear(m.start),
                subtitle: String(localized: "expected \(DurationFormat.short(model.ledger.fund(m)))") +
                    (m.contains(model.today) ? " · " + String(localized: "today \(Fmt.weekdayShort(model.today)) \(model.today.day)") : "") +
                    (m.end < model.today.firstOfMonth && !locked ? " · " + String(localized: "open until \(Fmt.dayMonth(model.lock.editableUntil(m.start)))") : ""),
                todayTitle: String(localized: "This month"),
                range: m,
                step: { model.selectedDay = model.selectedDay.firstOfMonth.adding(months: $0) },
                goToday: { model.selectedDay = model.today },
                needYou: model.needYouCount(in: m),
                needYouAction: { model.monthFilterNeedsYou.toggle() },
                balanceLabel: String(localized: "month balance"),
                balanceHelp: model.monthBalanceHelp(m),
                addTitle: String(localized: "Add absence"),
                addAction: { showAbsence = true },
                addMenu: {
                    Button(String(localized: "Absence…")) { showAbsence = true }
                    Button(String(localized: "Entry today")) { model.selectedDay = model.today; model.mainSelection = .day; model.addEntry(on: model.today) }
                },
                review: { model.requestReview(days: Array(m), title: String(localized: "Send \(Fmt.monthName(m.start)) to Jira")) })
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BalanceCurve(month: m, hover: $hoverDay)
                    HStack {
                        PillSegmented(selection: $model.monthFilterNeedsYou, options: [
                            (false, String(localized: "All days · \(rows(m, needsYou: false).count)")),
                            (true, String(localized: "Needs you · \(rows(m, needsYou: true).count)")),
                        ])
                        Spacer()
                        Text(String(localized: "Click a day to open it")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                    }
                    ledger(m)
                }
                .padding(20)
            }
        }
        .onAppear { DebugUI.open("addAbsence") { showAbsence = true } }
        .surfaceSheet(isPresented: $showAbsence) {
            AbsenceForm { showAbsence = false }.padding(20).frame(width: 460).environment(model)
        }
    }

    /// Workdays plus any day with entries or an absence (weekends without work omitted).
    private func rows(_ m: DateRange, needsYou: Bool) -> [LocalDate] {
        let l = model.ledger
        let last = min(m.end, model.today)
        guard last >= m.start else { return [] }
        return DateRange(m.start, last).filter { d in
            let show = model.dayCalendar.isWorkday(d) || model.dayCalendar.holidays[d] != nil || !l.entries(on: d).isEmpty || !model.absences(on: d).isEmpty
            guard show else { return false }
            if needsYou { return !model.needsYou(on: d).isEmpty }  // blockers only (audit U1)
            return true
        }
    }

    private func ledger(_ m: DateRange) -> some View {
        let l = model.ledger
        let days = rows(m, needsYou: model.monthFilterNeedsYou)
        let weeks = Dictionary(grouping: days, by: { $0.startOfWeek })
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                col(String(localized: "DAY"), 130, .leading)
                col(String(localized: "EXPECTED"), 80, .trailing)
                col(String(localized: "WORKED"), 90, .trailing)
                if model.jiraConnected { col(String(localized: "IN JIRA"), 90, .trailing) }
                col(String(localized: "DAY ±"), 90, .trailing)
                Text(String(localized: "NOTE")).font(DS.F.sectionLabel).foregroundStyle(DS.C.text3).padding(.leading, 16)
                Spacer()
            }
            .frame(height: 30).padding(.horizontal, 14)
            ForEach(weeks.keys.sorted(), id: \.self) { w in
                // Design week band (IPDkR): the whole week within the month; numbers up to today.
                let shown = DateRange(max(w, m.start), min(w.adding(days: 6), m.end))
                let wr = DateRange(shown.start, max(shown.start, min(shown.end, model.today)))
                let current = shown.contains(model.today)
                let wWorked = l.worked(wr), wJira = l.inJira(wr)
                HStack(spacing: 0) {
                    Text("W\(w.weekNumber) · \(shown.start.day)–\(shown.end.day) \(Fmt.monthShort(shown.end))").font(.system(size: 11).monospacedDigit()).foregroundStyle(DS.C.text3).frame(width: 130, alignment: .leading)
                    // The running week: expected so far, by the balance's rule (its ± beside it agrees); today's full
                    // fund is in today's row.
                    Text(DurationFormat.padded(l.expectedSoFar(wr))).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.C.text3).frame(width: 80, alignment: .trailing)
                    Text(DurationFormat.padded(wWorked)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text2).frame(width: 90, alignment: .trailing)
                    if model.jiraConnected {
                        // Plain numbers: what isn't in Jira yet is said once, in the NOTE column.
                        Text(DurationFormat.padded(wJira)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.C.text2).frame(width: 90, alignment: .trailing)
                    }
                    Text(DurationFormat.signed(wr.filter { $0 >= model.dataStart }.reduce(0) { $0 + l.dayBalance($1) })).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text2).frame(width: 90, alignment: .trailing)
                    Text(current ? String(localized: "so far") : String(localized: "week")).font(DS.F.caption).foregroundStyle(DS.C.text3).padding(.leading, 16)
                    Spacer()
                }
                .frame(height: 25).padding(.horizontal, 14)
                .background(DS.C.surface2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(current ? String(localized: "Week \(w.weekNumber) so far: worked \(DurationFormat.hm(wWorked)) of \(DurationFormat.hm(l.expectedSoFar(wr)))")
                                    : String(localized: "Week \(w.weekNumber): worked \(DurationFormat.hm(wWorked)) of \(DurationFormat.hm(l.expectedSoFar(wr)))"))
                .accessibilityAddTraits(.isHeader)
                ForEach(weeks[w]!.sorted(), id: \.self) { d in LedgerRow(day: d) }
            }
            if m.contains(model.today) && model.today < m.end {
                let rest = DateRange(model.today.adding(days: 1), m.end)
                let wd = model.dayCalendar.workdays(in: rest)
                let planned = rest.filter { !model.absences(on: $0).isEmpty }.count
                // Design footer: calendar-clock + "Rest of October · 20 workdays · expected 158h · planned: Doctor 2h on Wed 7 Oct".
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock").font(.system(size: 12)).foregroundStyle(DS.C.text2)
                    Text(String(localized: "Rest of \(Fmt.monthName(m.start)) · \(wd.count) workdays · expected \(DurationFormat.short(l.fund(rest)))") + plannedText(rest))
                        .font(.system(size: 12)).foregroundStyle(DS.C.text2)
                    Spacer()
                }
                .padding(14)
            }
        }
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
        .clipShape(RoundedRectangle(cornerRadius: DS.R.card))
        .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
    }

    private func plannedText(_ rest: DateRange) -> String {
        let items = rest.flatMap { d in model.absences(on: d).map { (d, $0) } }
        guard !items.isEmpty else { return "" }
        let parts = items.prefix(2).map { d, a -> String in
            let name = model.absenceType(a.typeId)?.name ?? ""
            let amount = a.unit == .hours ? " " + DurationFormat.short(a.amountSeconds) : ""
            return "\(name)\(amount) on \(Fmt.short(d))"
        }
        return " · " + String(localized: "planned: \(parts.joined(separator: ", "))") + (items.count > 2 ? " …" : "")
    }

    private func col(_ t: String, _ w: CGFloat, _ a: Alignment) -> some View {
        Text(t).font(DS.F.sectionLabel).foregroundStyle(DS.C.text3).frame(width: w, alignment: a)
    }
}

struct LedgerRow: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    @State private var hover = false

    var body: some View {
        let l = model.ledger
        let fund = l.fund(day), worked = l.worked(day), inJira = l.inJira(day)
        let status = l.dayStatus(day, lock: model.lock, jiraConnected: model.jiraConnected)
        let diff = l.dayBalance(day)
        HStack(spacing: 0) {
            // Design ledger row: day 12/700, fund mono 12/500 tertiary, worked mono 12/500, ± pill 11/600.
            let isToday = day == model.today
            Text(Fmt.short(day)).font(.system(size: 12, weight: .bold)).frame(width: 130, alignment: .leading)
            Text(fund > 0 ? DurationFormat.padded(fund) : "—").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(DS.C.text3).frame(width: 80, alignment: .trailing)
            Text(DurationFormat.padded(worked)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(DS.C.text).frame(width: 90, alignment: .trailing)
            if model.jiraConnected {
                Text(worked > 0 ? DurationFormat.padded(inJira) : "—").font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(worked > 0 ? DS.C.text2 : DS.C.text3).frame(width: 90, alignment: .trailing)
            }
            Group {
                if (fund == 0 && worked == 0) || isToday { Text("") }   // today is still running (design: no pill)
                else if diff == 0 { Text("±0").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text3) }
                else {
                    Text(DurationFormat.signed(diff)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 9).fill(diff > 0 ? DS.C.successSoft : DS.C.warningSoft))
                }
            }
            .frame(width: 90, alignment: .trailing)
            note.padding(.leading, 16)
            Spacer()
            if hover { Text(String(localized: "Open day ›")).font(DS.F.caption).foregroundStyle(DS.C.brandText) }
            // Exceptions only (✓ / ! / ⇄ / lock): "not sent" and "nothing tracked" are told once, in the NOTE column.
            StateMark(status: status == .waiting || status == .missed ? .none : status).frame(width: 20)
        }
        .frame(height: 28).padding(.horizontal, 14)
        .background(hover ? DS.C.surface2.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.selectedDay = day; model.mainSelection = .day }
        .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border.opacity(0.6)).frame(height: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(fund: fund, worked: worked, inJira: inJira, diff: diff, status: status))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selectedDay = day; model.mainSelection = .day }
        .accessibilityActions {
            Button(String(localized: "Add absence…")) { model.absenceDraftDays = [day]; model.mainSelection = .day; model.selectedDay = day }
        }
        .contextMenu {
            Button(String(localized: "Open day")) { model.selectedDay = day; model.mainSelection = .day }
            Button(String(localized: "Add absence…")) { model.absenceDraftDays = [day]; model.mainSelection = .day; model.selectedDay = day }
        }
    }

    /// One sentence per row for VoiceOver: the columns with their names, then the notes and the mark (§14).
    private func spoken(fund: Seconds, worked: Seconds, inJira: Seconds, diff: Seconds, status: DayStatus) -> String {
        var parts = [day == model.today ? String(localized: "Today · \(Fmt.long(day))") : Fmt.long(day)]
        if fund > 0 { parts.append(String(localized: "expected \(DurationFormat.hm(fund))")) }
        parts.append(String(localized: "worked \(DurationFormat.hm(worked))"))
        if model.jiraConnected && worked > 0 { parts.append(String(localized: "in Jira \(DurationFormat.hm(inJira))")) }
        if day != model.today && (fund > 0 || worked > 0) { parts.append(String(localized: "day ± \(DurationFormat.signed(diff))")) }
        parts += noteParts.map(\.text)
        if status != .waiting && status != .missed, let mark = status.label { parts.append(mark) }
        return parts.joined(separator: ", ")
    }

    /// Notes (design): 12 regular text-secondary, only the icon tinted; an absence and the day's status combine.
    @ViewBuilder
    private var note: some View {
        let parts = noteParts
        if !parts.isEmpty {
            HStack(spacing: 10) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 5) {
                        Image(systemName: p.icon).font(.system(size: 11)).foregroundStyle(p.tint)
                        Text(p.text).font(.system(size: 12)).foregroundStyle(DS.C.text2).lineLimit(1)
                    }
                }
            }
        }
    }

    private var noteParts: [(icon: String, tint: Color, text: String)] {
        let l = model.ledger
        let cal = model.dayCalendar
        var out: [(String, Color, String)] = []
        if day == model.today, model.runningEntry != nil {
            out.append(("play.circle", DS.C.tick, String(localized: "Today · still running")))
        }
        if let h = cal.holidays[day] {
            out.append(("sun.max", DS.C.brand, String(localized: "Holiday · \(h.name)")))
        } else if let a = model.absences(on: day).first, let t = model.absenceType(a.typeId) {
            out.append((t.icon, DS.C.brand, a.unit == .halfDay ? String(localized: "\(t.name) ½ day") : (a.unit == .hours ? "\(t.name) \(DurationFormat.short(a.amountSeconds))" : t.name)))
        }
        if cal.dayType(day) == .weekend && l.worked(day) > 0 {
            out.append(("briefcase", DS.C.text2, String(localized: "Weekend work")))
        }
        guard day != model.today else { return out }
        let status = l.dayStatus(day, lock: model.lock, jiraConnected: model.jiraConnected)
        switch status {
        case .missed: out.append(("calendar.badge.exclamationmark", DS.C.warning, String(localized: "Nothing tracked")))
        case .failed:
            let g = l.groups(on: day).first { $0.syncState == .error }
            out.append(("exclamationmark.circle", DS.C.danger, String(localized: "\(model.issue(g?.issueRef)?.key ?? "") rejected — \(g?.lastError?.display ?? "")")))
        case .conflict:
            let g = l.groups(on: day).first { $0.syncState == .conflict }
            out.append(("arrow.left.arrow.right", DS.C.danger, String(localized: "\(model.issue(g?.issueRef)?.key ?? "") changed in Jira and here")))
        case .waiting:
            let n = l.lines(on: day).filter { let s = l.state(of: $0, lock: model.lock); return s == .unsent || s == .modified || s == .noIssue }.count
            if n > 0 { out.append(("circle.dotted", DS.C.warning, n == 1 ? String(localized: "1 task not sent") : String(localized: "\(n) tasks not sent"))) }
        default:
            if let was = l.groups(on: day).compactMap(\.changedInJiraWas).first {
                out.append(("arrow.triangle.2.circlepath", DS.C.text3, String(localized: "Changed in Jira · was \(DurationFormat.hm(was))")))
            }
        }
        return out
    }
}

/// Running balance (design "Main · Month"): one slim column per day of the month — height = running
/// balance up to that day (deficit below the line, overtime above), future days as a quiet tick,
/// tikjot's hover card per day, caption naming the biggest drop. Today is a point of its own, live
/// (`Ledger.runningBalance`): its column, the "so far" total and the toolbar balance are one number.
struct BalanceCurve: View {
    @Environment(AppModel.self) private var model
    let month: DateRange
    @Binding var hover: LocalDate?

    var body: some View {
        let days = model.ledger.runningBalance(month: month, since: model.dataStart)
        let counted = days.filter(\.counted)
        let total = counted.last?.running ?? 0
        let maxPos = max(counted.map(\.running).max() ?? 0, 0)
        let maxNeg = max(-(counted.map(\.running).min() ?? 0), 0)
        // Design chart (wSN98): 96 tall, the baseline fixed in the middle (47 up · 1 pt · 46 down).
        let scale = Double(max(maxPos, maxNeg, 2 * 3600))
        let drop = counted.min { $0.diff < $1.diff }
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(localized: "Running balance · \(Fmt.monthName(month.start))")).font(DS.F.bodySemibold)
                    Spacer()
                    // Same total as the toolbar and sidebar (`liveBalance`): today's point included.
                    Text(String(localized: "so far \(DurationFormat.signed(total))")).font(.system(size: 12).monospacedDigit()).foregroundStyle(DS.C.text2)
                }
                if counted.isEmpty {
                    // Nothing to draw yet: one line instead of a chart full of dashes.
                    Text(caption(counted, drop: drop)).font(DS.F.caption).foregroundStyle(DS.C.text3)
                } else {
                    chart(days, scale: scale, drop: drop)
                    HStack {
                        Text(Fmt.dayMonth(month.start)).font(.system(size: 10).monospacedDigit()).foregroundStyle(DS.C.text3)
                        Spacer()
                        Text(caption(counted, drop: drop)).font(DS.F.caption).foregroundStyle(DS.C.text3)
                        Spacer()
                        Text(Fmt.dayMonth(month.end)).font(.system(size: 10).monospacedDigit()).foregroundStyle(DS.C.text3)
                    }
                }
            }
        }
    }

    private func chart(_ days: [BalancePoint], scale: Double, drop: BalancePoint?) -> some View {
        GeometryReader { g in
            let n = CGFloat(days.count)
            let gap: CGFloat = 4
            let colW = max(4, (g.size.width - gap * (n - 1)) / n)
            HStack(alignment: .top, spacing: gap) {
                ForEach(days) { day in
                    column(day, width: colW, scale: scale, isDrop: day.id == drop?.id && (drop?.diff ?? 0) < 0)
                        .onHover { inside in
                            if inside { hover = day.counted ? day.id : nil } else if hover == day.id { hover = nil }
                        }
                        .chartTooltip("month.balance.\(day.id)", day.counted ? tooltip(day) : nil)
                        .onTapGesture { if day.counted { model.selectedDay = day.id; model.mainSelection = .day } }
                        // The hover card is what VoiceOver reads (chartTooltip); days still to come are skipped.
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.selectedDay = day.id; model.mainSelection = .day }
                        .accessibilityHidden(!day.counted)
                }
            }
        }
        .frame(height: 96)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Running balance · \(Fmt.monthName(month.start))"))
    }

    @ViewBuilder
    private func column(_ d: BalancePoint, width: CGFloat, scale: Double, isDrop: Bool) -> some View {
        let h = 46 * CGFloat(Double(abs(d.running)) / scale)
        let hovered = hover == d.id
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color.clear
                if d.counted && d.running > 0 {
                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3).fill(DS.C.success.opacity(hovered ? 0.9 : 0.45)).frame(height: max(2, h))
                }
            }
            .frame(height: 47)
            Rectangle().fill(DS.C.borderStrong.opacity(d.counted ? 1 : 0.5)).frame(height: 1)
            ZStack(alignment: .top) {
                Color.clear
                if d.counted && d.running < 0 {
                    UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3).fill(DS.C.warning.opacity(hovered || isDrop ? 0.95 : 0.4)).frame(height: max(2, h))
                }
            }
            .frame(height: 46)
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }

    private func tooltip(_ d: BalancePoint) -> TooltipContent {
        let isToday = d.date == model.today
        let note: String
        if isToday && d.worked < d.expected && d.diff == 0 {
            note = String(localized: "So far today · a shortfall counts once the working day is over")
        } else if d.worked == 0 && d.expected > 0 {
            note = String(localized: "Nothing tracked · click to open the day")
        } else {
            note = String(localized: "Click to open the day")
        }
        return TooltipContent(
            title: isToday ? String(localized: "Today · \(Fmt.short(d.date))") : Fmt.short(d.date),
            rows: [
                .init(label: String(localized: "Worked"), value: DurationFormat.hm(d.worked)),
                .init(label: String(localized: "Expected"), value: DurationFormat.short(d.expected)),
                .init(label: String(localized: "Day ±"), value: DurationFormat.signed(d.diff)),
                .init(label: String(localized: "Running balance"), value: DurationFormat.signed(d.running), strong: true),
            ],
            note: note)
    }

    private func caption(_ past: [BalancePoint], drop: BalancePoint?) -> String {
        if past.count <= 3 { return String(localized: "the month has just started") }
        guard let drop, drop.diff < -1800 else { return String(localized: "steady so far") }
        if drop.worked == 0 { return String(localized: "the drop: \(Fmt.short(drop.id)) has nothing tracked (\(DurationFormat.signed(drop.diff)))") }
        return String(localized: "biggest dip: \(Fmt.short(drop.id)) (\(DurationFormat.signed(drop.diff)))")
    }
}
