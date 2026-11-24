import SwiftUI
import TikjotDomain

/// Friday recap (§11.11): after the last send of the week (or Friday 16:00) — "Week 40 is in Jira",
/// sent total, day bars, and the one thing left. Nothing for an empty week.
struct FridayRecap: View {
    @Environment(AppModel.self) private var model
    let week: DateRange
    @AppStorage("recapDismissed") private var dismissed = ""

    static func shouldShow(_ m: AppModel, week: DateRange) -> Bool {
        // Only for a week tikjot knows from its first day (history imported / tracked since then).
        guard week.contains(m.today), week.start >= m.dataStart, m.ledger.worked(week) > 0 else { return false }
        let minutes = Calendar.current.component(.hour, from: m.now) * 60 + Calendar.current.component(.minute, from: m.now)
        let past = DateRange(week.start, m.today)
        let allSent = m.jiraConnected && !past.contains { [.waiting, .failed, .conflict].contains(m.ledger.dayStatus($0, lock: m.lock)) }
        return m.today.isoWeekday >= 5 && (minutes >= 16 * 60 || allSent) || m.today.isoWeekday > 5
    }

    var body: some View {
        let l = model.ledger
        let past = DateRange(week.start, min(week.end, model.today))
        let allSent = model.jiraConnected && !past.contains { [.waiting, .failed, .conflict, .missed].contains(l.dayStatus($0, lock: model.lock)) }
        let missed = past.filter { l.dayStatus($0, lock: model.lock) == .missed }
        let key = "W\(week.start.weekNumber)-\(week.start.year)"
        if dismissed != key {
            HStack(alignment: .center, spacing: 18) {
                Illustration(name: "illWeekDone", width: 150)
                VStack(alignment: .leading, spacing: 8) {
                    Text(allSent ? String(localized: "Week \(week.start.weekNumber) is in Jira") : String(localized: "Week \(week.start.weekNumber) so far"))
                        .font(DS.F.screenTitle)
                    Text(allSent ? String(localized: "Sent \(DurationFormat.hm(l.inJira(week))) · worked \(DurationFormat.hm(l.worked(week))) of \(DurationFormat.short(l.fund(week)))")
                         : String(localized: "Worked \(DurationFormat.hm(l.worked(week))) of \(DurationFormat.short(l.fund(week))) · in Jira \(DurationFormat.hm(l.inJira(week)))"))
                        .font(DS.F.body).foregroundStyle(DS.C.text2)
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(week.prefix(7)), id: \.self) { d in
                            let w = Double(l.worked(d)), f = Double(max(l.fund(d), 1))
                            VStack(spacing: 3) {
                                Capsule().fill(l.fund(d) == 0 && w == 0 ? DS.C.surface2 : (w >= f ? DS.C.brand : DS.C.brand.opacity(0.4)))
                                    .frame(width: 18, height: max(4, CGFloat(min(1.3, w / f)) * 40))
                                Text(Fmt.weekdayShort(d).prefix(2)).font(.system(size: 9)).foregroundStyle(DS.C.text3)
                            }
                        }
                    }
                    if let m = missed.first {
                        HStack {
                            Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(DS.C.warning)
                            Text(String(localized: "\(Fmt.weekday(m)) \(m.day) is still empty")).font(DS.F.bodyMedium)
                            Button(String(localized: "Add absence…")) { model.absenceDraftDays = [m]; model.selectedDay = m; model.mainSelection = .day }
                                .buttonStyle(.pill(.secondary, height: DS.H.small))
                        }
                    } else if !allSent && model.jiraConnected {
                        Button(String(localized: "Review & send the week")) {
                            model.requestReview(days: Array(week), title: String(localized: "Send week \(week.start.weekNumber) to Jira"))
                        }.buttonStyle(.primaryPill)
                    }
                }
                Spacer()
                Button { dismissed = key } label: { Image(systemName: "xmark").foregroundStyle(DS.C.text3) }.buttonStyle(.icon)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(allSent ? DS.C.successSoft : DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
        }
    }
}
