import Foundation
import JiraKit
import SyncEngine
import Testing
import TikjotDomain
import TikjotPersistence
@testable import tikjot

extension AppTestSuite {
@MainActor
@Suite(.serialized) struct AppModelTests {
    func makeModel() throws -> (AppModel, MockJiraServer) {
        let mock = DemoData.makeServer()
        let model = try AppModel(db: try AppDatabase(), demo: true, connections: JiraConnections(mock: mock))
        return (model, mock)
    }

    func connect(_ m: AppModel) {
        var c = Changes()
        c.upsertInstances = [JiraInstance(id: DemoData.instanceId, name: "Cloud", kind: .cloud, baseURL: URL(string: "https://demo.atlassian.net")!,
                                          authMethod: .cloudApiToken, login: "demo", accountId: "demo", historyStartDate: m.today.firstOfMonth)]
        let p = Project(name: "Payments", color: "tangerine")
        c.upsertProjects = [p]
        c.upsertRules = [ProjectRule(projectId: p.id, instanceId: DemoData.instanceId, value: "ABC")]
        c.upsertIssues = [Issue(instanceId: DemoData.instanceId, issueId: "103", key: "ABC-981", summary: "Payment gateway retry")]
        m.applySilently(c)
    }

    /// "Open in Jira" (beta 2026-10-25): the task's page on its own site; nothing for an unknown task or no task.
    @Test func jiraURLUsesTheTasksOwnSite() throws {
        let (m, _) = try makeModel()
        connect(m)
        #expect(m.jiraURL(IssueRef(instanceId: DemoData.instanceId, issueId: "103"))?.absoluteString == "https://demo.atlassian.net/browse/ABC-981")
        #expect(m.jiraURL(IssueRef(instanceId: DemoData.instanceId, issueId: "999")) == nil)
        #expect(m.jiraURL(nil) == nil)
    }

    /// Typing a description in the popover, then stopping elsewhere (⌥⌘S, widget, main window) keeps the text.
    @Test func pendingDescriptionIsSavedOnAnyStop() throws {
        let (m, _) = try makeModel()
        m.now = Date().addingTimeInterval(-600)
        m.start(description: "Old", at: Date().addingTimeInterval(-600))
        let id = try #require(m.runningEntry?.id)
        m.pendingDescription = (id, "Typed but not confirmed")
        m.now = Date()
        m.stop()
        #expect(m.runningEntry == nil)
        #expect(m.data.entries.first { $0.id == id }?.description == "Typed but not confirmed")
        #expect(m.pendingDescription == nil)
    }

    /// Projects found by an import wait — saved, so a restart keeps them; "Add" creates the ticked ones and every
    /// shown row stops waiting (a left-out key gets no project).
    @Test func pendingProjectSuggestionsSurviveARestartAndAddCreatesOnlyTickedRows() throws {
        let db = try AppDatabase()
        let m = try AppModel(db: db, demo: true, connections: JiraConnections(mock: DemoData.makeServer()))
        let inst = UUID()
        m.noteUnmappedKeys(["CP": "Customer Portal", "MIG": "Data Migration"], instanceId: inst)
        let again = try AppModel(db: db, demo: true, connections: JiraConnections(mock: DemoData.makeServer()))
        #expect(again.pendingProjectSuggestions["CP"]?.0 == "Customer Portal")
        #expect(again.pendingProjectSuggestions["MIG"]?.1 == inst)
        let items = again.proposalItems(instanceId: inst)
        #expect(items.map(\.1) == ["CP", "MIG"])
        var choices = ProjectProposalChoices(items: items, model: again)
        choices.leftOut = ["MIG"]
        #expect(again.createProposedProjects(items, choices: choices) == 1)
        #expect(again.data.projects.contains { $0.name == "Customer Portal" })
        #expect(!again.data.rules.contains { $0.value == "MIG" })
        #expect(again.pendingProjectSuggestions.isEmpty)
        let third = try AppModel(db: db, demo: true, connections: JiraConnections(mock: DemoData.makeServer()))
        #expect(third.pendingProjectSuggestions.isEmpty)
    }

    @Test func timerStartSwitchStopAndUndo() throws {
        let (m, _) = try makeModel()
        connect(m)
        let issue = m.data.issues[0]
        m.now = Date().addingTimeInterval(-3600)
        m.start(issue: issue, description: "Retry logic", at: Date().addingTimeInterval(-3600))
        #expect(m.runningEntry?.description == "Retry logic")
        #expect(m.runningEntry?.projectId == m.data.projects[0].id) // project from key rule
        m.now = Date()
        m.start(description: "Something else")
        #expect(m.data.entries.count == 2)
        #expect(m.data.entries[0].end != nil)
        m.stop()
        #expect(m.runningEntry == nil)
        m.undo()
        #expect(m.runningEntry != nil)
        m.redo()
        #expect(m.runningEntry == nil)
    }

    @Test func groupsFollowEntriesAndPlanSends() async throws {
        let (m, mock) = try makeModel()
        connect(m)
        let issue = m.data.issues[0]
        let day = m.today.adding(days: -1)
        let e = m.addEntry(on: day, from: day.at(minutes: 540, in: .current), to: day.at(minutes: 652, in: .current), issue: issue, description: "Work")
        #expect(e != nil)
        #expect(m.data.groups.count == 1)
        let plan = m.plan(.days([day]))
        #expect(plan.items.first?.value == 110 * 60) // 1h 52m, nearest 5 min (the default)
        let report = await m.send(plan.items) { _ in }
        #expect(report.sentCount == 1)
        #expect(await mock.myWorklogs().count == 1)
        #expect(m.ledger.dayStatus(day, lock: m.lock) == .allInJira)
    }

    @Test func absencesReduceFund() throws {
        let (m, _) = try makeModel()
        var d = m.today
        while !m.dayCalendar.isWorkday(d) { d = d.adding(days: 1) }
        let before = m.dayCalendar.fund(d)
        m.addAbsence(type: .doctor, days: [d], unit: .hours, seconds: 3 * 3600, startMinutes: 600)
        #expect(m.dayCalendar.fund(d) == before - 3 * 3600)
        m.removeAbsences(m.absences(on: d))
        #expect(m.dayCalendar.fund(d) == before)
    }

    /// The month balance tooltip says the number shown next to it, and lists absences only when there are some.
    @Test func monthBalanceHelpMatchesTheBalance() throws {
        let (m, _) = try makeModel()
        let month = DateRange.month(of: m.today)
        let bal = m.ledger.liveBalance(month, since: m.dataStart)
        let help = m.monthBalanceHelp(month)
        #expect(help.title == "\(Fmt.monthName(m.today)) so far")
        #expect(help.rows.contains(.init(label: "Balance", value: DurationFormat.signed(bal), strong: true)))
        #expect(help.note == "Worked is rounded, as in Jira." && help.rows.first?.label == "Expected")
        #expect(!help.accessibilityText.contains("doctor"))
        var d = month.start
        while !m.dayCalendar.isWorkday(d) || d < m.dataStart { d = d.adding(days: 1) }
        if d < m.today {
            m.addAbsence(type: .doctor, days: [d], unit: .hours, seconds: 3600, startMinutes: 600)
            let after = m.monthBalanceHelp(month)
            #expect(after.rows.first?.value.contains("− doctor 1h") == true)
            #expect(after.accessibilityText.contains("Balance \(DurationFormat.signed(m.ledger.liveBalance(month, since: m.dataStart)))"))
        }
    }

    /// The hover card sits above its element, centred, and never leaves the window.
    @Test func tooltipPlacementStaysInside() {
        let card = CGSize(width: 200, height: 80)
        let bounds = CGSize(width: 1000, height: 700)
        // Room above: centred above with an 8 pt gap.
        #expect(TooltipPlacement.origin(card: card, anchor: CGRect(x: 400, y: 300, width: 20, height: 40), in: bounds) == CGPoint(x: 310, y: 212))
        // At the top: below the element.
        #expect(TooltipPlacement.origin(card: card, anchor: CGRect(x: 400, y: 20, width: 20, height: 40), in: bounds) == CGPoint(x: 310, y: 68))
        // At the left / right edge: pushed in to the 8 pt margin.
        #expect(TooltipPlacement.origin(card: card, anchor: CGRect(x: 0, y: 300, width: 20, height: 40), in: bounds).x == 8)
        #expect(TooltipPlacement.origin(card: card, anchor: CGRect(x: 990, y: 300, width: 10, height: 40), in: bounds).x == 792)
        // An element taller than the window: the card stays inside.
        let tall = TooltipPlacement.origin(card: card, anchor: CGRect(x: 400, y: 50, width: 20, height: 680), in: bounds)
        #expect(tall.y >= 8 && tall.y + card.height <= bounds.height - 8)
    }

    /// The card never travels (owner 2026-10-07): it fades in when none is shown, is replaced in place when the
    /// pointer moves to another element, survives the gap between two bars, and fades out only after the grace.
    @Test func tooltipPresenceShowSwitchHide() {
        var p = TooltipPresence()
        let a = TooltipContent(title: "W40"), b = TooltipContent(title: "W41")
        let ra = CGRect(x: 10, y: 10, width: 44, height: 170), rb = CGRect(x: 82, y: 10, width: 44, height: 170)
        // First card: fade in.
        #expect(p.show("a", anchor: ra, content: a) == .appear)
        #expect(p.show("a", anchor: ra, content: a) == .none)
        // Straight onto the next bar (enter before leave): replaced in place, and A's late exit doesn't hide B.
        #expect(p.show("b", anchor: rb, content: b) == .replace)
        #expect(p.hide("a") == .none)
        #expect(p.shown?.id == AnyHashable("b") && p.shown?.anchor == rb)
        // Across a gap (leave, then enter within the grace): still a replace, never a fade out + in.
        #expect(p.hide("b") == .startGrace)
        #expect(p.hide("b") == .none)
        #expect(p.show("a", anchor: ra, content: a) == .replace)
        #expect(!p.leaving)
        #expect(p.graceEnded() == .none)   // a stale grace timer does nothing
        // Back onto the same element during the grace: it simply stays.
        #expect(p.hide("a") == .startGrace)
        #expect(p.show("a", anchor: ra, content: a) == .none)
        #expect(p.graceEnded() == .none && p.shown != nil)
        // Pointer leaves everything: gone after the grace (fade out), and the next card fades in again.
        #expect(p.hide("a") == .startGrace)
        #expect(p.shown != nil)
        #expect(p.graceEnded() == .disappear)
        #expect(p.shown == nil)
        #expect(p.show("b", anchor: rb, content: b) == .appear)
        // New content on the shown element (a live number): swapped without animation.
        #expect(p.show("b", anchor: rb, content: TooltipContent(title: "W41", rows: [.init(label: "Worked", value: "1h")])) == .replace)
    }

    @Test func projectsMergeAndKeyMove() throws {
        let (m, _) = try makeModel()
        connect(m)
        let a = m.data.projects[0]
        let b = m.createProject(name: "Other")
        m.assignKey("ABC", instanceId: DemoData.instanceId, to: b.id)
        #expect(m.data.rules.filter { $0.value == "ABC" }.count == 1)
        #expect(m.data.rules.first { $0.value == "ABC" }?.projectId == b.id)
        m.mergeProject(b, into: a)
        #expect(m.data.projects.count == 1)
        #expect(m.data.rules.first { $0.value == "ABC" }?.projectId == a.id)
    }

    @Test func csvExportHasBOMAndRows() throws {
        let (m, _) = try makeModel()
        connect(m)
        let day = m.today.adding(days: -1)
        m.addEntry(on: day, from: day.at(minutes: 540, in: .current), to: day.at(minutes: 600, in: .current), issue: m.data.issues[0], description: "A; B")
        let data = Exporter.make(.entries, model: m, range: DateRange(day, day), projects: nil, billable: nil)
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.contains("ABC-981"))
        #expect(text.split(separator: "\r\n").count == 2)
        let att = Exporter.make(.attendance, model: m, range: DateRange(day, day), projects: nil, billable: nil)
        #expect(String(decoding: att, as: UTF8.self).contains(day.description))
    }

    @Test func keychainRoundTrip() throws {
        let account = "test-\(UUID().uuidString)"
        try Keychain.write(Data("secret".utf8), account: account)
        #expect(Keychain.read(account) == Data("secret".utf8))
        Keychain.delete(account)
        #expect(Keychain.read(account) == nil)
    }

    @Test func widgetReloadsOnlyWhenWhatItShowsChanges() throws {
        let now = Date()
        var a = WidgetSnapshot.placeholder
        a.generatedAt = now
        a.running?.start = now.addingTimeInterval(-600)
        a.worked = 3600
        // A minute later, nothing changed but the clock: same signature, no reload.
        var b = a
        b.generatedAt = now.addingTimeInterval(60)
        b.worked = 3660
        b.balanceText = "+0h 01m"
        #expect(a.reloadSignature(now: now) == b.reloadSignature(now: now.addingTimeInterval(60)))
        // Switching the task changes what the widget shows: reload.
        var c = a
        c.running?.key = "ABC-1"
        #expect(a.reloadSignature(now: now) != c.reloadSignature(now: now))
    }

    /// Beta 2026-10-08, row 13: starting or adding an entry without a task never takes a project from history (it
    /// used to take the last *inserted* entry's project, even an old import) — no task = no project unless picked.
    @Test func noTaskMeansNoGuessedProject() throws {
        let (m, _) = try makeModel()
        connect(m)
        let payments = m.data.projects[0]
        let other = Project(name: "Internal", color: "slate")
        let day = m.today.adding(days: -1)
        var c = Changes()
        c.upsertProjects = [other]
        // Inserted last but the oldest by time — the old guess picked this one.
        c.upsertEntries = [TimeEntry(start: day.at(minutes: 600, in: .current), end: day.at(minutes: 660, in: .current), projectId: payments.id, description: "Newer"),
                           TimeEntry(start: day.at(minutes: 480, in: .current), end: day.at(minutes: 540, in: .current), projectId: other.id, description: "Older")]
        m.applySilently(c)
        #expect(m.defaultProjectId == nil)

        // Added in the Day without a task: no project.
        let added = try #require(m.addEntry(on: day, from: day.at(minutes: 700, in: .current), to: day.at(minutes: 720, in: .current), description: "Added"))
        #expect(added.projectId == nil)

        // ↩ / ⌘↩ in the popover without a task: no project.
        m.now = Date().addingTimeInterval(-600)
        m.start(description: "Review checkout flow", at: Date().addingTimeInterval(-600))
        #expect(m.runningEntry?.projectId == nil)

        // A project picked explicitly stays; "No task yet" then keeps the running entry's project, nothing else.
        m.now = Date()
        m.start(projectId: other.id, description: "Internal work")
        #expect(m.runningEntry?.projectId == other.id)
        #expect(m.defaultProjectId == other.id)
        m.stop()
        #expect(m.defaultProjectId == nil)
    }

    /// Beta 2026-10-14: a second Jira behind a VPN that's off must not flip "offline" off and on with every refresh
    /// (the banner blinked) — only the connections that didn't answer count, and only they are asked again.
    @Test func unreachableConnectionStaysQuietAndOnlyItIsRetried() async throws {
        let (m, mock) = try makeModel()
        connect(m)
        let other = UUID()
        m.markUnreachable(other, .signInPage("sso.example.com"))
        #expect(m.offline)
        m.markReachable(DemoData.instanceId)          // the working connection answering changes nothing
        #expect(m.offline && m.unreachableInstances == [other])
        m.markReachable(other)
        #expect(!m.offline && m.lastRefreshError == nil)

        await mock.setSignInPage("<html><form action='https://sso.example.com/login'></form></html>")
        await m.refreshAll(reason: "test")
        #expect(m.offline && m.unreachableInstances == [DemoData.instanceId])
        #expect(m.lastRefreshError?.isSignInPage == true)
        await mock.setSignInPage(nil)
        await m.refreshAll(reason: "retry", only: m.unreachableInstances)
        #expect(!m.offline && m.unreachableInstances.isEmpty && m.lastRefreshError == nil)
    }

    /// Beta 2026-10-15: away from the Mac (night, dark wakes), an unreachable Jira isn't tried; back, one refresh.
    @Test func unreachableJiraWaitsWhileYouAreAway() async throws {
        let (m, _) = try makeModel()
        connect(m)
        var away = true
        m.userAway = { away }
        m.markUnreachable(DemoData.instanceId, .signInPage("sso.example.com"))
        m.networkChanged()
        #expect(m.networkRetry == nil && m.jiraWaitsForYou)
        away = false
        #expect(m.userIsBack() && !m.jiraWaitsForYou)
        m.offlineRetry?.cancel()
    }

    /// Beta 2026-10-18: back from a break you switch tasks without answering the away card. The card stays about
    /// the entry that ran while you were away: "Remove" splits that one around the time away, the new timer isn't
    /// touched (it used to be "Stop at", which deleted the new timer).
    @Test func awayCardAfterASwitchActsOnTheEntryYouWereAwayFrom() throws {
        let (m, _) = try makeModel()
        let base = Date().addingTimeInterval(-40 * 60).roundedToSecond
        guard LocalDate(base, calendar: m.timeCalendar) == m.today else { return }   // just after midnight
        m.now = base
        m.start(description: "Steering minutes", at: base)
        let a = try #require(m.runningEntry)
        m.awayPrompt = AwayPrompt(from: base.addingTimeInterval(300), to: base.addingTimeInterval(900), slept: false, entryId: a.id)
        #expect(m.awayCard?.owner == .running(a))
        m.now = base.addingTimeInterval(1200)
        m.start(description: "Agenda review", at: m.now)
        let b = try #require(m.runningEntry)
        guard case .finished(let e)? = m.awayCard?.owner else { Issue.record("no card after the switch"); return }
        #expect(e.id == a.id)
        m.stopAtAway()
        #expect(m.awayPrompt == nil)
        #expect(m.runningEntry?.id == b.id)
        let parts = m.data.entries.filter { $0.deletedAt == nil && $0.description == "Steering minutes" }.sorted { $0.start < $1.start }
        #expect(parts.map(\.start) == [base, base.addingTimeInterval(900)])
        #expect(parts.map(\.end) == [base.addingTimeInterval(300), base.addingTimeInterval(1200)])
    }

    /// Still on the same timer: the card is as before ("Stop at" ends it when you left). Deleted since: no card.
    @Test func awayCardOnTheRunningTimerAndGoneWhenItsEntryIsDeleted() throws {
        let (m, _) = try makeModel()
        let base = Date().addingTimeInterval(-40 * 60).roundedToSecond
        guard LocalDate(base, calendar: m.timeCalendar) == m.today else { return }
        m.now = base
        m.start(description: "Code review", at: base)
        let a = try #require(m.runningEntry)
        m.now = base.addingTimeInterval(1200)
        m.awayPrompt = AwayPrompt(from: base.addingTimeInterval(600), to: m.now, slept: false, entryId: a.id)
        m.stopAtAway()
        #expect(m.runningEntry == nil)
        #expect(m.data.entries.first { $0.id == a.id }?.end == base.addingTimeInterval(600))

        m.start(description: "Other", at: m.now)
        let c = try #require(m.runningEntry)
        m.awayPrompt = AwayPrompt(from: base.addingTimeInterval(1260), to: base.addingTimeInterval(1500), slept: false, entryId: c.id)
        m.now = base.addingTimeInterval(1600)
        m.start(description: "Next", at: m.now)
        #expect(m.awayCard != nil)
        m.delete(m.data.entries.filter { $0.id == c.id })
        #expect(m.awayCard == nil)
        m.dropStaleAwayPrompt()
        #expect(m.awayPrompt == nil)
    }

    /// Settings › About › Open-source licences: every licence text ships in the app bundle (MIT/BSD/OFL require it).
    @Test func licenceTextsAreBundled() {
        let expected = [("GPL-3.0", "GNU GENERAL PUBLIC LICENSE"), ("GRDB-MIT", "Gwendal Roué"),
                        ("SQLCipher-BSD", "ZETETIC LLC"), ("OFL", "Bricolage Grotesque Project Authors")]
        for (file, notice) in expected {
            #expect(LicenceText(file: file, title: "").text.contains(notice), "\(file).txt")
        }
    }
}
}
