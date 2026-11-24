import SwiftUI
import TikjotDomain

/// The design's calendar (Statistics · filter period): one month grid, Monday first; the range is a soft brand band
/// with filled ends, weekends quieter, today ringed in coral. `pick` gets the clicked day.
struct MonthGrid: View {
    @Environment(AppModel.self) private var model
    let month: LocalDate   // any day of the month
    let range: DateRange?
    var cell: CGFloat = 34
    let pick: (LocalDate) -> Void

    var body: some View {
        let first = month.firstOfMonth
        let lead = first.isoWeekday - 1
        let days = (0..<first.daysInMonth).map { first.adding(days: $0) }
        let weeks = Int(ceil(Double(lead + days.count) / 7))
        VStack(spacing: 4) {
            Text(Fmt.monthYear(first)).font(DS.F.bodySemibold).frame(height: 22)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(Self.weekdayLetters[i]).font(DS.F.caption).foregroundStyle(DS.C.text2).frame(width: cell)
                }
            }
            ForEach(0..<weeks, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        let k = w * 7 + i - lead
                        if k >= 0 && k < days.count { day(days[k], col: i) } else { Color.clear.frame(width: cell, height: cell) }
                    }
                }
            }
        }
    }

    private static var weekdayLetters: [String] {
        // Monday first, two letters, in the app's language.
        var c = Calendar.current
        c.locale = Locale.current
        let s = c.shortStandaloneWeekdaySymbols   // Sunday first
        return (1...7).map { String(s[$0 % 7].prefix(2)).capitalizedFirst }
    }

    @ViewBuilder
    private func day(_ d: LocalDate, col: Int) -> some View {
        let inRange = range.map { d >= $0.start && d <= $0.end } ?? false
        let isStart = range?.start == d, isEnd = range?.end == d
        let weekend = !model.dayCalendar.isWorkday(d)
        let today = d == model.today
        Button { pick(d) } label: {
            ZStack {
                if inRange {
                    // The band: rounded at the range ends and at the row's ends.
                    UnevenRoundedRectangle(topLeadingRadius: isStart || col == 0 ? cell / 2 : 0, bottomLeadingRadius: isStart || col == 0 ? cell / 2 : 0,
                                           bottomTrailingRadius: isEnd || col == 6 ? cell / 2 : 0, topTrailingRadius: isEnd || col == 6 ? cell / 2 : 0)
                        .fill(DS.C.brandSoft)
                }
                if isStart || isEnd { Circle().fill(DS.C.brand).padding(3) }
                if today && !(isStart || isEnd) { Circle().strokeBorder(DS.C.tick, lineWidth: 1.5).padding(3) }
                Text("\(d.day)")
                    .font(.system(size: 13, weight: isStart || isEnd ? .semibold : .regular))
                    .foregroundStyle(isStart || isEnd ? DS.C.onBrand : (weekend ? DS.C.text3 : DS.C.text))
            }
            .frame(width: cell, height: cell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A boxed date field (FROM / TO) as in the design; `active` = the next click in the calendar sets it.
struct DateBox: View {
    let label: String
    let date: LocalDate
    let active: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(DS.C.text2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text2)
                    Text("\(Fmt.weekdayShort(date)) \(Fmt.dayMonthYear(date))").font(DS.F.mono).foregroundStyle(DS.C.text)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(active ? DS.C.brand : DS.C.borderStrong, lineWidth: active ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The design's compact date field ("Mon 28 Sep" with a calendar icon, brand outline) that opens a `MonthGrid`
/// in a popover. With `until` it picks a range: the first click sets the start, the second the end.
struct DateField: View {
    @Environment(AppModel.self) private var model
    @Binding var day: LocalDate
    var until: Binding<LocalDate>?
    var label = ""
    @State private var open = false
    @State private var shown = LocalDate(year: 2026, month: 1, day: 1)
    @State private var pickingEnd = false

    var body: some View {
        Button { shown = day.firstOfMonth; pickingEnd = false; open = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(DS.C.text2)
                Text(text).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DS.C.brand, lineWidth: open ? 2 : 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(text)")
        .surfacePopover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                ZStack(alignment: .top) {
                    MonthGrid(month: shown, range: DateRange(day, end), cell: 30) { pick($0) }
                    HStack {
                        Button { shown = shown.adding(months: -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.icon)
                        Spacer()
                        Button { shown = shown.adding(months: 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.icon)
                    }
                }
                if until != nil {
                    Text(pickingEnd ? String(localized: "Now click the last day") : String(localized: "Click the first day"))
                        .font(DS.F.caption).foregroundStyle(DS.C.text3)
                }
            }
            .padding(12)
            .environment(model)
            .presentationBackground(DS.C.surface)
        }
    }

    private var end: LocalDate { max(day, until?.wrappedValue ?? day) }

    private var text: String {
        guard until != nil, end != day else { return Fmt.short(day) }
        if day.year == end.year && day.month == end.month { return "\(Fmt.weekdayShort(day)) \(day.day) – \(Fmt.short(end))" }
        return "\(Fmt.short(day)) – \(Fmt.short(end))"
    }

    private func pick(_ d: LocalDate) {
        guard let until else { day = d; open = false; return }
        if !pickingEnd {
            day = d; until.wrappedValue = d; pickingEnd = true
        } else {
            if d < day { until.wrappedValue = day; day = d } else { until.wrappedValue = d }
            open = false
        }
    }
}
