import SwiftUI
import TikjotDomain
import TikjotPersistence

/// The time fields of one card, so its Done can commit text still being typed (a click on Done doesn't take focus,
/// so the focus-loss commit never runs). `commitAll()` is false when a field holds text that isn't a time —
/// that field is marked and the card stays open.
@MainActor
final class FieldCommits {
    private var fields: [UUID: () -> Bool] = [:]
    func register(_ id: UUID, _ commit: @escaping () -> Bool) { fields[id] = commit }
    func remove(_ id: UUID) { fields[id] = nil }
    func commitAll() -> Bool {
        // Every field commits (and marks itself), not just the first bad one.
        fields.values.map { $0() }.allSatisfy { $0 }
    }
}

/// `popover/time-field`: labelled time with steppers; ↑↓ ±5 min, ⇧↑↓ ±1 min (hour absences: ±1 h / ±15 min);
/// typed 1020 / 10:20 / 10.20 accepted.
struct TimeField: View {
    let label: String
    @Binding var date: Date
    var day: LocalDate
    var readOnly = false
    /// Minutes per ↑↓ / stepper click, and per ⇧↑↓.
    var step = 5
    var fineStep = 1
    /// Settings use the quieter 13 pt mono of `field/text`; everywhere else keeps the big time.
    var font: Font = DS.F.monoBig
    var onCommit: () -> Void = {}
    /// The card's Done commits typed text through this.
    var commits: FieldCommits?
    /// ↩ with nothing new typed (the value is already in): the card's Done. So ↩ applies a typed time, a second ↩
    /// closes the card (owner 2026-10-14).
    var onReturn: (() -> Void)?
    @State private var text = ""
    /// Typed by you and not committed yet.
    @State private var dirty = false
    @State private var invalid = false
    @State private var id = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !label.isEmpty {
                Text(label.uppercased()).font(DS.F.sectionLabel).foregroundStyle(DS.C.text3)
            }
            HStack(spacing: 2) {
                if readOnly {
                    Text(Fmt.time(date)).font(font).foregroundStyle(DS.C.text2)
                    Spacer()
                } else {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(font)
                        .focused($focused)
                        .onSubmit { if dirty || onReturn == nil { commitText() } else { onReturn?() } }
                        .onKeyPress(.upArrow, phases: .down) { press in move(press.modifiers.contains(.shift) ? fineStep : step); return .handled }
                        .onKeyPress(.downArrow, phases: .down) { press in move(press.modifiers.contains(.shift) ? -fineStep : -step); return .handled }
                        .onChange(of: focused) { _, f in if !f { commitText() } }
                    Stepper("", onIncrement: { move(step) }, onDecrement: { move(-step) }).labelsHidden().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: DS.H.field)
            .background(RoundedRectangle(cornerRadius: DS.R.field).fill(readOnly ? DS.C.surface2 : DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(invalid ? DS.C.danger : (focused ? DS.C.focusRingStrong : DS.C.borderStrong),
                                                                             lineWidth: focused || invalid ? 2 : 1))
            .clickToFocus($focused)
        }
        .onAppear {
            text = Fmt.time(date)
            commits?.register(id) { commitFromCard() }
        }
        .onDisappear { commits?.remove(id) }
        .onChange(of: date) { _, d in if !focused { text = Fmt.time(d) } }
        .onChange(of: text) { _, t in
            invalid = false
            if focused && t != Fmt.time(date) { dirty = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Fmt.time(date))")
    }

    private func move(_ minutes: Int) {
        let new = date.addingTimeInterval(TimeInterval(minutes * 60))
        date = new
        show(Fmt.time(new))
        dirty = false
        onCommit()
    }

    /// The new value into the focused field. Set again on the next turn: a change made while the field editor is
    /// handling the key showed one step late (↑ on 1h stayed "1h" with 2h already applied — owner 2026-10-13).
    private func show(_ value: String) {
        text = value
        DispatchQueue.main.async { if !dirty { text = value } }
    }

    /// ↩ / focus leaves: apply a time, put back the current one for anything else.
    private func commitText() {
        dirty = false
        if case .set(let new) = TypedField.time(text, current: date, day: day, calendar: Calendar.current) { date = new; onCommit() }
        text = Fmt.time(date)
    }

    /// The card's Done: typed text applies; text that isn't a time stays and is marked.
    private func commitFromCard() -> Bool {
        guard dirty else { return true }
        switch TypedField.time(text, current: date, day: day, calendar: Calendar.current) {
        case .invalid: invalid = true; return false
        case .set(let new): date = new; onCommit()
        case .keep: break
        }
        dirty = false
        text = Fmt.time(date)
        return true
    }
}

/// LENGTH: duration with steppers (typed "1h 30m", "90m", "1:30"). Also the contract's hours per day (30 min steps).
struct LengthField: View {
    let label: String
    @Binding var seconds: Int
    var readOnly = false
    var step = 300
    /// Seconds per ⇧↑↓ (nil: same as ↑↓).
    var fineStep: Int?
    var range: ClosedRange<Int> = 60...Int.max
    var font: Font = DS.F.monoBig
    var onCommit: () -> Void = {}
    /// The card's Done commits typed text through this.
    var commits: FieldCommits?
    /// ↩ with nothing new typed (the value is already in): the card's Done. So ↩ applies a typed time, a second ↩
    /// closes the card (owner 2026-10-14).
    var onReturn: (() -> Void)?
    @State private var text = ""
    /// Typed by you and not committed yet.
    @State private var dirty = false
    @State private var invalid = false
    @State private var id = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !label.isEmpty {
                Text(label.uppercased()).font(DS.F.sectionLabel).foregroundStyle(DS.C.text3)
            }
            HStack(spacing: 2) {
                if readOnly {
                    Text(DurationFormat.hm(seconds)).font(font).foregroundStyle(DS.C.text2)
                    Spacer()
                } else {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(font)
                        .focused($focused)
                        .onSubmit { if dirty || onReturn == nil { commit() } else { onReturn?() } }
                        .onChange(of: focused) { _, f in if !f { commit() } }
                        .onKeyPress(.upArrow, phases: .down) { press in nudge(press.modifiers.contains(.shift) ? fineStep ?? step : step); return .handled }
                        .onKeyPress(.downArrow, phases: .down) { press in nudge(-(press.modifiers.contains(.shift) ? fineStep ?? step : step)); return .handled }
                    Stepper("", onIncrement: { nudge(step) }, onDecrement: { nudge(-step) })
                        .labelsHidden().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: DS.H.field)
            .background(RoundedRectangle(cornerRadius: DS.R.field).fill(readOnly ? DS.C.surface2 : DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(invalid ? DS.C.danger : (focused ? DS.C.focusRingStrong : DS.C.borderStrong),
                                                                             lineWidth: focused || invalid ? 2 : 1))
            .clickToFocus($focused)
        }
        .onAppear {
            text = DurationFormat.short(seconds)
            commits?.register(id) { commitFromCard() }
        }
        .onDisappear { commits?.remove(id) }
        .onChange(of: seconds) { _, s in if !focused { text = DurationFormat.short(s) } }
        .onChange(of: text) { _, t in
            invalid = false
            if focused && t != DurationFormat.short(seconds) { dirty = true }
        }
    }

    private func nudge(_ delta: Int) {
        let new = min(max(seconds + delta, range.lowerBound), range.upperBound)
        seconds = new
        show(DurationFormat.short(new))
        dirty = false
        onCommit()
    }

    /// See TimeField.show: set again on the next turn, or the focused field shows one step late.
    private func show(_ value: String) {
        text = value
        DispatchQueue.main.async { if !dirty { text = value } }
    }

    /// ↩ / focus leaves: apply a length, put back the current one for anything else.
    private func commit() {
        dirty = false
        if case .set(let s) = TypedField.length(text, current: seconds, range: range) { seconds = s; onCommit() }
        text = DurationFormat.short(seconds)
    }

    /// The card's Done: typed text applies; text that isn't a length stays and is marked.
    private func commitFromCard() -> Bool {
        guard dirty else { return true }
        switch TypedField.length(text, current: seconds, range: range) {
        case .invalid: invalid = true; return false
        case .set(let s): seconds = s; onCommit()
        case .keep: break
        }
        dirty = false
        text = DurationFormat.short(seconds)
        return true
    }
}

/// Overlap choices (§11.1 R4): radio rows with their consequence, Keep both is the default and never blocks.
struct OverlapChoices: View {
    enum Choice: Hashable { case keepBoth, trimThis, moveOther }
    let other: TimeEntry
    let otherTitle: String
    let overlap: Seconds
    let thisEnd: Date
    @Binding var choice: Choice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(DS.C.warning).font(.system(size: 11))
                Text(String(localized: "Overlaps “\(otherTitle)” (\(Fmt.range(other.start, other.end))) by \(DurationFormat.short(overlap)) — counts twice."))
                    .font(DS.F.caption).foregroundStyle(DS.C.text)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(DS.C.warningSoft))
            radio(.keepBoth, String(localized: "Keep both"), String(localized: "both stay, side by side in the main window"))
            radio(.trimThis, String(localized: "End this at \(Fmt.time(other.start))"), String(localized: "right before \(otherTitle)"))
            radio(.moveOther, String(localized: "Move \(otherTitle) to \(Fmt.time(thisEnd))"),
                  String(localized: "\(otherTitle) becomes \(Fmt.range(thisEnd, other.end.map { $0.addingTimeInterval(thisEnd.timeIntervalSince(other.start)) }))"))
        }
    }

    private func radio(_ c: Choice, _ title: String, _ sub: String) -> some View {
        Button { choice = c } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: choice == c ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == c ? DS.C.brand : DS.C.borderStrong).font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.F.bodyMedium).foregroundStyle(DS.C.text)
                    Text(sub).font(DS.F.caption).foregroundStyle(choice == c ? DS.C.text2 : DS.C.text3)   // text3 on brand-soft < 4.5:1
                }
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(choice == c ? DS.C.brandSoft.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }
}
