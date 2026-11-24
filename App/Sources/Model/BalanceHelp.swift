import Foundation
import TikjotDomain

/// The hover card on every month balance (popover footer, sidebar pill, Month toolbar): how the number comes about.
/// One fact per row; absences and holidays only when there are any. Its text is also the VoiceOver hint.
///
///     October so far
///     Expected      7 workdays × 8h − doctor 1h = 55h
///     Worked        54h 13m
///     Balance       −47m
///     Since 1 Sep   +4h 45m
///     Worked is rounded, as in Jira.
enum BalanceHelp {
    @MainActor static func content(_ b: BalanceBreakdown, month: DateRange, today: LocalDate, typeName: (UUID) -> String?) -> TooltipContent {
        let name = Fmt.monthName(month.start)
        var expr = String(localized: "\(b.workdays) workdays")
        if let perDay = b.perDay {
            expr += " × " + DurationFormat.short(perDay)
        } else if b.workdays > 0 {
            expr += " " + DurationFormat.short(b.base)
        }
        for a in b.absences {
            expr += " − " + (typeName(a.typeId)?.lowercased() ?? String(localized: "absence")) + " " + DurationFormat.short(a.seconds)
        }
        expr += " = " + DurationFormat.short(b.expected)
        if b.holidays > 0 { expr += " · " + String(localized: "\(b.holidays) holidays off") }
        var rows: [TooltipContent.Row] = [
            .init(label: String(localized: "Expected"), value: expr),
            .init(label: String(localized: "Worked"), value: DurationFormat.hm(b.worked)),
            .init(label: String(localized: "Balance"), value: DurationFormat.signed(b.balance), strong: true),
        ]
        if let s = b.since { rows.append(.init(label: String(localized: "Since \(Fmt.dayMonth(s))"), value: DurationFormat.signed(b.sinceBalance))) }
        return TooltipContent(title: month.contains(today) ? String(localized: "\(name) so far") : name, rows: rows,
                              note: String(localized: "Worked is rounded, as in Jira."))
    }
}

extension AppModel {
    /// The month balance's breakdown, with the same rules as the number next to it (`liveBalance(month, since: dataStart)`).
    func monthBalanceHelp(_ month: DateRange) -> TooltipContent {
        let b = ledger.balanceBreakdown(month: month, since: dataStart, runningSince: cumulativeStart, opening: settings.openingBalance)
        return BalanceHelp.content(b, month: month, today: today) { absenceType($0)?.name }
    }
}
