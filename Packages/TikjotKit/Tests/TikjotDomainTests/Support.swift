import Foundation
@testable import TikjotDomain

let bratislava: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Bratislava")!
    return c
}()

func d(_ s: String) -> LocalDate { LocalDate(s)! }

/// "2026-10-01 09:15" in Bratislava time.
func t(_ s: String) -> Date {
    let f = DateFormatter()
    f.calendar = bratislava
    f.timeZone = bratislava.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

let inst = UUID()

func entry(_ from: String, _ to: String?, issue: String? = nil, project: UUID? = nil, desc: String = "", source: EntrySource = .local) -> TimeEntry {
    TimeEntry(start: t(from), end: to.map(t), instanceId: issue == nil ? nil : inst, issueId: issue, projectId: project, description: desc, source: source)
}
