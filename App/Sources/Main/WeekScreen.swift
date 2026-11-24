import SwiftUI
import TikjotDomain
import TikjotPersistence

/// Week: editable task × day grid (§7.4). Day totals pinned under the header.
struct WeekScreen: View {
    @Environment(AppModel.self) private var model
    @State private var extraRows: [WeekRowKey] = []
    @State private var addingRow = false
    @State private var showAbsence = false

    private var week: DateRange { DateRange.week(of: model.selectedDay) }

    var body: some View {
        let w = week
        let rows = rowKeys(w)
        VStack(spacing: 0) {
            PeriodToolbar(
                title: String(localized: "Week \(w.start.weekNumber)"),
                subtitle: "\(Fmt.dayMonth(w.start)) – \(Fmt.dayMonth(w.end)) · " + String(localized: "expected \(DurationFormat.short(model.ledger.fund(w)))"),
                todayTitle: String(localized: "This week"),
                range: w,
                step: { model.selectedDay = model.selectedDay.adding(days: 7 * $0) },
                goToday: { model.selectedDay = model.today },
                needYou: model.needYouCount(in: w),
                needYouAction: { model.mainSelection = .unsent; model.unsentFilterNeedsYou = true },
                balanceLabel: String(localized: "week balance"),
                addTitle: String(localized: "Add task"),
                addAction: { addingRow = true },
                addMenu: {
                    Button(String(localized: "Task row")) { addingRow = true }
                    Button(String(localized: "Absence…")) { showAbsence = true }
                },
                review: { model.requestReview(days: Array(w), title: String(localized: "Send week \(w.start.weekNumber) to Jira")) })
            Divider().opacity(0.5)
            if w.start > model.today {
                VStack(spacing: 12) {
                    Spacer()
                    Illustration(name: "illAhead", width: 260)
                    Text(String(localized: "Next week hasn't started")).font(DS.F.title)
                    Text(String(localized: "Plan an absence ahead, or come back on Monday.")).foregroundStyle(DS.C.text2)
                    Button(String(localized: "Add absence…")) { showAbsence = true }.buttonStyle(.pill)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if FridayRecap.shouldShow(model, week: w) { FridayRecap(week: w) }
                        WeekGrid(week: w, rows: rows, addingRow: $addingRow) { key in
                            if !extraRows.contains(key) { extraRows.append(key) }
                        }
                        .zIndex(1)   // the add row's dropdown hangs over what follows
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle").foregroundStyle(DS.C.brand)
                            Text(String(localized: "Day totals stay pinned under the header. Type a duration into any cell — tikjot adds or shortens entries at the end of that day; ⌄ in a cell shows its entries. ⇧⌘S reviews & sends the week."))
                                .font(DS.F.caption).foregroundStyle(DS.C.text2)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, addingRow ? 240 : 0)   // room for the dropdown at the end of the scroll
                }
            }
        }
        .onChange(of: model.selectedDay) { _, _ in extraRows = [] }
        .onAppear {
            DebugUI.open("addAbsence") { showAbsence = true }
            DebugUI.open("weekAddRow") { addingRow = true }
        }
        .surfaceSheet(isPresented: $showAbsence) {
            AbsenceForm(initialDay: w.start) { showAbsence = false }.padding(20).frame(width: 460).environment(model)
        }
    }

    private func rowKeys(_ w: DateRange) -> [WeekRowKey] {
        var keys: [WeekRowKey] = []
        for d in w {
            for e in model.ledger.workEntries(on: d) {
                let k = WeekRowKey(instanceId: e.instanceId, issueId: e.issueId, projectId: e.projectId)
                if !keys.contains(k) { keys.append(k) }
            }
        }
        for k in extraRows where !keys.contains(k) { keys.append(k) }
        return keys.sorted { a, b in
            if a.issueId == nil && b.issueId != nil { return false }
            if b.issueId == nil && a.issueId != nil { return true }
            return (model.issue(a.ref)?.key ?? "") < (model.issue(b.ref)?.key ?? "")
        }
    }
}

/// Where the add row's task column is, for the picker drawn over the grid.
private struct AddRowAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

struct WeekRowKey: Hashable {
    var instanceId: UUID?
    var issueId: String?
    var projectId: UUID?
    var ref: IssueRef? { instanceId.flatMap { i in issueId.map { IssueRef(instanceId: i, issueId: $0) } } }
}

struct WeekGrid: View {
    @Environment(AppModel.self) private var model
    let week: DateRange
    let rows: [WeekRowKey]
    @Binding var addingRow: Bool
    let addRow: (WeekRowKey) -> Void
    /// Design grid (zlAHG): the task column takes the room, each day is 82 wide, the week total 90;
    /// every day and the total have a 1 pt divider on the left.
    static let dayW: CGFloat = 82
    static let totalW: CGFloat = 90

    var body: some View {
        let l = model.ledger
        let days = Array(week)
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 0) {
                Text(String(localized: "TASK")).font(DS.F.sectionLabel).foregroundStyle(DS.C.text3)
                    .padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(days, id: \.self) { d in
                    let cal = model.dayCalendar
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 3) {
                            if model.lock.isLocked(d, today: model.today) { Image(systemName: "lock.fill").font(.system(size: 8)) }
                            Text("\(Fmt.weekdayShort(d)) \(d.day)").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(d == model.today ? DS.C.brandText : (cal.fund(d) == 0 && cal.dayType(d) != .workday ? DS.C.text2 : DS.C.text))
                        }
                        Text(headerSub(d, cal)).font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(d == model.today ? DS.C.text2 : DS.C.text3)   // text3 on brand-soft < 4.5:1
                    }
                    .padding(.trailing, 10).frame(width: Self.dayW, alignment: .trailing).frame(maxHeight: .infinity)
                    .background(d == model.today ? DS.C.brandSoft : .clear)
                    .weekDivider()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([Fmt.long(d), headerSub(d, cal), d == model.today ? String(localized: "today") : nil,
                                         model.lock.isLocked(d, today: model.today) ? String(localized: "locked") : nil].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityAddTraits(.isHeader)
                }
                Text(String(localized: "Week")).font(.system(size: 12, weight: .bold)).padding(.trailing, 12)
                    .frame(width: Self.totalW, alignment: .trailing).frame(maxHeight: .infinity).weekDivider()
            }
            .frame(height: 48)
            // Day totals row (pinned in spirit: right under the header). On brand-soft, so quiet text is text2
            // (text3 there is under 4.5:1).
            HStack(spacing: 0) {
                Text(model.jiraConnected ? String(localized: "Day total · ± · in Jira") : String(localized: "Day total · ±"))
                    .font(DS.F.bodySemibold).padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(days, id: \.self) { d in
                    let worked = l.worked(d), fund = l.fund(d), inJira = l.inJira(d)
                    let status = l.dayStatus(d, lock: model.lock, jiraConnected: model.jiraConnected)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(d > model.today ? "—" : DurationFormat.padded(worked)).font(DS.F.monoMedium)
                            .foregroundStyle(d > model.today ? DS.C.text2 : DS.C.text)
                        if d <= model.today && fund > 0 && d >= model.dataStart {
                            if worked == 0 && d < model.today {
                                Text(String(localized: "nothing tracked")).font(.system(size: 10)).foregroundStyle(DS.C.text2)
                            } else {
                                Text(DurationFormat.signed(l.dayBalance(d))).font(.system(size: 10, design: .monospaced)).foregroundStyle(DS.C.text2)
                            }
                        }
                        // At most one Jira line per column: amber only when the day needs you; "not in Jira"
                        // stays calm (grey dot, as in the popover); nothing when nothing is tracked.
                        if !model.needsYou(on: d).isEmpty && d < model.today && worked > 0 {   // blockers only (audit U1)
                            HStack(spacing: 4) { NeedsYouDot(size: 5); Text(String(localized: "needs you")) }
                                .font(.system(size: 10)).foregroundStyle(DS.C.text2)
                        } else if model.jiraConnected && worked > 0 {
                            if inJira >= worked {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.C.success)
                                    Text(String(localized: "in Jira"))
                                }
                                .font(.system(size: 10)).foregroundStyle(DS.C.text2)
                            } else {
                                HStack(spacing: 4) { Circle().fill(DS.C.borderStrong).frame(width: 5, height: 5); Text(String(localized: "not in Jira")) }
                                    .font(.system(size: 10)).foregroundStyle(DS.C.text2)
                                    .help(inJira > 0 ? String(localized: "In Jira \(DurationFormat.hm(inJira))") : "")
                            }
                        }
                    }
                    .padding(.trailing, 10).frame(width: Self.dayW, alignment: .trailing).frame(maxHeight: .infinity)
                    .weekDivider()
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(localized: "Day total \(Fmt.weekday(d))"))
                }
                let wk = l.worked(week)
                // The running week against what was expected so far (the balance's rule), the full week in the
                // toolbar subtitle and the tooltip (owner 2026-10-07: "the current week always looks behind").
                let so = l.soFar(week)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(DurationFormat.padded(wk)).font(DS.F.monoMedium).rolls(DurationFormat.padded(wk))
                    Text(so.isRunning && so.hasMoreToCome ? String(localized: "of \(DurationFormat.short(so.expected)) so far")
                         : String(localized: "of \(DurationFormat.short(so.full))")).font(.system(size: 10)).foregroundStyle(DS.C.text2)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    // Hidden while nothing is in Jira ("Jira 0h 00m" was noise); calm text when something is.
                    if model.jiraConnected && l.inJira(week) > 0 {
                        Text("Jira \(DurationFormat.padded(l.inJira(week)))").font(.system(size: 10, design: .monospaced)).foregroundStyle(DS.C.text2)
                    }
                }
                .padding(.trailing, 12).frame(width: Self.totalW, alignment: .trailing).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Week total"))
                .chartTooltip("week.total", so.isRunning && so.hasMoreToCome ? TooltipContent(
                    title: String(localized: "Week \(week.start.weekNumber) so far"),
                    rows: [.init(label: String(localized: "Worked"), value: DurationFormat.hm(wk), strong: true),
                           .init(label: String(localized: "Expected so far"), value: DurationFormat.short(so.expected)),
                           .init(label: String(localized: "Full week"), value: DurationFormat.short(so.full))],
                    note: String(localized: "Today counts once you've worked its hours or the working day is over — as in the balance.")) : nil)
                .weekDivider()
            }
            .frame(height: 56)
            .background(DS.C.brandSoft)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.C.brand).frame(height: 1.5) }

            ForEach(rows, id: \.self) { key in
                WeekRow(key: key, week: week)
                Divider().opacity(0.6)
            }
            if addingRow {
                // The new row lives in the grid (design LuXG1): its search field in the task column, empty days.
                // The picker itself is drawn over the grid (below), so its results can hang past the card's edge.
                HStack(spacing: 0) {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .anchorPreference(key: AddRowAnchor.self, value: .bounds) { $0 }
                    ForEach(days, id: \.self) { _ in
                        Color.clear.frame(width: Self.dayW).frame(maxHeight: .infinity).weekDivider()
                    }
                    Text("—").font(DS.F.mono).foregroundStyle(DS.C.text3).padding(.trailing, 12)
                        .frame(width: Self.totalW, alignment: .trailing).frame(maxHeight: .infinity).weekDivider()
                }
                .frame(height: Self.addRowH)
                Divider().opacity(0.6)
            }
            // Absences row
            let absDays = days.filter { !model.absences(on: $0).isEmpty }
            if !absDays.isEmpty {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "stethoscope").font(.system(size: 12)).foregroundStyle(DS.C.brand)
                        Text(String(localized: "Absences")).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.text)
                    }
                    .padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(days, id: \.self) { d in
                        let a = model.absences(on: d).first
                        Text(a.map { abs in "\(model.absenceType(abs.typeId)?.name ?? "") \(abs.unit == .hours ? DurationFormat.short(abs.amountSeconds) : "")" } ?? "")
                            .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(DS.C.text).lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.trailing, 10).frame(width: Self.dayW, alignment: .trailing).frame(maxHeight: .infinity).weekDivider()
                            .accessibilityLabel(a == nil ? "" : "\(Fmt.weekday(d)): " + (a.map { abs in "\(model.absenceType(abs.typeId)?.name ?? "") \(abs.unit == .hours ? DurationFormat.short(abs.amountSeconds) : "")" } ?? ""))
                            .accessibilityHidden(a == nil)
                    }
                    Color.clear.frame(width: Self.totalW).weekDivider()
                }
                .frame(height: 44)
                .background(DS.C.brandSoft)
            }
        }
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
        .clipShape(RoundedRectangle(cornerRadius: DS.R.card))
        .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
        .overlayPreferenceValue(AddRowAnchor.self) { anchor in
            if addingRow, let anchor {
                GeometryReader { g in
                    let r = g[anchor]
                    addRowPicker
                        .frame(width: max(r.width - 28, 260))
                        .offset(x: r.minX + 14, y: r.minY + (Self.addRowH - DS.H.field) / 2)
                }
            }
        }
    }

    static let addRowH: CGFloat = 44

    /// The shared picker as the design's inline search + dropdown: its field sits in the new row, the results
    /// and the note drop down under it on a card.
    private var addRowPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskPicker(allowNoTask: true) { issue, pid in
                addRow(WeekRowKey(instanceId: issue?.instanceId, issueId: issue?.issueId, projectId: pid))
                addingRow = false
            } onCancel: { addingRow = false }
            DropdownNote(text: String(localized: "↩ adds the row — then type hours into its days. A row without hours disappears when you leave."))
        }
        .background {
            TaskDropdownCard().padding(EdgeInsets(top: DS.H.field + 4, leading: -6, bottom: -8, trailing: -6))
        }
    }

    private func headerSub(_ d: LocalDate, _ cal: DayCalendar) -> String {
        if cal.holidays[d] != nil { return String(localized: "Holiday") }
        if let a = model.absences(on: d).first(where: { $0.unit != .hours }), let t = model.absenceType(a.typeId) {
            return a.unit == .halfDay ? String(localized: "½ \(t.name.lowercased())") : t.name
        }
        let f = cal.fund(d)
        return f == 0 ? String(localized: "expected \("—")") : String(localized: "expected \(DurationFormat.short(f))")
    }
}

struct WeekRow: View {
    @Environment(AppModel.self) private var model
    let key: WeekRowKey
    let week: DateRange

    var body: some View {
        let issue = model.issue(key.ref)
        let project = model.project(key.projectId)
        let total = week.reduce(0) { $0 + cellValue($1) }
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let issue {
                    Circle().fill(DS.project(project?.color ?? "slate")).frame(width: 7, height: 7)
                    KeyName(key: issue.key, name: issue.summary, minName: 60, stacked: false)
                } else {
                    NoTaskMark(size: 13)
                    Text(String(localized: "No task · \(project?.name ?? "")")).font(DS.F.body).foregroundStyle(DS.C.text2).lineLimit(1)
                }
            }
            .padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowName(issue, project))
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(week), id: \.self) { d in
                WeekCell(key: key, day: d, value: cellValue(d), rowName: rowName(issue, project))
                    .frame(width: WeekGrid.dayW).frame(maxHeight: .infinity)
                    .background(d == model.today ? DS.C.brand.opacity(0.04) : .clear)
                    .weekDivider()
            }
            Text(DurationFormat.padded(total)).font(DS.F.monoMedium).rolls(DurationFormat.padded(total)).padding(.trailing, 12)
                .frame(width: WeekGrid.totalW, alignment: .trailing).frame(maxHeight: .infinity).weekDivider()
                .accessibilityLabel(String(localized: "Week total \(DurationFormat.hm(total))"))
        }
        .frame(height: 44)
        .accessibilityElement(children: .contain)
    }

    private func rowName(_ issue: Issue?, _ project: Project?) -> String {
        issue.map { "\($0.key) \($0.summary)" } ?? String(localized: "No task · \(project?.name ?? "")")
    }

    private func cellValue(_ d: LocalDate) -> Seconds {
        model.ledger.lines(on: d).filter { l in
            l.entries.contains { $0.instanceId == key.instanceId && $0.issueId == key.issueId && (key.issueId != nil || $0.projectId == key.projectId) }
        }.reduce(0) { $0 + $1.value }
    }
}

struct WeekCell: View {
    @Environment(AppModel.self) private var model
    let key: WeekRowKey
    let day: LocalDate
    let value: Seconds
    /// The row's task, so VoiceOver can say which cell this is.
    var rowName = ""
    @State private var editing = false
    @State private var text = ""
    @State private var what = ""
    @State private var hover = false
    @State private var detail = false
    @FocusState private var focused: Bool

    private var entries: [TimeEntry] {
        model.ledger.workEntries(on: day).filter { $0.instanceId == key.instanceId && $0.issueId == key.issueId && (key.issueId != nil || $0.projectId == key.projectId) }
    }

    var body: some View {
        let editable = model.lock.canEditEntries(on: day, today: model.today)
        let status = cellStatus
        ZStack(alignment: .trailing) {
            if editing {
                TextField("", text: $text)
                    .accessibilityLabel(String(localized: "Time for \(rowName), \(Fmt.long(day))"))
                    .textFieldStyle(.plain).font(DS.F.monoMedium).multilineTextAlignment(.trailing)
                    .focused($focused)
                    .focusEffectDisabled()   // the brand outline is the focus ring
                    .onSubmit(commit)
                    // Clicking elsewhere (another cell, outside) ends the edit and keeps a valid time, like other fields.
                    .onChange(of: focused) { _, f in if !f && editing { commit() } }
                    .onKeyPress(.escape) { editing = false; return .handled }
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
                    .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(DS.C.brand, lineWidth: 1.5))
                    .padding(.horizontal, 5)   // inside the cell, clear of its grid lines
                    .surfacePopover(isPresented: .constant(editing && DurationFormat.parse(text) != nil), arrowEdge: .bottom) { hintView.padding(12).frame(width: 300) }
            } else {
                HStack(spacing: 4) {
                    if hover && value > 0 {
                        Button { detail = true } label: { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }.buttonStyle(.icon)
                    }
                    Spacer(minLength: 0)
                    // Marks only the exceptions (✓ sent / ! failed / ⇄ conflict); "not sent yet" is the normal state.
                    StateMark(status: status == .waiting ? .none : status)
                    Text(value > 0 ? DurationFormat.padded(value) : (editable ? "—" : "")).font(DS.F.monoMedium).lineLimit(1).fixedSize()
                        .foregroundStyle(value > 0 ? (editable ? DS.C.text : DS.C.text3) : DS.C.text3)
                }
                .padding(.horizontal, 10).frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture { if editable { start() } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([rowName, Fmt.long(day), value > 0 ? DurationFormat.hm(value) : String(localized: "nothing"),
                                     status.label, editable ? nil : String(localized: "locked")].compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(editable ? .isButton : [])
                .accessibilityHint(editable ? String(localized: "Type the time for this day") : "")
                .accessibilityAction { if editable { start() } }
                .accessibilityActions {
                    if value > 0 { Button(String(localized: "Show entries")) { detail = true } }
                    Button(String(localized: "Open day")) { model.selectedDay = day; model.mainSelection = .day }
                }
            }
        }
        .onHover { hover = $0 }
        .background(day == model.today ? DS.C.brandSoft.opacity(0.18) : .clear)
        .surfacePopover(isPresented: $detail, arrowEdge: .bottom) { cellDetail.padding(12).frame(width: 320) }
        .help(splitHelp)
    }

    private var cellStatus: DayStatus {
        guard model.jiraConnected, value > 0, key.issueId != nil else { return .none }
        let lines = model.ledger.lines(on: day).filter { l in l.entries.contains { e in entries.contains { $0.id == e.id } } }
        let states = lines.map { model.ledger.state(of: $0, lock: model.lock) }
        if states.contains(.conflict) { return .conflict }
        if states.contains(.error) { return .failed }
        if states.contains(where: { $0 == .unsent || $0 == .modified }) { return .waiting }
        if states.allSatisfy({ $0 == .synced }) { return .allInJira }
        return .none
    }

    private var splitHelp: String {
        guard let g = entries.first?.worklogGroupId, let group = model.data.groups.first(where: { $0.id == g }), let sent = group.lastSent, sent.durationSeconds < value else { return "" }
        return String(localized: "In Jira \(DurationFormat.hm(sent.durationSeconds)) / Not sent yet +\(DurationFormat.hm(value - sent.durationSeconds)) · next send — Jira gets one worklog per task and day")
    }

    private func start() {
        text = value > 0 ? DurationFormat.short(value) : ""
        what = entries.last?.description ?? model.data.entries.last { $0.instanceId == key.instanceId && $0.issueId == key.issueId && !$0.description.isEmpty }?.description ?? ""
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private var hintView: some View {
        let target = DurationFormat.parse(text) ?? 0
        let diff = target - value
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(DurationFormat.hm(value)) → \(DurationFormat.hm(target))").font(DS.F.monoMedium)
            Text(diff > 0 ? String(localized: "adds \(DurationFormat.short(diff)) after the last entry of the day")
                 : diff < 0 ? String(localized: "shortens the task's last entries by \(DurationFormat.short(-diff))")
                 : String(localized: "no change")).font(DS.F.caption).foregroundStyle(DS.C.text2)
            // No text field here: it would take the keys from the cell mid-typing ("1h30" → "1" + "h30"), and ↩ would
            // stop working. The new entry gets the task's last description; it can be changed in the Day view.
            if diff > 0 && entries.isEmpty && !what.isEmpty {
                Text(String(localized: "as “\(what)”")).font(DS.F.caption).foregroundStyle(DS.C.text2).lineLimit(1)
            }
            Text(String(localized: "↩ set · esc cancel")).font(DS.F.caption).foregroundStyle(DS.C.text3)
        }
    }

    private func commit() {
        editing = false
        guard let target = DurationFormat.parse(text), target != value else { return }
        let template = entries.last ?? TimeEntry(start: day.start(in: .current), end: nil, instanceId: key.instanceId, issueId: key.issueId, projectId: key.projectId)
        let ch = EntryOps.setCell(task: template, dayEntries: model.ledger.workEntries(on: day), current: entries.reduce(0) { $0 + $1.duration(now: model.now) },
                                  target: target, day: day, workdayStartMinutes: model.schedule.period(on: day).workdayStart,
                                  description: what, now: model.now, calendar: .current)
        let shortened = ch.updated.first.map { e in e.description.isEmpty ? model.taskLabel(for: e) : e.description }
        model.apply(ch, name: "Set \(DurationFormat.short(target))",
                    toast: target < value ? String(localized: "Shortened “\(shortened ?? "")”") : nil)
    }

    private var cellDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Fmt.short(day)) · \(DurationFormat.hm(value))").font(DS.F.bodySemibold)
            ForEach(entries) { e in
                HStack {
                    Text(Fmt.range(e.start, e.end)).font(DS.F.mono).foregroundStyle(DS.C.text2)
                    DescriptionLabel(text: e.description)
                    Spacer()
                    Text(DurationFormat.short(e.duration(now: model.now))).font(DS.F.mono)
                }
            }
            if let g = entries.first?.worklogGroupId.flatMap({ id in model.data.groups.first { $0.id == id } }) {
                if g.syncState == .error {
                    Text(g.lastError?.display ?? "").font(DS.F.caption).foregroundStyle(DS.C.dangerText)
                    Button(String(localized: "Retry")) { Task { await model.retry(g.id) } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                } else if g.syncState == .conflict {
                    HStack {
                        Button(String(localized: "Take Jira's")) { Task { await model.takeJira(g.id) } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                        Button(String(localized: "Keep mine")) { Task { await model.keepMine(g.id) } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                    }
                }
            }
            Button(String(localized: "Open day")) { detail = false; model.selectedDay = day; model.mainSelection = .day }.buttonStyle(.pill(.secondary, height: DS.H.small))
        }
    }
}

private extension View {
    /// The grid's 1 pt column divider on the left (design lmrNI).
    func weekDivider() -> some View { overlay(alignment: .leading) { Rectangle().fill(DS.C.border).frame(width: 1) } }
}
