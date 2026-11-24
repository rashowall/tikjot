import SwiftUI
import TikjotDomain
import TikjotPersistence

/// Absence sheet (§11.8 "Absence sheet"): type → one day | date range → length → live effect on the fund.
/// Same form in the popover and the main window; in edit mode it shortens a range or removes it.
struct AbsenceForm: View {
    @Environment(AppModel.self) private var model
    var compact = false
    var editing: [Absence] = []
    /// The day the form opens on (the Day / Week it was opened from). Passed in rather than set in the caller's
    /// `.onAppear`: the form's own `.onAppear` runs first, so it would read the previous day.
    var initialDay: LocalDate?
    let done: () -> Void

    enum Kind: Hashable { case vacation, doctor, sick, child, other }

    @State private var kind: Kind = .vacation
    @State private var range = false
    @State private var day = LocalDate(year: 2026, month: 1, day: 1)
    @State private var until = LocalDate(year: 2026, month: 1, day: 1)
    @State private var half = false
    @State private var fromMinutes = 9 * 60
    @State private var seconds = 3600
    @State private var otherTypeId: UUID?
    @State private var newTypeName = ""
    @State private var newTypeUnit: AbsenceUnit = .day
    @State private var addingType = false
    @State private var note = ""
    @State private var keptDays: Set<LocalDate> = []
    @State private var loaded = false

    private var isEdit: Bool { !editing.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !isEdit {
                HStack(spacing: 6) {
                    typeButton(.vacation, String(localized: "Vacation"), "sun.horizon")
                    typeButton(.doctor, String(localized: "Doctor"), "stethoscope")
                    typeButton(.sick, String(localized: "Sick leave"), "thermometer.medium")
                    typeButton(.child, String(localized: "Child care"), "figure.and.child.holdinghands")
                    typeButton(.other, String(localized: "Other"), "ellipsis")
                }
            }
            if kind == .other && !isEdit { otherPicker }
            if isEdit && editing.count > 1 {
                editRangeRows
            } else {
                fields
            }
            effectCard
            HStack(spacing: 8) {
                if isEdit {
                    Button(role: .destructive) {
                        model.removeAbsences(editing)
                        done()
                    } label: { Label(String(localized: "Remove \(typeName.lowercased())"), systemImage: "trash").font(DS.F.bodyMedium) }
                    .buttonStyle(LinkButtonStyle(color: DS.C.dangerText))
                    .accessibilityIdentifier("absence.remove")
                }
                Spacer()
                Button(String(localized: "Cancel")) { done() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button(action: save) {
                    Label(isEdit ? String(localized: "Save changes") : String(localized: "Add absence"), systemImage: "checkmark")
                }
                .buttonStyle(.primaryPill)
                .disabled(!valid)
                .accessibilityIdentifier("absence.save")
            }
        }
        .onAppear {
            load()
            if DebugUI.wants("absenceDoctor") { kind = .doctor }
            if DebugUI.wants("absenceRange") { range = true }
        }
        // The app's surface, not the sheet's default grey — on it tiles and segments got lost in dark mode.
        .presentationBackground(DS.C.surface)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(isEdit ? String(localized: "Edit \(typeName.lowercased())") : String(localized: "Add absence"))
                .font(.system(size: 15, weight: .bold)).foregroundStyle(DS.C.text)
            Text(subtitle).font(DS.F.caption).foregroundStyle(DS.C.text2)
        }
    }

    private var subtitle: String {
        guard let first = editing.first else { return String(localized: "Lowers your expected hours · never sent to Jira") }
        let dates = editing.map(\.date).sorted()
        var parts = [dates.count > 1 ? spanText(dates.first!, dates.last!) : Fmt.short(first.date)]
        if dates.count > 1 {
            parts.append(String(localized: "\(dates.filter { model.dayCalendar.isWorkday($0) }.count) working days"))
        }
        parts.append(String(localized: "added \(Fmt.dayMonth(LocalDate(first.createdAt, calendar: .current)))"))
        return parts.joined(separator: " · ")
    }

    private func spanText(_ a: LocalDate, _ b: LocalDate) -> String {
        if a.year == b.year && a.month == b.month { return "\(Fmt.weekdayShort(a)) \(a.day) – \(Fmt.short(b))" }
        return "\(Fmt.short(a)) – \(Fmt.short(b))"
    }

    private func typeButton(_ k: Kind, _ title: String, _ icon: String) -> some View {
        Button { kind = k; if k == .sick || k == .child { range = true } } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14)).frame(height: 16)
                    .foregroundStyle(kind == k ? DS.C.brand : DS.C.text2)
                Text(title).font(.system(size: 11, weight: kind == k ? .bold : .medium)).foregroundStyle(DS.C.text)
                    .lineLimit(1).fixedSize()
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(kind == k ? DS.C.brandSoft : DS.C.surface2))
            .overlay(RoundedRectangle(cornerRadius: DS.R.row).strokeBorder(kind == k ? DS.C.brand : DS.C.border, lineWidth: kind == k ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.field)
        .accessibilityIdentifier("absence.type.\(String(describing: k))")
        .accessibilityAddTraits(kind == k ? .isSelected : [])
    }

    /// A design form row: label on the left, control on the right.
    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(DS.F.bodySemibold).foregroundStyle(DS.C.text).lineLimit(1)
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 28)
    }

    private var otherPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            let customs = model.data.absenceTypes.filter { $0.builtin == nil && !$0.archived }
            if !customs.isEmpty && !addingType {
                row(String(localized: "Type")) {
                    HStack(spacing: 8) {
                        Picker(String(localized: "Type"), selection: $otherTypeId) {
                            ForEach(customs) { t in Label(t.name, systemImage: t.icon).tag(Optional(t.id)) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                        Button(String(localized: "New type…")) { addingType = true }.buttonStyle(LinkButtonStyle()).font(DS.F.caption)
                    }
                }
            }
            if addingType || customs.isEmpty {
                HStack(spacing: 8) {
                    TextField(String(localized: "New type, e.g. Blood donation"), text: $newTypeName).textFieldStyle(.plain).fieldStyle()
                    PillSegmented(selection: $newTypeUnit, options: [(AbsenceUnit.day, String(localized: "Days")), (AbsenceUnit.hours, String(localized: "Hours"))], compact: true)
                }
            }
        }
    }

    private var unit: AbsenceUnit {
        switch kind {
        case .vacation: return half ? .halfDay : .day
        case .doctor: return .hours
        case .sick, .child: return .day
        case .other:
            if addingType || otherTypeId == nil { return newTypeUnit }
            return model.absenceType(otherTypeId!)?.unit ?? .day
        }
    }

    @ViewBuilder
    private var fields: some View {
        let ranged = range && unit != .hours
        if !isEdit && unit != .hours {
            row(typeName) {
                PillSegmented(selection: $range, options: [(false, String(localized: "One day")), (true, String(localized: "Date range"))], compact: true)
            }
        }
        if ranged {
            row(String(localized: "From – until")) {
                HStack(spacing: 6) {
                    DateField(day: Binding(get: { day }, set: { day = $0; if until < $0 { until = $0 } }), label: String(localized: "From"))
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(DS.C.text3)
                    DateField(day: Binding(get: { until }, set: { until = max($0, day) }), label: String(localized: "Until"))
                }
            }
        } else {
            row(String(localized: "Day")) { DateField(day: $day, label: String(localized: "Day")) }
        }
        if unit == .hours {
            row(String(localized: "Time")) {
                HStack(spacing: 6) {
                    TimeField(label: "", date: Binding(get: { day.at(minutes: fromMinutes, in: .current) },
                                                       set: { fromMinutes = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) }),
                              day: day, step: 60, fineStep: 15, font: DS.F.monoMedium)
                        .frame(width: 84)
                        .accessibilityLabel(String(localized: "From"))
                    Text(String(localized: "for")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                    LengthField(label: "", seconds: $seconds, step: 3600, fineStep: 900, range: 3600...24 * 3600, font: DS.F.monoMedium).frame(width: 84)
                        .accessibilityLabel(String(localized: "How long"))
                }
            }
            HStack(spacing: 6) {
                Spacer()
                ForEach([3600, 2 * 3600, 4 * 3600], id: \.self) { s in
                    lengthPreset(DurationFormat.short(s), seconds: s)
                }
                if let rest = restOfDay { lengthPreset(String(localized: "Rest of the day"), seconds: rest) }
            }
        } else if kind == .vacation && !ranged {
            row(String(localized: "Length")) {
                PillSegmented(selection: $half, options: [(false, String(localized: "Full day")), (true, String(localized: "Half day"))], compact: true)
            }
        }
    }

    /// From the start time to the end of the working day (the doctor in the afternoon), when that's at least the 1 h minimum.
    private var restOfDay: Int? {
        let end = model.schedule.period(on: day).workdayEnd
        return end - fromMinutes >= 60 ? (end - fromMinutes) * 60 : nil
    }

    /// Hour absences: the usual lengths in one click (↑↓ in the field steps by an hour, ⇧↑↓ by 15 min).
    private func lengthPreset(_ title: String, seconds s: Int) -> some View {
        let on = seconds == s
        return Button { seconds = s } label: {
            Text(title)
                .font(DS.F.captionMedium)
                .padding(.horizontal, 9).frame(height: 24)
                .foregroundStyle(on ? DS.C.brandText : DS.C.text2)
                .background(Capsule().fill(on ? DS.C.brandSoft : DS.C.surface))
                .overlay(Capsule().strokeBorder(on ? DS.C.brand : DS.C.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.chip)
    }

    /// Edit a range: the span, then day chips — click one to take it out (click again to keep it).
    private var editRangeRows: some View {
        let dates = editing.map(\.date).sorted()
        return VStack(alignment: .leading, spacing: 14) {
            row(String(localized: "From – until")) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(DS.C.text2)
                    Text(spanText(dates.first!, dates.last!)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(DS.C.surface2))
            }
            HStack(alignment: .top, spacing: 8) {
                Text(String(localized: "Days")).font(DS.F.bodySemibold).foregroundStyle(DS.C.text).frame(height: 24)
                FlowChips(items: dates) { d in
                    let kept = keptDays.contains(d)
                    Button { if kept { keptDays.remove(d) } else { keptDays.insert(d) } } label: {
                        HStack(spacing: 4) {
                            Text("\(Fmt.weekdayShort(d)) \(d.day)").strikethrough(!kept)
                            if !kept { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        }
                        .font(DS.F.captionMedium)
                        .padding(.horizontal, 9).frame(height: 24)
                        .foregroundStyle(kept ? DS.C.brandText : DS.C.text2)
                        .background(Capsule().fill(kept ? DS.C.brandSoft : DS.C.surface))
                        .overlay(Capsule().strokeBorder(kept ? DS.C.brand : DS.C.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.chip)
                    .help(String(localized: "Click a day to take it out of the range."))
                }
            }
        }
    }

    // MARK: Effect

    private var days: [LocalDate] {
        if isEdit && editing.count > 1 { return Array(keptDays).sorted() }
        if range && unit != .hours { return Array(DateRange(day, max(day, until))) }
        return [day]
    }

    private var effectCard: some View {
        let cal = model.dayCalendar
        let ds = days
        let workdays = ds.count > 1 ? ds.filter { cal.isWorkday($0) } : ds
        let holidays = ds.filter { cal.holidays[$0] != nil }
        let before = workdays.reduce(0) { $0 + cal.fund($1) }
        let after: Int = {
            var c = cal
            let fake = workdays.map { Absence(typeId: UUID(), date: $0, unit: unit, amountSeconds: seconds) }
            let existingIds = Set(editing.map(\.id))
            c = DayCalendar(schedule: model.schedule, holidays: model.holidays, customDays: model.data.customDays,
                            absences: model.data.absences.filter { !existingIds.contains($0.id) } + fake)
            return workdays.reduce(0) { $0 + c.fund($1) }
        }()
        let line: String
        var detail: [String] = []
        if workdays.count == 1, let d = workdays.first {
            line = String(localized: "\(Fmt.short(d)) · expected \(DurationFormat.short(before)) → \(DurationFormat.short(after))")
            if before == 0 {
                detail.append(String(localized: "Not a working day · nothing changes."))
            } else if unit == .halfDay {
                detail.append(String(localized: "Half of your \(DurationFormat.short(before)) day."))
            } else if unit == .hours {
                detail.append(String(localized: "\(DurationFormat.hm(min(seconds, before))) off your \(DurationFormat.short(before)) day."))
            } else {
                detail.append(String(localized: "Whole day · the day no longer needs you."))
            }
            if d == model.today {
                detail.append(String(localized: "\(DurationFormat.hm(max(0, after - model.ledger.worked(d)))) to go"))
            }
        } else {
            line = String(localized: "\(workdays.count) working days · expected \(DurationFormat.short(before)) → \(DurationFormat.short(after))")
            if let a = ds.first, let b = ds.last, !(isEdit && editing.count > 1) { detail.append(spanText(a, b)) }
        }
        if !holidays.isEmpty { detail.append(String(localized: "holidays inside: \(holidays.map { Fmt.short($0) }.joined(separator: ", "))")) }
        if isEdit && editing.count > 1 {
            let dropped = editing.map(\.date).filter { !keptDays.contains($0) }.sorted()
            if !dropped.isEmpty {
                detail.append(String(localized: "\(dropped.map { Fmt.short($0) }.joined(separator: ", ")) becomes an ordinary workday again — it shows as a missed day until you track it or add another absence."))
            }
        }
        return HStack(spacing: 10) {
            Image(systemName: "scalemass").font(.system(size: 13)).foregroundStyle(DS.C.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(line).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(DS.C.text)
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: DS.R.row).fill(DS.C.surface2))
        .overlay(RoundedRectangle(cornerRadius: DS.R.row).strokeBorder(DS.C.border))
    }

    private var typeName: String {
        switch kind {
        case .vacation: return AppModel.builtinName(.vacation)
        case .doctor: return AppModel.builtinName(.doctor)
        case .sick: return AppModel.builtinName(.sickLeave)
        case .child: return AppModel.builtinName(.childCare)
        case .other: return otherTypeId.flatMap { model.absenceType($0)?.name } ?? (newTypeName.isEmpty ? String(localized: "Absence") : newTypeName)
        }
    }

    private var valid: Bool {
        if !model.lock.canEditAbsences(on: day, today: model.today) { return false }
        if kind == .other && !isEdit && otherTypeId == nil && newTypeName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if unit == .hours && seconds <= 0 { return false }
        return !days.isEmpty
    }

    // MARK: Load / save

    private func load() {
        guard !loaded else { return }
        loaded = true
        day = model.absenceDraftDays.first ?? initialDay ?? model.today
        until = model.absenceDraftDays.last ?? day
        if model.absenceDraftDays.count > 1 { range = true }
        model.absenceDraftDays = []
        fromMinutes = Calendar.current.component(.hour, from: model.now) * 60
        fromMinutes -= fromMinutes % 60
        if let first = editing.first, let t = model.absenceType(first.typeId) {
            switch t.builtin {
            case .vacation: kind = .vacation
            case .doctor: kind = .doctor
            case .sickLeave: kind = .sick
            case .childCare: kind = .child
            case nil: kind = .other; otherTypeId = t.id
            }
            day = first.date
            half = first.unit == .halfDay
            seconds = first.amountSeconds
            fromMinutes = first.startMinutes ?? fromMinutes
            note = first.note
            keptDays = Set(editing.map(\.date))
            range = editing.count > 1
        }
    }

    private func save() {
        if isEdit {
            if editing.count > 1 {
                model.removeAbsences(editing.filter { !keptDays.contains($0.date) })
            } else if var a = editing.first {
                a.date = day
                a.unit = unit
                a.amountSeconds = unit == .hours ? seconds : 0
                a.startMinutes = unit == .hours ? fromMinutes : nil
                a.note = note
                model.updateAbsence(a)
            }
            done()
            return
        }
        let type: AbsenceType
        switch kind {
        case .vacation: type = model.absenceType(AbsenceType.vacation.id) ?? .vacation
        case .doctor: type = model.absenceType(AbsenceType.doctor.id) ?? .doctor
        case .sick: type = model.absenceType(AbsenceType.sickLeave.id) ?? .sickLeave
        case .child: type = model.absenceType(AbsenceType.childCare.id) ?? .childCare
        case .other:
            if let id = otherTypeId, !addingType, let t = model.absenceType(id) { type = t } else {
                let t = AbsenceType(name: newTypeName.trimmingCharacters(in: .whitespaces), unit: newTypeUnit, icon: "calendar.badge.clock")
                var c = Changes()
                c.upsertAbsenceTypes = [t]
                model.applySilently(c)
                type = t
            }
        }
        model.addAbsence(type: type, days: days, unit: unit, seconds: unit == .hours ? seconds : 0,
                         startMinutes: unit == .hours ? fromMinutes : nil, note: note)
        done()
    }
}

/// Simple wrapping layout for chips.
struct FlowChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            w = max(w, x)
        }
        return CGSize(width: min(maxW, w), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
