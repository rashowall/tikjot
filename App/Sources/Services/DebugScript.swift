#if DEBUG
import AppKit
import SyncEngine
import TikjotDomain
import TikjotPersistence

/// Debug aid for demo mode: `-script flow` drives the model through a realistic day and writes the
/// outcome to /private/tmp/tikjot-captures/script.txt (checks the real app process end to end).
@MainActor
enum DebugScript {
    static func run(args: [String], model m: AppModel) {
        guard m.demo, let i = args.firstIndex(of: "-script"), args.indices.contains(i + 1) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var log: [String] = []
            func check(_ name: String, _ ok: Bool) { log.append("\(ok ? "PASS" : "FAIL") \(name)") }
            let day = m.today.adding(days: -1)
            // 1. Timer
            let issue = m.data.issues.first { $0.key == "ABC-981" }!
            m.start(issue: issue, description: "Scripted work", at: m.now.addingTimeInterval(-1800))
            check("timer running", m.runningEntry?.description == "Scripted work")
            m.stop()
            check("timer stopped", m.runningEntry == nil)
            m.undo(); check("undo stop", m.runningEntry != nil)
            m.redo(); check("redo stop", m.runningEntry == nil)
            // 2. Editing on yesterday
            let e = m.addEntry(on: day, from: day.at(minutes: 18 * 60, in: .current), to: day.at(minutes: 19 * 60, in: .current), issue: issue, description: "Evening fix")!
            if let ch = try? EntryOps.split(e, at: day.at(minutes: 18 * 60 + 30, in: .current)) { m.apply(ch, name: "Split") }
            check("split", m.ledger.workEntries(on: day).filter { $0.description == "Evening fix" }.count == 2)
            let parts = m.ledger.workEntries(on: day).filter { $0.description == "Evening fix" }.compactMap { p in m.data.entries.first { $0.id == p.id } }
            if let ch = try? EntryOps.merge(parts) { m.apply(ch, name: "Merge") }
            check("merge", m.ledger.workEntries(on: day).filter { $0.description == "Evening fix" }.count == 1)
            // M merges only neighbours (beta 2026-10-22): another task in between stops it.
            let other = m.data.issues.first { $0.key != "ABC-981" }!
            _ = m.addEntry(on: day, from: day.at(minutes: 19 * 60, in: .current), to: day.at(minutes: 19 * 60 + 30, in: .current), issue: other, description: "Between")
            let later = m.addEntry(on: day, from: day.at(minutes: 19 * 60 + 30, in: .current), to: day.at(minutes: 20 * 60, in: .current), issue: issue, description: "Evening fix 2")!
            m.selectedDay = day
            m.selectedEntryIds = [later.id]
            m.mergeSelectionWithPrevious()
            check("no merge over another task", m.data.entries.contains { $0.id == later.id })
            // A merge over an empty gap names the time it adds.
            let late = m.addEntry(on: day, from: day.at(minutes: 21 * 60, in: .current), to: day.at(minutes: 21 * 60 + 30, in: .current), issue: issue, description: "Late fix")!
            m.selectedEntryIds = [late.id]
            m.mergeSelectionWithPrevious()
            check("merge toast names the gap", m.toast?.text == "Merged · +1h 00m from the gap" && !m.data.entries.contains { $0.id == late.id })
            // 3. Absence
            let fundBefore = m.dayCalendar.fund(m.today.adding(days: 1))
            m.addAbsence(type: .doctor, days: [m.today.adding(days: 1)], unit: .hours, seconds: 7200, startMinutes: 600)
            check("absence reduces fund", m.dayCalendar.fund(m.today.adding(days: 1)) == max(0, fundBefore - 7200))
            // 4. Give the no-task entry a task, then review & send yesterday
            let noTask = m.ledger.workEntries(on: day).filter { !$0.hasIssue }
            m.setTask(issue, projectId: nil, for: noTask)
            let plan = m.plan(.days([day]))
            check("plan has items", !plan.items.isEmpty)
            let report = await m.send(plan.items) { _ in }
            check("sent all", report.failed.isEmpty && report.sentCount == plan.items.count)
            check("day in Jira", m.ledger.dayStatus(day, lock: m.lock) == .allInJira)
            // 5. Undo after send
            _ = await m.engine.undo(report.undo)
            check("undo send", !m.plan(.days([day])).items.isEmpty)
            // 6. Refresh from the mock Jira
            await m.refreshAll(reason: "script")
            check("refresh ok", m.lastRefreshError == nil)
            // 7. Unknown Jira key → project named after the Jira project
            var unknown = Issue(instanceId: DemoData.instanceId, issueId: "999", key: "QA-1", summary: "Release testing")
            unknown.projectName = "Quality Assurance"
            let before = m.data.projects.count
            m.start(issue: unknown, description: "Smoke test")
            let created = m.data.projects.first { $0.name == "Quality Assurance" }
            check("auto project created", m.data.projects.count == before + 1 && created != nil)
            check("auto project has key rule", m.data.rules.contains { $0.value == "QA" && $0.projectId == created?.id })
            check("entry filed into it", m.runningEntry?.projectId == created?.id)
            m.stop()
            // 8. CSV
            let csv = Exporter.make(.worklogs, model: m, range: DateRange.month(of: m.today), projects: nil, billable: nil)
            check("csv", csv.count > 100)
            let dir = URL(fileURLWithPath: "/private/tmp/tikjot-captures")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("script.txt"), atomically: true, encoding: .utf8)
            if args.contains("-captureQuit") { NSApp.terminate(nil) }
        }
    }
}
#endif
