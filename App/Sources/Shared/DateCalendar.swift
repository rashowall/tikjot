import SwiftUI
import TikjotDomain

/// Month title + ‹ › + Today — the head of every one-day calendar (Day picker W9Wl9, `calendar/date`).
struct CalendarHead: View {
    @Binding var month: LocalDate
    let today: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(Fmt.monthYear(month)).font(DS.F.display(15, .bold)).foregroundStyle(DS.C.text).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Button { month = month.adding(months: -1) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .buttonStyle(.icon).foregroundStyle(DS.C.text2)
                .accessibilityLabel(String(localized: "Previous"))
            Button { month = month.adding(months: 1) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .buttonStyle(.icon).foregroundStyle(DS.C.text2)
                .accessibilityLabel(String(localized: "Next"))
            Button(action: today) {
                Text(String(localized: "Today")).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize().padding(.horizontal, 8).frame(height: 30)
            }
            .buttonStyle(LinkButtonStyle())
        }
    }
}

/// One day of a calendar month: today ringed in coral, the picked / focused day outlined in brand, weekends and
/// holidays quieter, the next month's first days tertiary, the month's leading days empty, days out of range faded.
struct CalendarDayCell: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    let month: LocalDate
    let outlined: Bool
    var enabled = true
    var dot = false
    var height: CGFloat = 40
    let pick: (LocalDate) -> Void

    var body: some View {
        let inMonth = day.month == month.month
        let leading = day < month.firstOfMonth
        let color = !inMonth ? DS.C.text3 : (model.dayCalendar.isWorkday(day) ? DS.C.text : DS.C.text2)
        Button { pick(day) } label: {
            VStack(spacing: 3) {
                Text("\(day.day)").font(.system(size: 13, weight: day == model.today ? .bold : .medium)).foregroundStyle(color)
                    .frame(width: 26, height: 22)
                    .overlay { if day == model.today { RoundedRectangle(cornerRadius: 11).strokeBorder(DS.C.tick, lineWidth: 1.5) } }
                if height > 36 { Circle().fill(DS.C.warning).frame(width: 5, height: 5).opacity(dot ? 1 : 0) }
            }
            .frame(width: 36, height: height)
            .overlay { if outlined && inMonth { RoundedRectangle(cornerRadius: 8).strokeBorder(DS.C.brand, lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
        // Days of the month before stay empty (design); the next month's first days show, quieter.
        .opacity(leading ? 0 : (enabled ? 1 : 0.45))
        .disabled(leading || !enabled)
        .accessibilityLabel(Fmt.long(day))
    }
}

/// Design `calendar/date` (Settings · Jira · import from · calendar): the calendar of every date field — the Day
/// picker's look without what belongs to day navigation (week numbers, needs-you dots, legend, hover card).
/// Days outside `range` are faded and can't be picked. Arrows move the outlined day, Return picks it.
struct DateCalendar: View {
    @Environment(AppModel.self) private var model
    let range: ClosedRange<LocalDate>?
    let pick: (LocalDate) -> Void
    @State private var month: LocalDate
    @State private var cursor: LocalDate
    @FocusState private var focused: Bool

    init(selected: LocalDate, range: ClosedRange<LocalDate>? = nil, pick: @escaping (LocalDate) -> Void) {
        self.range = range
        self.pick = pick
        _month = State(initialValue: selected.firstOfMonth)
        _cursor = State(initialValue: selected)
    }

    var body: some View {
        let first = month.firstOfMonth.startOfWeek
        VStack(alignment: .leading, spacing: 8) {
            CalendarHead(month: $month) { if allowed(model.today) { pick(model.today) } else { month = model.today.firstOfMonth } }
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<7) { i in
                        Text(Fmt.weekdayShort(first.adding(days: i)).prefix(2)).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.C.text3).frame(width: 36)
                    }
                }
                .padding(.bottom, 4)
                ForEach(0..<6) { w in
                    let wk = first.adding(days: w * 7)
                    if wk <= month.lastOfMonth {
                        GridRow {
                            ForEach(0..<7) { i in
                                let d = wk.adding(days: i)
                                CalendarDayCell(day: d, month: month, outlined: d == cursor, enabled: allowed(d), height: 36, pick: pick)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 276)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-7) }
        .onKeyPress(.downArrow) { move(7) }
        .onKeyPress(.return) {
            guard allowed(cursor) else { return .ignored }
            pick(cursor)
            return .handled
        }
    }

    private func allowed(_ d: LocalDate) -> Bool { range?.contains(d) ?? true }

    private func move(_ days: Int) -> KeyPress.Result {
        let d = cursor.adding(days: days)
        guard allowed(d) else { return .handled }
        cursor = d
        month = d.firstOfMonth
        return .handled
    }
}
