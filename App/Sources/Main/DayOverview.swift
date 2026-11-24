import SwiftUI
import TikjotDomain

/// "Day overview" (owner 2026-10-14, pen "Day recap · options" B): what you did on a day, in words — the totals,
/// how the day split between tasks, and every task with all its descriptions and their times. Opened from the Day
/// inspector for the day shown behind it (no ‹ › of its own — owner: it would drift from the day below); Esc closes.
struct DayOverview: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    let close: () -> Void

    /// One task (or "No task") of the day.
    struct Item: Identifiable {
        let id: String
        let key: String
        let name: String
        let color: Color
        let seconds: Int
        let inJira: Bool
        let descriptions: [(text: String, seconds: Int)]
    }

    var body: some View {
        let l = model.ledger
        let items = items(l)
        let worked = l.worked(day)
        VStack(alignment: .leading, spacing: 20) {
            header
            metrics(l, items: items, worked: worked)
            if items.isEmpty {
                Text(String(localized: "Nothing tracked this day.")).font(DS.F.body).foregroundStyle(DS.C.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else {
                split(items)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "What you did")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                if i > 0 { Rectangle().fill(DS.C.border).frame(height: 1) }
                                row(item)
                            }
                        }
                    }
                    .frame(height: listHeight(items))
                }
            }
            absences
        }
        .padding(28)
        .frame(width: 780)
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "DAY OVERVIEW")).font(DS.F.sectionLabel).foregroundStyle(DS.C.text3)
                Text(Fmt.long(day)).font(DS.F.display(26, .bold)).foregroundStyle(DS.C.text)
            }
            Spacer()
            Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.icon)
                .keyboardShortcut(.cancelAction).help(String(localized: "Close"))
        }
    }

    private func metrics(_ l: Ledger, items: [Item], worked: Int) -> some View {
        let fund = l.fund(day)
        let balance = l.dayBalance(day)
        let absences = model.absences(on: day)
        let work = l.workEntries(on: day)
        let notSent = l.lines(on: day).filter { !$0.isNoIssue && ![.synced, .locked].contains(l.state(of: $0, lock: model.lock)) }.count
        let tasks = items.filter { !$0.key.isEmpty }.count
        var span = "–"
        if let first = work.first, let last = work.max(by: { $0.effectiveEnd(now: model.now) < $1.effectiveEnd(now: model.now) }) {
            span = Fmt.range(first.start, last.end)
        }
        var counts = String(localized: "Tasks: \(tasks)")
        if !absences.isEmpty { counts += " · " + String(localized: "Absences: \(absences.count)") }
        let away = absences.map { "\(model.absenceType($0.typeId)?.name ?? "") \(model.absenceAmount($0, on: day))" }.joined(separator: " · ")
        return HStack(spacing: 12) {
            tile(String(localized: "Worked"), DurationFormat.hm(worked), String(localized: "of \(DurationFormat.short(fund)) expected"))
            tile(String(localized: "Day balance"), DurationFormat.signed(balance), away.isEmpty ? Fmt.weekday(day) : away,
                 color: balance > 0 ? DS.C.successText : DS.C.text)
            if model.jiraConnected {
                tile(String(localized: "In Jira"), DurationFormat.hm(l.inJira(day)),
                     notSent == 0 ? (worked > 0 ? String(localized: "Everything sent") : "–") : String(localized: "\(notSent) worklogs not in Jira"))
            }
            tile(String(localized: "Your day"), span, counts)
        }
    }

    private func tile(_ label: String, _ value: String, _ sub: String, color: Color = DS.C.text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(DS.F.caption).foregroundStyle(DS.C.text2)
            Text(value).font(DS.F.number(20)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(DS.F.caption).foregroundStyle(DS.C.text3).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.C.surface2))
    }

    /// How the day split between tasks — one coloured segment per task, in list order.
    private func split(_ items: [Item]) -> some View {
        let total = max(1, items.reduce(0) { $0 + $1.seconds })
        return GeometryReader { g in
            let w = g.size.width - CGFloat(max(0, items.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(items) { item in
                    RoundedRectangle(cornerRadius: 3).fill(item.color)
                        .frame(width: max(3, w * CGFloat(item.seconds) / CGFloat(total)))
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func row(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if item.key.isEmpty {
                    NoTaskMark(size: 11).frame(width: 10)
                } else {
                    Circle().fill(item.color).frame(width: 10, height: 10).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(item.key).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(DS.F.keyColor)
                }
                Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(item.key.isEmpty ? DS.C.text2 : DS.C.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(DurationFormat.short(item.seconds)).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(DS.C.text)
                if model.jiraConnected && !item.key.isEmpty {
                    StateMark(status: item.inJira ? .allInJira : .waiting).frame(width: 16)
                }
            }
            if !item.descriptions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.descriptions, id: \.text) { d in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(d.text).font(DS.F.body).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(DurationFormat.short(d.seconds)).font(.system(size: 12, design: .monospaced)).foregroundStyle(DS.C.text3)
                        }
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, model.jiraConnected ? 24 : 0)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var absences: some View {
        let list = model.absences(on: day)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(list) { a in
                    HStack(spacing: 8) {
                        Image(systemName: model.absenceType(a.typeId)?.icon ?? "calendar").font(.system(size: 13)).foregroundStyle(DS.C.brand)
                        Text(model.absenceTitle(a, on: day)).font(DS.F.body).foregroundStyle(DS.C.text)
                        Spacer()
                        Text(model.absenceAmount(a, on: day)).font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.C.brandSoft))
        }
    }

    // MARK: Data

    /// Tasks by time (most first), "No task" last; each with its descriptions merged (case ignored) in order of the
    /// day and their raw time. Breaks don't count.
    private func items(_ l: Ledger) -> [Item] {
        let lines = l.lines(on: day)
        var out: [Item] = []
        for (ref, ls) in Dictionary(grouping: lines.filter { !$0.isNoIssue }, by: { $0.issue! }) {
            let i = model.issue(ref)
            out.append(Item(id: "\(ref.instanceId)/\(ref.issueId)", key: i?.key ?? "", name: i?.summary ?? "",
                            color: DS.project(model.project(ls.first?.projectId)?.color ?? "slate"),
                            seconds: ls.reduce(0) { $0 + $1.value },
                            inJira: ls.allSatisfy { l.state(of: $0, lock: model.lock) == .synced },
                            descriptions: Self.describe(ls.flatMap(\.entries), now: model.now)))
        }
        out.sort { ($0.seconds, $1.key) > ($1.seconds, $0.key) }
        let none = lines.filter(\.isNoIssue)
        if !none.isEmpty {
            out.append(Item(id: "no-task", key: "", name: String(localized: "No task"), color: DS.C.text3,
                            seconds: none.reduce(0) { $0 + $1.value }, inJira: false,
                            descriptions: Self.describe(none.flatMap(\.entries), now: model.now)))
        }
        return out
    }

    static func describe(_ entries: [TimeEntry], now: Date) -> [(text: String, seconds: Int)] {
        var order: [(key: String, text: String)] = []
        var seconds: [String: Int] = [:]
        for e in entries.filter({ $0.kind == .work }).sorted(by: { $0.start < $1.start }) {
            let t = e.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let k = t.lowercased()
            if seconds[k] == nil { order.append((k, t)) }
            seconds[k, default: 0] += e.duration(now: now)
        }
        return order.map { ($0.text, seconds[$0.key]!) }
    }

    /// The list scrolls past ~460 pt (a long day); shorter days take their own height.
    private func listHeight(_ items: [Item]) -> CGFloat {
        let est = items.reduce(0) { $0 + 46 + CGFloat($1.descriptions.count) * 21 } + CGFloat(max(0, items.count - 1))
        return min(460, est)
    }
}
