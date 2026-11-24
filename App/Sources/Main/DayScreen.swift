import SwiftUI
import TikjotDomain
import TikjotPersistence

/// Day: vertical timeline (calendar-like) + inspector (§7.3, §11.3).
struct DayScreen: View {
    @Environment(AppModel.self) private var model
    var availableWidth: CGFloat = 1000
    @State private var showAbsence = false

    private var day: LocalDate { model.selectedDay }

    var body: some View {
        let floatingInspector = availableWidth < 1180 - 230
        let hideInspector = availableWidth < 900 - 64
        VStack(spacing: 0) {
            PeriodToolbar(
                title: Fmt.long(day),
                subtitle: subtitle,
                todayTitle: String(localized: "Today"),
                range: DateRange(day, day),
                step: { model.selectedDay = day.adding(days: $0); model.selectedEntryIds = [] },
                goToday: { model.selectedDay = model.today; model.selectedEntryIds = [] },
                needYou: model.needYouCount(in: DateRange.month(of: day)),
                needYouAction: { model.mainSelection = .month; model.monthFilterNeedsYou = true },
                balanceLabel: String(localized: "day balance"),
                addTitle: String(localized: "Add entry"),
                addAction: { model.addEntry(on: day) },
                addMenu: {
                    Button(String(localized: "Entry in free time")) { model.addEntry(on: day) }
                    Button(String(localized: "Absence…")) { showAbsence = true }
                },
                review: { model.requestReview(days: [day], title: String(localized: "Send \(Fmt.dayName(day, today: model.today)) to Jira")) },
                compact: floatingInspector)
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    dayContent
                    if floatingInspector && !hideInspector && !model.selectedEntryIds.isEmpty {
                        DayInspector(day: day)
                            .frame(width: 320)
                            .modifier(FloatingInspectorSurface())
                            .padding(12)
                    }
                }
                if !floatingInspector {
                    Divider().opacity(0.5)
                    DayInspector(day: day)
                        .frame(width: 330)
                        .background(DS.C.surface)
                }
            }
        }
        .surfaceSheet(isPresented: $showAbsence) {
            // Drafts (Month / Unsent rows) still win inside the form.
            AbsenceForm(initialDay: day) { showAbsence = false }
                .padding(20).frame(width: 460)
                .environment(model)
        }
        // "Add absence" from a Month or Unsent row lands here with the day prefilled.
        .onAppear {
            if !model.absenceDraftDays.isEmpty { showAbsence = true }
            DebugUI.open("addAbsence") { showAbsence = true }
        }
        .onChange(of: model.absenceDraftDays) { _, v in if !v.isEmpty && model.mainSelection == .day { showAbsence = true } }
    }

    private var subtitle: String {
        let cal = model.dayCalendar
        let fund = cal.fund(day)
        var parts: [String] = []
        switch cal.dayType(day) {
        case .holiday: parts.append(String(localized: "Holiday · \(cal.holidays[day]?.name ?? "")"))
        case .weekend: parts.append(String(localized: "Weekend"))
        case .custom: parts.append(cal.customDays[day]?.name ?? "")
        case .workday: parts.append(String(localized: "Workday"))
        }
        var fundText = String(localized: "expected \(DurationFormat.short(fund))")
        let abs = model.absences(on: day).compactMap { a in model.absenceType(a.typeId).map { (a, $0) } }
        if let (a, t) = abs.first {
            fundText += " (" + (a.unit == .hours ? "\(t.name.lowercased()) \(DurationFormat.short(a.amountSeconds))" : t.name.lowercased()) + ")"
        }
        parts.append(fundText)
        if model.lock.isLocked(day, today: model.today) { parts.append(String(localized: "locked")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var dayContent: some View {
        let entries = model.ledger.entries(on: day)
        let absences = model.absences(on: day)
        if entries.isEmpty && absences.filter({ $0.unit == .hours }).isEmpty {
            DayEmptyState(day: day)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                DayTimeline(day: day)
            }
        }
    }

    private func deleteSelection() {
        let es = model.selectedEntries
        guard !es.isEmpty, model.lock.canEditEntries(on: day, today: model.today) else { return }
        model.delete(es)
    }
}

/// The day's working hours as a quiet grid behind an empty-day card.
struct EmptyHourGrid: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    var body: some View {
        let start = max(0, model.schedule.period(on: day).workdayStart / 60 - 1)
        GeometryReader { _ in
            HourGrid().offset(y: -CGFloat(start) * DayTimeline.hourHeight)
        }
        .clipped()
        .padding(.horizontal, 20)
        .allowsHitTesting(false)
    }
}

/// Empty days follow the popover pattern: one illustration, one sentence, one useful action (§7.3).
struct DayEmptyState: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    @State private var showAbsence = false
    @State private var editingAbsence: [Absence]?

    var body: some View {
        let cal = model.dayCalendar
        let l = model.ledger
        // Design (G3KFRG / JlYCr): a surface card floating over the day's hour grid.
        ZStack {
            EmptyHourGrid(day: day)
            VStack(spacing: 12) {
            if let h = cal.holidays[day] {
                Illustration(name: "illHoliday", width: 240)
                Text(h.name).font(DS.F.screenTitle).multilineTextAlignment(.center)
                Text(String(localized: "Public holiday · expected 0h. Next workday: \(Fmt.long(nextWorkday)).")).font(DS.F.body).foregroundStyle(DS.C.text2)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Text(String(localized: "Worked anyway?")).font(DS.F.body).foregroundStyle(DS.C.text2)
                    Button { model.addEntry(on: day) } label: { Label(String(localized: "Add entry"), systemImage: "plus") }.buttonStyle(.pill(.secondary, height: DS.H.small))
                    Text(String(localized: "counts as overtime")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                }
            } else if let a = model.absences(on: day).first(where: { $0.unit == .day }), let t = model.absenceType(a.typeId) {
                Illustration(name: t.builtin == .sickLeave ? "illSickDay" : (t.builtin == .childCare ? "illChildCare" : "illVacation"), width: 240)
                Text(t.name).font(DS.F.screenTitle).accessibilityIdentifier("day.empty.title")
                Text(rangeText(a)).foregroundStyle(DS.C.text2).multilineTextAlignment(.center)
                // Design "Main · Day · vacation": the range in words, then "Worked anyway? + Add entry · counts as overtime".
                HStack(spacing: 8) {
                    Text(String(localized: "Worked anyway?")).font(DS.F.body).foregroundStyle(DS.C.text2)
                    Button { model.addEntry(on: day) } label: { Label(String(localized: "Add entry"), systemImage: "plus") }.buttonStyle(.pill(.secondary, height: DS.H.small))
                    Text(String(localized: "counts as overtime")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                }
                Button(String(localized: "Edit absence…")) {
                    editingAbsence = a.rangeId.map { rid in model.data.absences.filter { $0.rangeId == rid && $0.deletedAt == nil } } ?? [a]
                }
                .buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                .accessibilityIdentifier("day.editAbsence")
                .disabled(model.lock.isLocked(day, today: model.today))
            } else if day == model.today {
                Illustration(name: "illMorning", width: 240)
                let y = model.today.adding(days: -1)
                Text(String(localized: "Good morning")).font(DS.F.screenTitle)
                Text(String(localized: "Yesterday \(DurationFormat.hm(l.worked(y))) · balance \(DurationFormat.signed(l.balance(model.balanceRange)))"))
                    .foregroundStyle(DS.C.text2)
                let yEntries = l.workEntries(on: y).suffix(3)
                if !yEntries.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(Array(yEntries)) { e in
                            HStack {
                                TimeEdge(color: DS.project(model.project(e.projectId)?.color ?? "slate")).frame(height: 24)
                                DescriptionLabel(text: e.description.isEmpty ? model.taskLabel(for: e) : e.description)
                                Spacer()
                                Button(String(localized: "Continue")) { model.continueEntry(e) }.buttonStyle(.pill(.secondary, height: DS.H.small))
                            }
                        }
                    }
                    .frame(width: 360)
                }
                HStack {
                    Button(String(localized: "Start timer")) { MenuBarController.shared?.showPopover() }.buttonStyle(.primaryPill)
                    Button(String(localized: "Add entry")) { model.addEntry(on: day) }.buttonStyle(.pill)
                }
                Text(String(localized: "Press ⌥⌘T to start tracking from anywhere.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
            } else if day > model.today {
                Illustration(name: "illNotStarted", width: 240)
                Text(String(localized: "This day hasn't started")).font(DS.F.screenTitle).accessibilityIdentifier("day.empty.title")
                Button(String(localized: "Add absence…")) { showAbsence = true }.buttonStyle(.pill).accessibilityIdentifier("day.addAbsence")
            } else if cal.fund(day) == 0 {
                Illustration(name: "illWeekend", width: 240)
                Text(cal.dayType(day) == .weekend ? String(localized: "Weekend") : Fmt.weekday(day)).font(DS.F.screenTitle)
                    .accessibilityIdentifier("day.empty.title")
                Text(String(localized: "Day off · any time counts as overtime")).foregroundStyle(DS.C.text2)
                Button(String(localized: "Add entry")) { model.addEntry(on: day) }.buttonStyle(.pill)
                    .disabled(model.lock.isLocked(day, today: model.today))
            } else {
                // Design "Main · Day · empty (past)".
                Illustration(name: "illMissed", width: 240)
                Text(String(localized: "Nothing tracked on \(Fmt.weekday(day))")).font(DS.F.screenTitle).multilineTextAlignment(.center)
                Text(String(localized: "\(DurationFormat.short(cal.fund(day))) expected still open. Forgot the timer, or were you off?"))
                    .font(DS.F.body).foregroundStyle(DS.C.text2).multilineTextAlignment(.center)
                if model.lock.isLocked(day, today: model.today) {
                    Chip(text: String(localized: "Locked — read-only"), icon: "lock.fill")
                } else {
                    HStack {
                        Button { model.addEntry(on: day) } label: { Label(String(localized: "Add entry"), systemImage: "plus") }.buttonStyle(.primaryPill)
                        Button { showAbsence = true } label: { Label(String(localized: "Add absence"), systemImage: "calendar.badge.plus") }.buttonStyle(.pill).accessibilityIdentifier("day.addAbsence")
                    }
                }
            }
            }
            .padding(.top, 20).padding(.horizontal, 28).padding(.bottom, 22)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 14).fill(DS.C.surface).shadow(color: .black.opacity(0.08), radius: 16, y: 6))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.C.border))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .surfaceSheet(isPresented: $showAbsence) {
            AbsenceForm(initialDay: day) { showAbsence = false }.padding(20).frame(width: 460).environment(model)
        }
        .surfaceSheet(item: Binding(get: { editingAbsence.map { AbsenceEdit(list: $0) } }, set: { editingAbsence = $0?.list })) { e in
            AbsenceForm(editing: e.list) { editingAbsence = nil }.padding(20).frame(width: 460).environment(model)
        }
    }

    private var nextWorkday: LocalDate {
        var d = day.adding(days: 1)
        while !model.dayCalendar.isWorkday(d) && d.days(until: day) > -30 { d = d.adding(days: 1) }
        return d
    }

    private func rangeText(_ a: Absence) -> String {
        guard let rid = a.rangeId else { return String(localized: "Whole day off") }
        let days = model.data.absences.filter { $0.rangeId == rid }.map(\.date).sorted()
        guard let f = days.first, let l = days.last, let idx = days.firstIndex(of: day) else { return "" }
        var back = l.adding(days: 1)
        while !model.dayCalendar.isWorkday(back) && back.days(until: l) > -30 { back = back.adding(days: 1) }
        return String(localized: "\(Fmt.dayMonth(f)) – \(Fmt.dayMonth(l)) · day \(idx + 1) of \(days.count) · back on \(Fmt.long(back))")
    }
}

extension AppModel {
    var selectedEntries: [TimeEntry] { data.entries.filter { selectedEntryIds.contains($0.id) }.sorted { $0.start < $1.start } }

    /// Days in the range that need you — one definition everywhere (blockers only, audit U1).
    func needYouCount(in range: DateRange) -> Int { needsYou(in: range).days.count }

    func selectAllOnDay() {
        selectedEntryIds = Set(ledger.workEntries(on: selectedDay).map(\.id))
    }

    func copyDescription(_ e: TimeEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.description, forType: .string)
        showToast(String(localized: "Description copied"))
    }

    /// M: merge the selected entry with the previous entry of the same task (or merge the selection) — only
    /// neighbours: another entry in between stops it, and each refusal says why (beta 2026-10-22).
    func mergeSelectionWithPrevious() {
        let sel = selectedEntries
        guard !sel.isEmpty, lock.canEditEntries(on: selectedDay, today: today) else { return }
        let day = ledger.workEntries(on: selectedDay)
        var group = sel
        if sel.count == 1, let e = sel.first {
            guard e.end != nil else { return showToast(Self.mergeRefusal(.running)) }
            guard let prev = day.last(where: { $0.start < e.start && $0.id != e.id && EntryOps.sameTask($0, e) }) else {
                return showToast(String(localized: "No earlier entry of this task on this day"))
            }
            group = [prev, e]
        }
        do {
            let parts = group.compactMap { g in data.entries.first { $0.id == g.id } }
            let ch = try EntryOps.merge(parts, within: day)
            let gap = EntryOps.mergeGap(parts)
            apply(ch, name: "Merge", toast: gap >= 60 ? String(localized: "Merged · +\(DurationFormat.hm(gap)) from the gap") : String(localized: "Merged"))
            selectedEntryIds = Set(ch.updated.map(\.id))
        } catch let e as EntryOpError {
            showToast(Self.mergeRefusal(e))
        } catch {}
    }

    /// Why a merge can't happen, in words (toast and the multi-select note).
    static func mergeRefusal(_ e: EntryOpError) -> String {
        switch e {
        case .running: String(localized: "A running timer can't be merged — stop it first")
        case .differentTasks: String(localized: "Different tasks can't be merged")
        case .notAdjacent: String(localized: "Another entry is in between — only neighbours merge")
        default: String(localized: "Select two or more entries of one task")
        }
    }
}

/// Floating inspector (900–1180 pt windows): a glass card on macOS 26, tinted towards the surface colour so the
/// inspector's text keeps its contrast over the timeline; the flat card with a soft shadow on macOS 14–15.
struct FloatingInspectorSurface: ViewModifier {
    func body(content: Content) -> some View {
        if LiquidGlass.isAvailable {
            content.glassSurface(RoundedRectangle(cornerRadius: DS.R.card), fill: DS.C.surface, tint: DS.C.surface.opacity(0.6))
        } else {
            content.background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface).shadow(color: .black.opacity(0.12), radius: 20, y: 8))
        }
    }
}
