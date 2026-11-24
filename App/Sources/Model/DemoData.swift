import Foundation
import JiraKit
import SyncEngine
import TikjotDomain
import TikjotPersistence

/// Demo mode (`-tikjotDemo`): in-memory database + mock Jira with the design's sample data.
/// Used for screenshots, UI checks and trying tikjot without a Jira account.
enum DemoData {
    static let instanceId = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!

    struct I { let id: String; let key: String; let summary: String; var status = "In Progress"; var cat = "indeterminate"; var assigned = false; var estimate: Int? = nil }

    static let issues: [I] = [
        I(id: "101", key: "PMO-412", summary: "Quarterly steering prep", assigned: true),
        I(id: "102", key: "PMO-415", summary: "Steering committee minutes", assigned: true),
        I(id: "103", key: "ABC-981", summary: "Payment gateway retry", assigned: true, estimate: 20 * 3600),
        I(id: "104", key: "DIV-7", summary: "Division meetings"),
        I(id: "105", key: "FIN-23", summary: "Budget 2027 planning"),
        I(id: "106", key: "PAY-5", summary: "Finance system integration"),
        I(id: "107", key: "OPS-77", summary: "Operations night release"),
        I(id: "108", key: "INT-3", summary: "Standup"),
        I(id: "109", key: "VND-12", summary: "Vendor contract review", status: "Done", cat: "done"),
        I(id: "110", key: "ADM-44", summary: "Internal budget rules"),
        I(id: "111", key: "ABC-990", summary: "Card tokenisation", assigned: true, estimate: 8 * 3600),
        I(id: "112", key: "FIN-31", summary: "Budget IT 2027 review"),
    ]

    static func makeServer() -> MockJiraServer {
        let s = MockJiraServer(kind: .cloud, me: "demo", meName: "Martin Example", validSecret: "demo")
        Task {
            for i in issues {
                let long = i.id == "102" && LaunchFlags.args.contains("-demoLongKey")
                await s.add(.init(id: i.id, key: long ? "PAY_PLATFORM-5" : i.key, summary: long ? "Payments platform – integration" : i.summary, status: i.status, statusCategory: i.cat,
                                  assignee: i.assigned ? "demo" : nil, estimate: i.estimate, projectName: projectName(Issue.projectKey(of: i.key))))
            }
        }
        return s
    }

    static func projectName(_ key: String) -> String {
        switch key {
        case "ABC", "PAY": return "Payments"
        case "PMO": return "Steering 2026"
        case "FIN": return "Finance"
        case "DIV": return "Division"
        case "VND": return "Vendor"
        case "OPS": return "Operations"
        default: return "Internal"
        }
    }

    /// Deterministic pseudo-random numbers so screenshots are stable.
    struct RNG { var s: UInt64; mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(n)) } }

    @MainActor
    static func seed(_ m: AppModel) {
        let cal = m.timeCalendar
        let today = m.today
        var c = Changes()
        var inst = JiraInstance(id: instanceId, name: "Company Cloud", kind: .cloud, baseURL: URL(string: "https://demo.atlassian.net")!,
                                authMethod: .cloudApiToken, login: "demo@example.com", accountId: "demo", displayName: "Martin Example",
                                jiraTimeZone: TimeZone.current.identifier,
                                lastSyncAt: Clock.now, syncCursor: Clock.now, historyStartDate: today.firstOfMonth.adding(months: -1))   // = the demo data start (no empty imported month)
        c.upsertInstances = [inst]
        let projects: [(String, String, Bool, [String])] = [
            ("Payments", "tangerine", true, ["ABC", "PAY"]), ("Steering 2026", "grape", true, ["PMO"]),
            ("Finance", "amber", true, ["FIN"]), ("Division", "jade", false, ["DIV"]), ("Vendor", "blue", true, ["VND"]),
            ("Internal", "slate", false, ["INT", "ADM"]), ("Operations", "cyan", true, ["OPS"]),
        ]
        var pid: [String: UUID] = [:]
        for (name, color, billable, keys) in projects {
            let p = Project(name: name, color: color, billable: billable)
            c.upsertProjects.append(p)
            for k in keys { c.upsertRules.append(ProjectRule(projectId: p.id, instanceId: instanceId, value: k)); pid[k] = p.id }
        }
        var issueById: [String: Issue] = [:]
        for i in issues {
            var x = Issue(instanceId: instanceId, issueId: i.id, key: i.key, summary: i.summary, issueType: "Task", statusName: i.status,
                          statusCategory: StatusCategory(rawValue: i.cat) ?? .indeterminate, assignedToMe: i.assigned,
                          originalEstimateSeconds: i.estimate, timeSpentSeconds: nil, updated: Clock.now, sources: ["logged"])
            c.upsertIssues.append(x)
            issueById[i.id] = x
        }
        let descs: [String: [String]] = [
            "101": ["Prepare agenda for steering", "Steering deck"], "102": ["Wrap-up notes", "Steering minutes"],
            "103": ["Retry logic for card payments", "Code review", "Fix flaky retry test"], "104": ["Weekly sync", "Division meeting"],
            "105": ["Budget review", "workshop prep with finance"], "106": ["Integration call", "Mapping fields"],
            "107": ["Release window"], "108": ["Standup"], "110": ["Budget rules draft"], "111": ["Tokenisation spike"],
        ]
        // Debug/captures: -demoSeed N picks another (equally plausible) history, e.g. a month that ends in plus.
        let a = LaunchFlags.args
        var rng = RNG(s: a.firstIndex(of: "-demoSeed").flatMap { a.indices.contains($0 + 1) ? UInt64(a[$0 + 1]) : nil } ?? 42)
        func add(_ d: LocalDate, _ from: Int, _ to: Int, _ issueId: String?, _ desc: String? = nil, project: String? = nil) {
            let s = d.at(minutes: from, in: cal), e = d.at(minutes: to, in: cal)
            let issue = issueId.flatMap { issueById[$0] }
            let key = issue.map { Issue.projectKey(of: $0.key) } ?? project ?? "ABC"
            let text = desc ?? issueId.flatMap { descs[$0]?[rng.next(descs[$0]!.count)] } ?? ""
            c.upsertEntries.append(TimeEntry(start: s, end: e, instanceId: issue == nil ? nil : instanceId, issueId: issue?.issueId,
                                             projectId: pid[key], description: text))
        }
        let pool = ["101", "103", "103", "105", "106", "102", "111", "110", "107"]
        let start = today.firstOfMonth.adding(months: -1)
        let vacation = DateRange(start.adding(days: 20), start.adding(days: 24))
        var d = start
        while d < today {
            defer { d = d.adding(days: 1) }
            let wd = d.isoWeekday
            if wd >= 6 { continue }
            if vacation.contains(d) { continue }
            if d == today.adding(days: -9) && !LaunchFlags.args.contains("-demoNoMissed") { continue } // a missed day (promo: none)
            var t = 8 * 60 + rng.next(4) * 10
            add(d, t, t + 15, "108", "Standup"); t += 15
            if wd == 1 || wd == 4 { add(d, t, t + 80, "104", "Weekly sync"); t += 80 }
            while t < 16 * 60 + 20 {
                let len = [45, 60, 75, 90, 110, 120][rng.next(6)]
                let iid = pool[rng.next(pool.count)]
                let end = min(t + len, 17 * 60)
                add(d, t, end, iid)
                t = end + (t < 12 * 60 && end >= 12 * 60 ? 30 : rng.next(3) * 5)
            }
        }
        // Vacation absences and a doctor visit.
        let vacationRange = UUID()   // one range, as a real "Date range" vacation
        for v in vacation where v.isoWeekday < 6 {
            var a = Absence(typeId: AbsenceType.vacation.id, date: v, unit: .day)
            a.rangeId = vacationRange
            c.upsertAbsences.append(a)
        }
        // Today: like "Main · Day" in the design.
        if today.isoWeekday < 6 {
            add(today, 8 * 60 + 26, 10 * 60 + 5, "102", "Prepare agenda for steering")
            add(today, 10 * 60 + 10, 11 * 60 + 30, "104", "Weekly sync")
            add(today, 11 * 60 + 30, 12 * 60 + 5, "103", "Code review")
            add(today, 13 * 60 + 2, 15 * 60, nil, "workshop prep with finance", project: "ABC")
            if LaunchFlags.args.contains("-demoShort") {
                // Debug/captures: back-to-back short entries in the lunch gap (5, 10 and 15 min).
                add(today, 12 * 60 + 10, 12 * 60 + 15, "103", "Quick reply on the PR")
                add(today, 12 * 60 + 15, 12 * 60 + 25, "108", "Call with support")
                add(today, 12 * 60 + 25, 12 * 60 + 40, "104", "Fix the agenda typo")
            }
            c.upsertAbsences.append(Absence(typeId: AbsenceType.doctor.id, date: today, unit: .hours, amountSeconds: 3600, startMinutes: 15 * 60))
            let nowMin = cal.component(.hour, from: Clock.now) * 60 + cal.component(.minute, from: Clock.now)
            if LaunchFlags.args.contains("-demoIdle") {
                // Debug/captures: nothing running.
            } else if nowMin > 16 * 60 {
                c.upsertEntries.append(TimeEntry(start: today.at(minutes: 16 * 60, in: cal), end: nil, instanceId: instanceId, issueId: "102",
                                                 projectId: pid["PMO"], description: "Wrap-up notes"))
            } else {
                c.upsertEntries.append(TimeEntry(start: Clock.now.addingTimeInterval(-42 * 60), end: nil, instanceId: instanceId, issueId: "102",
                                                 projectId: pid["PMO"], description: "Wrap-up notes"))
            }
        }
        // Nothing in the future: drop today's sample entries that would end after "now".
        c.upsertEntries.removeAll { e in (e.end ?? .distantPast) > m.now }
        if let r = c.upsertEntries.first(where: { $0.end == nil }) {
            let latest = c.upsertEntries.compactMap(\.end).filter { LocalDate($0, calendar: cal) == today }.max()
            if let latest, latest > r.start, let i = c.upsertEntries.firstIndex(where: { $0.id == r.id }) { c.upsertEntries[i].start = latest }
        }
        var s = m.settings
        s.onboardingDone = true
        s.openingBalance = OpeningBalance(date: start, seconds: 6 * 3600)
        c.settings = s
        if LaunchFlags.args.contains("-demoLongKey") {
            // Debug/captures: a long real-world Jira key on the running task.
            c.upsertIssues = c.upsertIssues.map { var x = $0; if x.issueId == "102" { x.key = "PAY_PLATFORM-5"; x.summary = "Payments platform – integration" }; return x }
        }
        m.applySilently(c)

        // Send everything older than two days to the mock Jira, so the demo has a realistic mix.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Debug/captures `-demoAllSent`: today is stopped and sent too (the green "all sent" moment).
            let allSent = LaunchFlags.args.contains("-demoAllSent")
            if allSent {
                m.stop()
                let noTask = m.ledger.workEntries(on: today).filter { !$0.hasIssue }
                if let i = m.data.issues.first(where: { $0.issueId == "103" }), !noTask.isEmpty { m.setTask(i, projectId: nil, for: noTask) }
                m.toast = nil
            }
            let days = Array(DateRange(start, allSent ? today : today.adding(days: -3)))
            let plan = m.plan(.days(days))
            let r = await m.engine.send(plan.items)
            if allSent { Log.info("demo all sent: \(plan.items.count) items, needs you \(plan.needsYou.count), sent \(r.sentCount), failed \(r.failed.count), status \(m.ledger.dayStatus(today, lock: m.lock, jiraConnected: m.jiraConnected))") }
            // One conflict and one failure to show those states.
            m.reconcile()
        }
    }
}
