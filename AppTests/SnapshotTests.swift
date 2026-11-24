import AppKit
import JiraKit
import SwiftUI
import Testing
import TikjotDomain
import TikjotPersistence
@testable import tikjot

/// Snapshot tests of the key screens in light and dark (SPEC §18).
/// Data: the demo model (`DemoData`) on a frozen clock — Thursday 1 Oct 2026, 16:42, with a running timer.
/// Re-record: `SNAPSHOT_RECORD=1 scripts/build.sh test-unit` (see README › Tests).
/// References are rendered on the developer's Mac (macOS 26); other macOS versions render text slightly differently,
/// so CI skips them (`SNAPSHOT_SKIP=1`).
extension AppTestSuite {
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_SKIP"] != "1", "SNAPSHOT_SKIP=1"))
struct SnapshotTests {
    static let demoNow = "2026-10-01 16:42"
    static let mainSize = CGSize(width: 1240, height: 820)

    /// One demo model for the whole suite (seeding + the demo's background send take a moment).
    private static var cached: AppModel?

    /// Freezes the clock, returns the demo model in the given appearance. Call `Self.unfreeze()` when done.
    func model(dark: Bool) async throws -> AppModel {
        let now = try #require(Clock.parse(Self.demoNow))
        Clock.offset = now.timeIntervalSinceNow
        Clock.frozen = now
        let m: AppModel
        if let c = Self.cached {
            m = c
        } else {
            m = try AppModel(db: try AppDatabase(), demo: true, connections: JiraConnections(mock: DemoData.makeServer()))
            DemoData.seed(m)
            // DemoData sends everything older than two days to the mock Jira in the background: wait for it.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            Self.cached = m
        }
        m.now = now
        m.updateSettings { $0.appearance = dark ? "dark" : "light"; $0.language = "en" }
        m.mainSelection = .day
        m.selectedDay = m.today
        m.selectedEntryIds = []
        m.popoverEditing = nil
        m.toast = nil
        return m
    }

    static func unfreeze() {
        Clock.frozen = nil
        Clock.offset = 0
    }

    private func main(_ m: AppModel) -> some View { MainView().environment(m).themed(m) }

    private func snapMain(_ section: MainSection, day: LocalDate? = nil, name: String) async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            m.mainSelection = section
            if let day { m.selectedDay = day }
            Snapshot.assert(main(m), named: "\(name)-\(dark ? "dark" : "light")", size: Self.mainSize, dark: dark)
        }
    }

    @Test func dayWithEntries() async throws {
        try await snapMain(.day, name: "day")
    }

    @Test func dayEmptyWeekend() async throws {
        try await snapMain(.day, day: LocalDate(year: 2026, month: 9, day: 27), name: "day-weekend")
    }

    /// Day overview sheet (pen "Day recap · options" B): totals, split, every task with its descriptions.
    @Test func dayOverview() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            let v = DayOverview(day: m.today) {}.environment(m).themed(m).background(DS.C.surface)
            Snapshot.assert(v, named: "day-overview-\(dark ? "dark" : "light")", size: CGSize(width: 780, height: 720), dark: dark)
        }
    }

    @Test func week() async throws {
        try await snapMain(.week, name: "week")
    }

    @Test func month() async throws {
        try await snapMain(.month, name: "month")
    }

    @Test func unsent() async throws {
        try await snapMain(.unsent, name: "unsent")
    }

    @Test func statistics() async throws {
        try await snapMain(.statistics, name: "statistics")
    }

    /// A quarter: 13+ weeks of trend bars fit the card, By project keeps its width (beta 2026-10-21).
    @Test func statisticsQuarter() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            let view = StatisticsScreen(range: DateRange(m.today.adding(days: -90), m.today)).environment(m).themed(m)
            Snapshot.assert(view, named: "statistics-quarter-\(dark ? "dark" : "light")", size: CGSize(width: 1000, height: 820), dark: dark)
        }
    }

    /// tikjot's hover cards (owner 2026-10-07): the month balance breakdown, a day of the running-balance chart and a
    /// week of the trend (project dots) — and one in place over the Month chart.
    @Test func tooltipCards() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            let month = DateRange.month(of: m.today)
            let today = try #require(m.ledger.runningBalance(month: month, since: m.dataStart).first { $0.date == m.today })
            let day = TooltipContent(title: "Today · \(Fmt.short(m.today))", rows: [
                .init(label: "Worked", value: DurationFormat.hm(today.worked)),
                .init(label: "Expected", value: DurationFormat.short(today.expected)),
                .init(label: "Day ±", value: DurationFormat.signed(today.diff)),
                .init(label: "Running balance", value: DurationFormat.signed(today.running), strong: true),
            ], note: "Click to open the day")
            let week = TooltipContent(title: "Week 40 · 28 Sep – 4 Oct", rows: [
                .init(label: "Payments", value: "14h 20m", dot: DS.project("tangerine")),
                .init(label: "Steering 2026", value: "6h 05m", dot: DS.project("grape")),
                .init(label: "Internal", value: "1h 15m", dot: DS.project("slate")),
                .init(label: "Worked", value: "21h 40m", strong: true),
                .init(label: "Expected", value: "24h"),
                .init(label: "±", value: "−2h 20m"),
            ])
            let cards = HStack(alignment: .top, spacing: 24) {
                ChartTooltip(m.monthBalanceHelp(month)).frame(maxWidth: 300)
                ChartTooltip(day)
                ChartTooltip(week)
            }
            .padding(24).background(DS.C.bg)
            Snapshot.assert(cards.environment(m).themed(m), named: "tooltip-cards-\(dark ? "dark" : "light")", dark: dark)

            // In place: the card over today's column of the Month chart, inside the chart's window.
            let center = TooltipCenter()
            let width: CGFloat = 760, cols = CGFloat(month.count), colW = (width - 28 - 4 * (cols - 1)) / cols
            let x = 14 + CGFloat(m.today.day - 1) * (colW + 4)
            center.show("today", anchor: CGRect(x: x, y: 150, width: colW, height: 96), content: day)
            let inPlace = VStack(spacing: 0) {
                Color.clear.frame(height: 110)
                BalanceCurve(month: month, hover: .constant(m.today))
            }
            .frame(width: width).padding(.bottom, 14).background(DS.C.bg)
            .tooltipHost(center)
            Snapshot.assert(inPlace.environment(m).themed(m), named: "tooltip-month-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    @Test func popover() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            Snapshot.assert(PopoverView().environment(m).themed(m), named: "popover-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// The task picker before any pin: your tasks, the one-time pin hint, the key hints (beta 2026-10-21).
    @Test func taskPickerPinHint() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            UserDefaults.standard.removeObject(forKey: "pinHintDone")
            for i in m.data.issues where i.pinned { m.togglePin(i) }
            let view = TaskPicker(autoFocus: false, onPick: { _, _ in }).padding(12).frame(width: 420).background(DS.C.bg).environment(m).themed(m)
            Snapshot.assert(view, named: "picker-pin-hint-\(dark ? "dark" : "light")", size: CGSize(width: 420, height: 420), dark: dark)
        }
    }

    /// An entry of today edited in place: description, task, START / END / LENGTH, Delete · Cancel · Done
    /// (no "Open in Day" since 2026-10-07).
    @Test func popoverEntryEditor() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            let e = try #require(m.ledger.workEntries(on: m.today).last { $0.end != nil })
            m.popoverEditing = .entry(e.id)
            Snapshot.assert(PopoverView().environment(m).themed(m), named: "popover-edit-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// The description suggestions under "What are you working on?" (Start / ⌥⌘T while idle, typing, back from the
    /// task list): your recent work, then entries like what you typed with "Start … as new".
    @Test func popoverDescriptionSuggestions() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            func panel(_ q: String, highlighted: Int?) -> some View {
                DescriptionSuggestionList(query: q, items: m.descriptionSuggestions(q, limit: q.isEmpty ? 4 : 5), highlighted: highlighted,
                                          pick: { _ in }, startNew: {})
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                    .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.brand, lineWidth: 1.5))
            }
            let v = VStack(spacing: 16) {
                panel("", highlighted: nil)
                panel("retry", highlighted: 0)
            }
            .padding(12).frame(width: 420).background(DS.C.bg)
            Snapshot.assert(v.environment(m).themed(m), named: "popover-suggestions-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    @Test func settingsWorkTime() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            m.settingsTab = .workTime
            Snapshot.assert(SettingsView().environment(m).themed(m), named: "settings-worktime-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// Settings › About › Open-source licences: tikjot's GPL notice, then each bundled component with its licence text
    /// behind a disclosure (collapsed here; `licenceTextsAreBundled` checks the texts).
    @Test func licences() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            Snapshot.assert(LicencesSheet {}.environment(m).themed(m), named: "licences-\(dark ? "dark" : "light")", dark: dark)
            let expanded = LicenceText(file: "SQLCipher-BSD", title: "Licence text", expanded: true)
                .padding(24).frame(width: 540).background(DS.C.surface)
            Snapshot.assert(expanded.environment(m).themed(m), named: "licences-expanded-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// Settings › Jira: sites, then one box of settings per site (no token-expiry row since 2026-10-06).
    @Test func settingsJira() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            m.settingsTab = .jira
            Snapshot.assert(SettingsView().environment(m).themed(m), named: "settings-jira-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// The Unsent badge (variant V1 "brand solid"): calm grey days, a solid brand pill when something needs you —
    /// sidebar row, selected sidebar row, and inverted (with an amber dot) inside the brand button.
    @Test func unsentBadgeStates() async throws {
        let days = [LocalDate(year: 2026, month: 9, day: 29), LocalDate(year: 2026, month: 9, day: 30), LocalDate(year: 2026, month: 10, day: 1)]
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            let v = VStack(alignment: .leading, spacing: 12) {
                ForEach([false, true], id: \.self) { needs in
                    HStack(spacing: 16) {
                        ForEach([false, true], id: \.self) { selected in
                            HStack {
                                Text("Unsent").font(DS.F.bodyMedium).foregroundStyle(selected ? DS.C.brandText : DS.C.text)
                                Spacer()
                                UnsentCountBadge(badge: UnsentBadge(days: days, needsYou: needs), calmFill: DS.C.surface)
                            }
                            .padding(.horizontal, 8).frame(width: 160, height: 32)
                            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(selected ? DS.C.brandSoft : .clear))
                        }
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(DS.C.surface2)
            Snapshot.assert(v.environment(m).themed(m), named: "unsent-badge-\(dark ? "dark" : "light")", size: CGSize(width: 380, height: 120), dark: dark)
        }
    }

    @Test func onboardingFirstStep() async throws {
        for dark in [false, true] {
            let m = try await model(dark: dark)
            defer { Self.unfreeze() }
            Snapshot.assert(OnboardingView().environment(m).themed(m), named: "onboarding-1-\(dark ? "dark" : "light")",
                            size: CGSize(width: 720, height: 540), dark: dark)
        }
    }

    /// The helper itself: identical renders match, a changed view doesn't.
    @Test func comparisonDetectsChanges() throws {
        let a = Snapshot.render(Color.red.frame(width: 40, height: 40), size: CGSize(width: 40, height: 40), dark: false)!
        let b = Snapshot.render(Color.red.frame(width: 40, height: 40), size: CGSize(width: 40, height: 40), dark: false)!
        let c = Snapshot.render(Color.blue.frame(width: 40, height: 40), size: CGSize(width: 40, height: 40), dark: false)!
        #expect(a.pixelsWide == 40 && a.pixelsHigh == 40)
        #expect(Snapshot.compare(a, b).failure == nil)
        #expect(Snapshot.compare(a, c).failure != nil)
    }
}
}
