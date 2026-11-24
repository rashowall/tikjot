import Charts
import SwiftUI
import TikjotDomain

/// Statistics (§12): filters · KPIs · by project · trend by week vs fund · utilization (bullet bars) · heatmap · tasks.
/// Drill-down is an in-place filter with a breadcrumb: all → project → task (days → entries).
struct StatisticsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var range: DateRange?
    @State private var projectFilter: Set<UUID>? = nil
    @State private var billable: Bool? = nil
    @State private var drillProject: UUID?
    @State private var drillTask: IssueRef?
    @State private var allTasks = false
    @State private var showPeriod = false
    @State private var showProjects = false
    @State private var showBillable = false
    @State private var expandedDays: Set<LocalDate> = []

    /// `range`: the period to open at (snapshots); nil = this month.
    init(range: DateRange? = nil) { _range = State(initialValue: range) }

    private var r: DateRange { range ?? DateRange.month(of: model.today) }

    /// Effective project filter (drill-down wins).
    private var projects: Set<UUID>? { drillProject.map { [$0] } ?? projectFilter }

    private func include(_ pid: UUID?) -> Bool {
        if let projects, !projects.contains(pid ?? UUID()) { return false }
        if let billable { return (model.project(pid)?.billable ?? false) == billable }
        return true
    }

    private func lines(_ d: LocalDate) -> [WorklogLine] {
        model.ledger.lines(on: d).filter { include($0.projectId) && (drillTask == nil || $0.issue == drillTask) }
    }

    var body: some View {
        let hasData = !model.data.entries.isEmpty && (model.data.entries.first.map { model.now.timeIntervalSince($0.start) > 6 * 86400 } ?? false)
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
                .onAppear {
                    // Debug/captures: -statsFilter period|projects|billable opens that filter; -statsMonth 2026-09 picks the month.
                    let a = LaunchFlags.args
                    if let i = a.firstIndex(of: "-statsMonth"), a.indices.contains(i + 1), let d = LocalDate(a[i + 1] + "-01") { range = DateRange.month(of: d) }
                    if let i = a.firstIndex(of: "-statsFilter"), a.indices.contains(i + 1) {
                        let w = a[i + 1]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            if w == "period" { showPeriod = true } else if w == "projects" { showProjects = true } else if w == "billable" { showBillable = true }
                        }
                    }
                }
            if !hasData {
                notEnoughData
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        filters
                        breadcrumb
                        if allTasks {
                            TasksTable(rows: taskRows(), limit: nil) { ref in drillTask = ref; allTasks = false }
                        } else if let t = drillTask {
                            taskDrill(t)
                        } else {
                            kpis
                            // Cards in a row share one height (the tallest).
                            HStack(alignment: .top, spacing: 16) {
                                byProject.frame(minWidth: 240, maxWidth: .infinity)
                                trend.frame(maxWidth: .infinity)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .top, spacing: 16) {
                                utilization.frame(maxWidth: .infinity)
                                heatmap.frame(maxWidth: .infinity)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(String(localized: "Top tasks")).font(.system(size: 14, weight: .bold))
                                    Spacer()
                                    Button(String(localized: "All \(taskRows().count) tasks →")) { allTasks = true }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                                }
                                TasksTable(rows: taskRows(), limit: 5) { ref in drillTask = ref }
                            }
                            .padding(16).background(card)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onChange(of: model.exportRequest) { _, v in if v { model.exportRequest = false; Exporter.save(nil, model: model, range: r, projects: projects, billable: billable) } }
    }

    // Cards: the app's card radius (14), surface, border; titles 14/700. Content sits top-left so cards in a row
    // can stretch to the same height.
    private var card: some View {
        RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface).overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
    }
    private func cardTitle(_ t: String) -> some View { Text(t).font(.system(size: 14, weight: .bold)) }

    // MARK: Header & filters

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Statistics")).font(DS.F.screenTitle)
                Text("\(periodTitle) · " + (projects == nil ? String(localized: "all projects") : String(localized: "\(projects!.count) projects"))).font(DS.F.caption).foregroundStyle(DS.C.text2)
            }
            Spacer()
            Menu {
                Button(String(localized: "Everything (ZIP)")) { Exporter.save(nil, model: model, range: r, projects: projects, billable: billable) }.keyboardShortcut("e")
                Divider()
                ForEach(Exporter.Kind.allCases) { k in
                    Button(k.title) { Exporter.save(k, model: model, range: r, projects: projects, billable: billable) }
                }
            } label: { Label(String(localized: "Export CSV"), systemImage: "square.and.arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.C.text) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(DS.C.text).fixedSize()
            .padding(.horizontal, 12).frame(height: DS.H.regular)
            .background(Capsule().fill(DS.C.surface)).overlay(Capsule().inset(by: 0.5).stroke(DS.C.border, lineWidth: 1))
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }

    private var periodTitle: String {
        if r == DateRange.month(of: r.start) { return Fmt.monthYear(r.start) }
        return "\(Fmt.dayMonth(r.start)) – \(Fmt.dayMonth(r.end)) \(r.end.year)"
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.icon)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.icon)
            filterButton(periodTitle, "calendar", primary: true) { showPeriod = true }
                .surfacePopover(isPresented: $showPeriod, arrowEdge: .bottom) { PeriodPicker(range: Binding(get: { r }, set: { range = $0 })) { showPeriod = false }.environment(model).presentationBackground(DS.C.surface) }
            filterButton(projectFilter == nil ? String(localized: "All projects") : String(localized: "\(projectFilter!.count) projects"), "folder") { showProjects = true }
                .surfacePopover(isPresented: $showProjects, arrowEdge: .bottom) { ProjectFilter(selection: $projectFilter, range: r) { showProjects = false }.environment(model).presentationBackground(DS.C.surface) }
            filterButton(billable == nil ? String(localized: "Billable + non-billable") : (billable! ? String(localized: "Only billable") : String(localized: "Only non-billable")), "doc.text") { showBillable = true }
                .surfacePopover(isPresented: $showBillable, arrowEdge: .bottom) { BillableFilter(billable: $billable) { showBillable = false }.environment(model).presentationBackground(DS.C.surface) }
            Spacer()
        }
    }

    // Filters are the app's secondary pills (height 30); the period label is bold.
    private func filterButton(_ t: String, _ icon: String, primary: Bool = false, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(DS.C.text2)
                Text(t).font(.system(size: 13, weight: primary ? .bold : .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.C.text3)
            }
        }
        .buttonStyle(.pill)
    }

    private func shift(_ n: Int) {
        if r == DateRange.month(of: r.start) {
            range = DateRange.month(of: r.start.adding(months: n))
        } else {
            let len = r.count
            range = DateRange(r.start.adding(days: n * len), r.end.adding(days: n * len))
        }
    }

    @ViewBuilder
    private var breadcrumb: some View {
        if drillProject != nil || drillTask != nil || allTasks {
            HStack(spacing: 6) {
                Button { drillProject = nil; drillTask = nil; allTasks = false } label: { Label(String(localized: "Statistics"), systemImage: "chevron.left") }
                    .buttonStyle(.pill(.secondary, height: DS.H.small)).keyboardShortcut(.escape, modifiers: [])
                if let p = model.project(drillProject) {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(DS.C.text3)
                    Button { drillTask = nil; allTasks = false } label: {
                        HStack(spacing: 4) {
                            Circle().fill(DS.project(p.color)).frame(width: 7, height: 7)
                            Text(p.name).font(DS.F.bodyMedium)
                            Text("· \(p.billable ? String(localized: "billable") : String(localized: "non-billable")) · " + String(localized: "keys \(model.data.rules.filter { $0.projectId == p.id }.map(\.value).joined(separator: ", "))"))
                                .font(DS.F.caption).foregroundStyle(DS.C.text3)
                        }
                    }.buttonStyle(.row)
                }
                if let t = drillTask, let i = model.issue(t) {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(DS.C.text3)
                    KeyName(key: i.key, name: i.summary, nameFont: DS.F.bodyMedium, stacked: false).fixedSize()
                    if let url = model.jiraURL(t) {
                        Link(String(localized: "open in Jira ↗"), destination: url).font(DS.F.caption)
                    }
                }
                if allTasks { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(DS.C.text3); Text(String(localized: "All tasks")).font(DS.F.bodyMedium) }
            }
        }
    }

    // MARK: KPIs

    private var kpis: some View {
        let l = model.ledger
        let last = min(r.end, model.today)
        let past = last >= r.start ? DateRange(r.start, last) : r
        let worked = past.reduce(0) { $0 + lines($1).reduce(0) { $0 + $1.value } }
        let balance = l.liveBalance(r, since: model.dataStart)
        // The running period against what was expected so far (the balance's rule), the whole fund beside it.
        let so = l.soFar(r)
        // Through today, like the month balance (and the "Since …" line in its tooltip).
        let yearBal = l.liveCumulativeBalance(since: model.cumulativeStart, opening: model.settings.openingBalance)
        let util = l.utilization(r, through: model.today)
        let notInJiraLines = past.flatMap { lines($0).filter { let s = l.state(of: $0, lock: model.lock); return s != .synced && s != .locked } }
        let notInJira = notInJiraLines.reduce(0) { $0 + $1.value }
        let needs = model.needYouCount(in: r)
        // "Not in Jira" is a calm amount; "needs you" only counts blockers, in days (audit U1).
        let notInJiraSub = String(localized: "\(notInJiraLines.filter { !$0.isNoIssue }.count) worklogs") + (needs > 0 ? " · " + NeedsYouText.days(needs) : "")
        return HStack(alignment: .top, spacing: 12) {
            kpi(String(localized: "Worked / expected"), DurationFormat.hm(worked), so.isRunning && so.hasMoreToCome
                ? String(localized: "of \(DurationFormat.short(so.expected)) so far · \(DurationFormat.short(so.full)) in all")
                : String(localized: "of \(DurationFormat.short(so.full)) expected"))
                .chartTooltip("stats.kpi.worked", so.isRunning && so.hasMoreToCome ? TooltipContent(
                    title: String(localized: "\(periodTitle) so far"),
                    rows: [.init(label: String(localized: "Worked"), value: DurationFormat.hm(worked), strong: true),
                           .init(label: String(localized: "Expected so far"), value: DurationFormat.short(so.expected)),
                           .init(label: String(localized: "Expected in all"), value: DurationFormat.short(so.full))],
                    note: String(localized: "Today counts once you've worked its hours or the working day is over — as in the balance.")) : nil)
            if drillProject == nil {
                kpi(String(localized: "Balance"), DurationFormat.signed(balance), String(localized: "\(r.count > 31 ? "period" : "month") · \(String(model.today.year)) so far \(DurationFormat.signed(yearBal))"))
                kpi(String(localized: "Utilization"), util.map { DurationFormat.percent($0) } ?? "—", String(localized: "of the full fund · target \(Int(model.settings.utilizationTarget * 100))%"))
                    .chartTooltip("stats.kpi.utilization", utilizationCard(title: String(localized: "Utilization · \(periodTitle)"), range: r))
            } else {
                kpi(String(localized: "Tasks"), "\(taskRows().count)", String(localized: "in this period"))
                kpi(String(localized: "Billable"), model.project(drillProject)?.billable == true ? String(localized: "Yes") : String(localized: "No"), "")
            }
            if model.jiraConnected { kpi(String(localized: "Not in Jira"), DurationFormat.hm(notInJira), notInJiraSub) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func kpi(_ t: String, _ v: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 12)).foregroundStyle(DS.C.text2)
            Text(v).font(DS.F.number(24)).rolls(v)
            Text(s).font(DS.F.caption).foregroundStyle(DS.C.text3).lineLimit(1)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(card)
    }

    // MARK: By project / task

    private struct Share: Identifiable { let id: String; let name: String; let color: String; let billable: Bool; let secs: Seconds; let projectId: UUID?; let issue: IssueRef? }

    private func shares() -> [Share] {
        var out: [String: Share] = [:]
        for d in r {
            for line in lines(d) {
                if drillProject != nil {
                    let i = model.issue(line.issue)
                    let k = i?.id ?? "none"
                    let prev = out[k]?.secs ?? 0
                    out[k] = Share(id: k, name: i.map { "\($0.key) \($0.summary)" } ?? String(localized: "No task"), color: model.project(line.projectId)?.color ?? "slate",
                                   billable: true, secs: prev + line.value, projectId: line.projectId, issue: line.issue)
                } else {
                    let p = model.project(line.projectId)
                    let k = p?.id.uuidString ?? "none"
                    let prev = out[k]?.secs ?? 0
                    out[k] = Share(id: k, name: p?.name ?? String(localized: "No project"), color: p?.color ?? "slate", billable: p?.billable ?? false,
                                   secs: prev + line.value, projectId: p?.id, issue: nil)
                }
            }
        }
        return out.values.sorted { $0.secs > $1.secs }
    }

    private var byProject: some View {
        let s = shares()
        let total = max(1, s.reduce(0) { $0 + $1.secs })
        return VStack(alignment: .leading, spacing: 12) {
            cardTitle(drillProject == nil ? String(localized: "By project") : String(localized: "By task"))
            ForEach(s) { x in
                Button {
                    if let iss = x.issue { drillTask = iss } else if drillProject == nil, let p = x.projectId { drillProject = p }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(DS.project(x.color)).frame(width: 8, height: 8)
                            Text(x.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            if drillProject == nil { Text(x.billable ? String(localized: "billable") : String(localized: "non-billable")).font(DS.F.caption).foregroundStyle(DS.C.text3) }
                            Spacer()
                            Text("\(DurationFormat.hm(x.secs)) · \(Int(Double(x.secs) * 100 / Double(total)))%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(DS.C.surface2)
                                RoundedRectangle(cornerRadius: 4).fill(DS.project(x.color)).frame(width: g.size.width * CGFloat(x.secs) / CGFloat(total))
                            }
                        }
                        .frame(height: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.row)
                .chartTooltip("stats.share.\(x.id)", TooltipContent(
                    title: x.name,
                    rows: [.init(label: String(localized: "Worked"), value: DurationFormat.hm(x.secs), dot: DS.project(x.color)),
                           .init(label: String(localized: "Share"), value: "\(Int(Double(x.secs) * 100 / Double(total)))%")]
                        + (drillProject == nil ? [.init(label: String(localized: "Billable"), value: x.billable ? String(localized: "Yes") : String(localized: "No"))] : []),
                    note: x.issue != nil || drillProject == nil ? String(localized: "Click to see only \(x.name)") : nil))
            }
            if s.isEmpty { Text(String(localized: "Nothing tracked in this period.")).foregroundStyle(DS.C.text3) }
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .topLeading).background(card)
    }

    // MARK: Trend

    private struct TrendBar: Identifiable { let id = UUID(); let week: String; let project: String; let color: String; let hours: Double }

    /// Design trend (s6T1X): no axes or grid — one 44 pt stack per week (largest project at the bottom, 1 pt
    /// between segments), the week's fund as a line across it, labels "W40" ("W40 · 28–30" for a partial week).
    /// At least the last 5 weeks are shown — empty ones too — so a fresh month isn't one lonely bar.
    /// The running week is compared with what was expected so far (`Ledger.soFar`, the balance's rule): its line
    /// sits at the to-date value, a faint dashed line marks the full week (owner 2026-10-07).
    private var trend: some View {
        let l = model.ledger
        struct Week: Identifiable {
            let id: LocalDate; let label: String; let range: DateRange; let parts: [(name: String, color: String, secs: Seconds)]; let so: PeriodSoFar
            var fund: Seconds { so.expected }
        }
        var weeks: [Week] = []
        let lastWeek = min(r.end, model.today).startOfWeek
        let first = min(r.start.startOfWeek, lastWeek.adding(days: -28))
        var w = first
        while w <= lastWeek {
            let full = DateRange(w, w.adding(days: 6))
            // Weeks inside the period are clipped to it; the earlier context weeks are shown whole (up to today).
            let wr = w < r.start.startOfWeek ? DateRange(w, min(full.end, model.today))
                : DateRange(max(w, r.start), max(max(w, r.start), min(full.end, r.end)))
            var per: [String: (String, Seconds)] = [:]
            for d in wr where d <= model.today { for line in lines(d) {
                let p = model.project(line.projectId)
                per[p?.name ?? "—", default: (p?.color ?? "slate", 0)].1 += line.value
            } }
            let parts = per.sorted { $0.value.1 > $1.value.1 }.map { (name: $0.key, color: $0.value.0, secs: $0.value.1) }
            let partial = wr != full
            weeks.append(Week(id: w, label: partial ? "W\(w.weekNumber) · \(wr.start.day)–\(wr.end.day)" : "W\(w.weekNumber)", range: wr, parts: parts, so: l.soFar(wr)))
            w = w.adding(days: 7)
        }
        let top = Double(max(weeks.map { max($0.parts.reduce(0) { $0 + $1.secs }, $0.so.full) }.max() ?? 0, 3600)) * 1.08
        let chartH: CGFloat = 170
        return VStack(alignment: .leading, spacing: 10) {
            cardTitle(String(localized: "Trend by week · vs expected"))
            // Bars fit the card: up to 44 pt wide with 28 pt between (72 pt a week), narrower for a long period —
            // a quarter's 14 weeks at fixed width squeezed By project to a sliver (beta 2026-10-21). Labels shed the
            // day range, then every other week, when there is no room for them.
            GeometryReader { g in
                let slot = min(72, g.size.width / CGFloat(max(weeks.count, 1)))
                let barW = min(44, (slot * 0.62).rounded())
                let ranged = slot >= 72
                let every = max(1, Int((36 / slot).rounded(.up)))
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(weeks.enumerated()), id: \.element.id) { n, wk in
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottom) {
                                Color.clear
                                VStack(spacing: 1) {
                                    ForEach(Array(wk.parts.reversed().enumerated()), id: \.offset) { _, part in
                                        Rectangle().fill(DS.project(part.color)).frame(height: max(1, chartH * CGFloat(Double(part.secs) / top)))
                                    }
                                }
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                                if wk.so.isRunning && wk.so.hasMoreToCome && wk.so.full > 0 {
                                    // The full week, still ahead: faint and dashed.
                                    Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: barW, y: 1)) }
                                        .stroke(DS.C.text3.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                                        .frame(height: 2)
                                        .offset(y: -chartH * CGFloat(Double(wk.so.full) / top))
                                }
                                if wk.fund > 0 {
                                    Capsule().fill(DS.C.text2).frame(height: 2)
                                        .offset(y: -chartH * CGFloat(Double(wk.fund) / top))
                                }
                            }
                            .frame(width: barW, height: chartH)
                            Text(ranged ? wk.label : "W\(wk.id.weekNumber)").font(.system(size: 11).monospacedDigit()).foregroundStyle(DS.C.text3)
                                .lineLimit(1).fixedSize()
                                .opacity(n % every == 0 ? 1 : 0)
                        }
                        // Bars start at the left edge as before; the slot's spare room is the gap after the bar.
                        .frame(width: slot, alignment: ranged ? .leading : .center)
                        .contentShape(Rectangle())
                        .chartTooltip("stats.week.\(wk.id)", weekCard(wk.range, parts: wk.parts, so: wk.so))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: chartH + 20)
            Text(weeks.contains { $0.so.isRunning && $0.so.hasMoreToCome }
                 ? String(localized: "Line on top = expected hours for that week · this week: so far, dashed = full week")
                 : String(localized: "Line on top = expected hours for that week")).font(DS.F.caption).foregroundStyle(DS.C.text3)
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .topLeading).background(card)
    }

    /// "Week 40 · 28 Sep – 4 Oct": worked per project (largest first), total, expected and the difference.
    /// The running week: "Expected so far" (the balance's rule, so ± equals the week balance) and the full week.
    private func weekCard(_ wr: DateRange, parts: [(name: String, color: String, secs: Seconds)], so: PeriodSoFar) -> TooltipContent {
        let worked = parts.reduce(0) { $0 + $1.secs }
        var rows = parts.map { TooltipContent.Row(label: $0.name, value: DurationFormat.hm($0.secs), dot: DS.project($0.color)) }
        rows.append(.init(label: String(localized: "Worked"), value: DurationFormat.hm(worked), strong: true))
        if so.isRunning && so.hasMoreToCome {
            rows.append(.init(label: String(localized: "Expected so far"), value: DurationFormat.short(so.expected)))
            rows.append(.init(label: String(localized: "Full week"), value: DurationFormat.short(so.full)))
            rows.append(.init(label: String(localized: "± so far"), value: DurationFormat.signed(worked - so.expected)))
        } else if so.full > 0 {
            rows.append(.init(label: String(localized: "Expected"), value: DurationFormat.short(so.full)))
            rows.append(.init(label: "±", value: DurationFormat.signed(worked - so.full)))
        }
        return TooltipContent(title: String(localized: "Week \(wr.start.weekNumber) · \(Fmt.dayMonth(wr.start)) – \(Fmt.dayMonth(wr.end))"), rows: rows,
                              note: parts.isEmpty ? String(localized: "Nothing tracked") : nil)
    }

    /// Utilization's parts for `range` (whole past days, today so far): billable ÷ full fund, the target.
    private func utilizationCard(title: String, range: DateRange) -> TooltipContent? {
        let l = model.ledger
        let first = max(range.start, model.dataStart), last = min(range.end, model.today)
        guard last >= first else { return nil }
        let w = DateRange(first, last)
        let fund = l.utilizationFund(w)
        guard fund > 0 else { return nil }
        let billable = l.billableWorked(w)
        return TooltipContent(title: title, rows: [
            .init(label: String(localized: "Billable"), value: DurationFormat.hm(billable)),
            .init(label: String(localized: "Full fund"), value: DurationFormat.hm(fund)),
            .init(label: String(localized: "Utilization"), value: DurationFormat.percent(Double(billable) / Double(fund)), strong: true),
            .init(label: String(localized: "Target"), value: "\(Int((model.settings.utilizationTarget * 100).rounded()))%"),
        ], note: String(localized: "Full fund = workdays without holidays. Absences stay in it, so they lower utilization."))
    }

    // MARK: Utilization bullet bars (decided 2026-10-03)

    private var utilization: some View {
        let l = model.ledger
        let target = model.settings.utilizationTarget
        let endMonth = r.end.firstOfMonth
        let months = (0..<(r.count > 200 ? 12 : 6)).reversed().map { endMonth.adding(months: -$0) }
        return VStack(alignment: .leading, spacing: 8) {
            cardTitle(String(localized: "Utilization · last \(months.count) months"))
            ForEach(months, id: \.self) { m in
                // A month without any data is "—", not 0 % (audit U2).
                let mu = l.monthUtilization(DateRange.month(of: m), since: model.dataStart, through: model.today)
                let u = mu ?? 0
                HStack(spacing: 10) {
                    // Design (sUCXB): bars 12 high r6, target 2 × 18; below target a solid light violet and secondary labels.
                    let onTarget = u >= target
                    Text(Fmt.monthShort(m)).font(.system(size: 11, weight: m == endMonth ? .bold : .regular))
                        .foregroundStyle(onTarget || m == endMonth ? DS.C.text : DS.C.text2).frame(width: 34, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6).fill(DS.C.surface2)
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(DS.C.surface)
                                RoundedRectangle(cornerRadius: 6).fill(DS.C.brand.opacity(onTarget ? 1 : 0.38))
                            }
                            .frame(width: g.size.width * min(1, u / 1.2))
                            Rectangle().fill(DS.C.text).frame(width: 2, height: 18).offset(x: g.size.width * target / 1.2)
                        }
                    }
                    .frame(height: 12)
                    Text(mu.map { DurationFormat.percent($0) } ?? "—").font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(onTarget ? DS.C.text : DS.C.text2).frame(width: 44, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .chartTooltip("stats.util.\(m)", mu == nil ? nil : utilizationCard(
                    title: DateRange.month(of: m).contains(model.today) ? String(localized: "\(Fmt.monthYear(m)) so far") : Fmt.monthYear(m),
                    range: DateRange.month(of: m)))
            }
            Text(String(localized: "Billable share of the full fund — absences lower it · line = \(Int(target * 100))% target")).font(DS.F.caption).foregroundStyle(DS.C.text3)
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .topLeading).background(card)
    }

    // MARK: Heatmap (kept by the user's choice)

    private var heatmap: some View {
        let l = model.ledger
        let start = r.start.startOfWeek
        let weeks = Int(ceil(Double(start.days(until: r.end) + 1) / 7))
        let maxH = Double(max(8 * 3600, r.map { l.worked($0) }.max() ?? 0))
        return VStack(alignment: .leading, spacing: 8) {
            cardTitle(String(localized: "Hours per day · \(r == DateRange.month(of: r.start) ? Fmt.monthName(r.start) : periodTitle)"))
            VStack(spacing: 4) {
                // Weekday labels over the columns (Mon … Sun in the app's language).
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(Fmt.weekdayShort(start.adding(days: i))).font(.system(size: 10, weight: .medium)).foregroundStyle(DS.C.text3)
                            .lineLimit(1).frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<min(weeks, 6), id: \.self) { w in
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { i in
                            let d = start.adding(days: w * 7 + i)
                            let inRange = r.contains(d) && d <= model.today
                            let worked = inRange ? Double(lines(d).reduce(0) { $0 + $1.value }) : 0
                            let fund = l.fund(d)
                            // A past workday with nothing tracked at all (the filters don't make a day "missed").
                            let missed = inRange && d < model.today && d >= model.dataStart && fund > 0 && l.worked(d) == 0
                            RoundedRectangle(cornerRadius: 4)
                                .fill(!inRange ? Color.clear : (fund == 0 && worked == 0 ? DS.C.surface2 : DS.C.brand.opacity(0.15 + 0.85 * min(1, worked / maxH))))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(missed ? DS.C.warning : (inRange ? .clear : DS.C.border.opacity(0.5)), lineWidth: missed ? 1.5 : 0.5))
                                .frame(height: 22)
                                .chartTooltip("stats.heat.\(d)", inRange ? TooltipContent(
                                    title: d == model.today ? String(localized: "Today · \(Fmt.short(d))") : Fmt.short(d),
                                    rows: [.init(label: String(localized: "Worked"), value: DurationFormat.hm(Int(worked)), strong: true),
                                           .init(label: String(localized: "Expected"), value: DurationFormat.short(fund)),
                                           // Today as in the balance: no shortfall until the working day is over.
                                           .init(label: String(localized: "Day ±"), value: DurationFormat.signed(Int(worked) - l.expectedSoFar(d)))],
                                    note: missed ? String(localized: "Nothing tracked · click to open the day")
                                        : d == model.today && l.expectedSoFar(d) < fund ? String(localized: "So far today · a shortfall counts once the working day is over")
                                        : String(localized: "Click to open the day")) : nil)
                                .onTapGesture { if inRange { model.selectedDay = d; model.mainSelection = .day } }
                                // The hover card speaks for the day; "amber outline" is said in its note, not only by colour.
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { if inRange { model.selectedDay = d; model.mainSelection = .day } }
                                .accessibilityHidden(!inRange)
                        }
                    }
                }
            }
            Text(String(localized: "Darker = more hours · grey = nothing expected · amber outline = nothing tracked")).font(DS.F.caption).foregroundStyle(DS.C.text3)
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .topLeading).background(card)
    }

    // MARK: Tasks

    struct TaskRow: Identifiable {
        var id: String { ref.map { "\($0.instanceId)|\($0.issueId)" } ?? "none" }
        let ref: IssueRef?
        let secs: Seconds
        let last: LocalDate
        let projectId: UUID?
    }

    private func taskRows() -> [TaskRow] {
        var acc: [String: TaskRow] = [:]
        for d in r {
            for line in lines(d) where !line.isNoIssue {
                let k = "\(line.issue!.instanceId)|\(line.issue!.issueId)"
                let prev = acc[k]
                acc[k] = TaskRow(ref: line.issue, secs: (prev?.secs ?? 0) + line.value, last: max(prev?.last ?? d, d), projectId: line.projectId)
            }
        }
        return acc.values.sorted { $0.secs > $1.secs }
    }

    private func taskDrill(_ t: IssueRef) -> some View {
        let i = model.issue(t)
        let l = model.ledger
        let days = r.filter { !lines($0).isEmpty }
        let mine = days.reduce(0) { $0 + lines($1).reduce(0) { $0 + $1.value } }
        let notIn = days.reduce(0) { $0 + lines($1).filter { l.state(of: $0, lock: model.lock) != .synced }.reduce(0) { $0 + $1.value } }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                kpi(String(localized: "My hours"), DurationFormat.hm(mine), periodTitle)
                kpi(String(localized: "Spent / estimate (all)"), "\(DurationFormat.short(i?.timeSpentSeconds ?? 0)) / \(i?.originalEstimateSeconds.map(DurationFormat.short) ?? "—")", "")
                kpi(String(localized: "Status in Jira"), i?.statusName ?? "—", "")
                kpi(String(localized: "Not in Jira"), DurationFormat.hm(notIn), "")
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "Days")).font(.system(size: 14, weight: .bold)).padding(16)
                ForEach(days, id: \.self) { d in
                    let ls = lines(d)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Button { if expandedDays.contains(d) { expandedDays.remove(d) } else { expandedDays.insert(d) } } label: {
                                Image(systemName: expandedDays.contains(d) ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                            }.buttonStyle(.icon)
                            .accessibilityLabel(expandedDays.contains(d) ? String(localized: "Hide entries") : String(localized: "Show entries"))
                            Button(Fmt.short(d)) { model.selectedDay = d; model.mainSelection = .day }.buttonStyle(.row).font(DS.F.bodyMedium).frame(width: 110, alignment: .leading)
                            Text(ls.map(\.commentLine).joined(separator: "; ")).font(DS.F.caption).foregroundStyle(DS.C.text2).lineLimit(1)
                            Spacer()
                            Text(DurationFormat.hm(ls.reduce(0) { $0 + $1.value })).font(DS.F.mono)
                            StateMark(status: ls.allSatisfy { l.state(of: $0, lock: model.lock) == .synced || l.state(of: $0, lock: model.lock) == .locked } ? .allInJira : .waiting).frame(width: 18)
                        }
                        .padding(.horizontal, 16).frame(height: 32)
                        .accessibilityElement(children: .combine)
                        if expandedDays.contains(d) {
                            ForEach(ls.flatMap(\.entries)) { e in
                                HStack {
                                    Text(Fmt.range(e.start, e.end)).font(DS.F.mono).foregroundStyle(DS.C.text3).frame(width: 110, alignment: .leading)
                                    DescriptionLabel(text: e.description, font: DS.F.caption)
                                    Spacer()
                                    Text(DurationFormat.short(e.duration(now: model.now))).font(DS.F.mono)
                                }
                                .padding(.leading, 42).padding(.trailing, 34).frame(height: 24)
                            }
                        }
                        Divider().opacity(0.5)
                    }
                }
            }
            .background(card)
        }
    }

    private var notEnoughData: some View {
        VStack(spacing: 12) {
            Spacer()
            Illustration(name: "illGrowing", width: 280)
            Text(String(localized: "Statistics need a little history")).font(DS.F.screenTitle)
            Text(String(localized: "Track for a week — or bring in what's already in Jira.")).foregroundStyle(DS.C.text2)
            if model.jiraConnected {
                Button(String(localized: "Import history from Jira")) { AppDelegate.shared?.windows.showSettings(model, tab: .jira) }.buttonStyle(.primaryPill)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct TasksTable: View {
    @Environment(AppModel.self) private var model
    let rows: [StatisticsScreen.TaskRow]
    let limit: Int?
    let open: (IssueRef?) -> Void
    @State private var sortByHours = true

    var body: some View {
        let shown = Array((sortByHours ? rows : rows.sorted { ($0.last) > ($1.last) }).prefix(limit ?? rows.count))
        let total = max(1, rows.reduce(0) { $0 + $1.secs })
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "TASK")).frame(maxWidth: .infinity, alignment: .leading)
                Button(String(localized: "MY HOURS")) { sortByHours = true }.buttonStyle(.row).frame(width: 110, alignment: .leading)
                Text(String(localized: "SPENT / ESTIMATE (ALL)")).frame(width: 170, alignment: .leading)
                Text(String(localized: "STATUS")).frame(width: 110, alignment: .leading)
                Button(String(localized: "LAST LOGGED")) { sortByHours = false }.buttonStyle(.row).frame(width: 100, alignment: .leading)
            }
            .font(DS.F.sectionLabel).foregroundStyle(DS.C.text3).frame(height: 26)
            ForEach(shown) { row in
                let i = model.issue(row.ref)
                let over = (i?.originalEstimateSeconds).map { (i?.timeSpentSeconds ?? 0) > $0 } ?? false
                HStack {
                    HStack(spacing: 6) {
                        Circle().fill(DS.project(model.project(row.projectId)?.color ?? "slate")).frame(width: 7, height: 7)
                        KeyName(key: i?.key ?? "", name: i?.summary ?? "")
                        if limit == nil {
                            Capsule().fill(DS.C.brand.opacity(0.3)).frame(width: CGFloat(row.secs) / CGFloat(total) * 80, height: 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(DurationFormat.hm(row.secs)).font(DS.F.monoMedium).frame(width: 110, alignment: .leading)
                    HStack(spacing: 3) {
                        if over { Image(systemName: "exclamationmark.triangle").foregroundStyle(DS.C.danger).font(.system(size: 10)) }
                        Text("\(DurationFormat.short(i?.timeSpentSeconds ?? 0)) / \(i?.originalEstimateSeconds.map(DurationFormat.short) ?? "—")").font(DS.F.mono)
                    }
                    .frame(width: 170, alignment: .leading)
                    Text(i?.statusName ?? "").font(DS.F.caption).foregroundStyle(DS.C.text2).frame(width: 110, alignment: .leading)
                    Text(Fmt.dayName(row.last, today: model.today)).font(DS.F.caption).frame(width: 100, alignment: .leading)
                }
                .frame(height: 34)
                .contentShape(Rectangle())
                .onTapGesture { open(row.ref) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([
                    "\(i?.key ?? "") \(i?.summary ?? "")",
                    String(localized: "my hours \(DurationFormat.hm(row.secs))"),
                    String(localized: "spent \(DurationFormat.short(i?.timeSpentSeconds ?? 0)) of estimate \(i?.originalEstimateSeconds.map(DurationFormat.short) ?? "—")"),
                    over ? String(localized: "over the estimate") : nil,
                    i?.statusName,
                    String(localized: "last logged \(Fmt.dayName(row.last, today: model.today))"),
                ].compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(row.ref) }
                .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border.opacity(0.6)).frame(height: 0.5) }
                .help(String(localized: "Open ›"))
            }
        }
        .padding(limit == nil ? 16 : 0)
        .background(limit == nil ? RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface) : nil)
    }
}

/// Period popover (design "Statistics · filter period"): presets on the left (a click applies), on the right
/// From → To boxes over a two-month calendar; a click sets the active box (From, then To), Apply takes the range.
struct PeriodPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var range: DateRange
    let done: () -> Void
    @State private var from = LocalDate(year: 2000, month: 1, day: 1)
    @State private var to = LocalDate(year: 2000, month: 1, day: 1)
    @State private var editingTo = false
    @State private var shown = LocalDate(year: 2000, month: 1, day: 1)   // left month

    var body: some View {
        let t = model.today
        let presets: [(String, String, DateRange)] = [
            (String(localized: "This week"), "W\(t.weekNumber)", DateRange.week(of: t)),
            (String(localized: "Last week"), "W\(t.adding(days: -7).weekNumber)", DateRange.week(of: t.adding(days: -7))),
            (String(localized: "This month"), Fmt.monthShort(t), DateRange.month(of: t)),
            (String(localized: "Last month"), Fmt.monthShort(t.adding(months: -1)), DateRange.month(of: t.firstOfMonth.adding(months: -1))),
            (String(localized: "This quarter"), "Q\((t.month - 1) / 3 + 1)", DateRange(t.firstOfQuarter, t.firstOfQuarter.adding(months: 3).adding(days: -1))),
            (String(localized: "Last quarter"), "Q\((t.firstOfQuarter.adding(months: -3).month - 1) / 3 + 1)", DateRange(t.firstOfQuarter.adding(months: -3), t.firstOfQuarter.adding(days: -1))),
            (String(localized: "This year"), String(t.year), DateRange(t.firstOfYear, LocalDate(year: t.year, month: 12, day: 31))),
            (String(localized: "Last 12 months"), "", DateRange(t.adding(months: -12).adding(days: 1), t)),
        ]
        let draft = DateRange(min(from, to), max(from, to))
        let isPreset = presets.contains { $0.2 == draft }
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(presets, id: \.0) { p in
                    let on = draft == p.2
                    Button { range = p.2; done() } label: {
                        HStack {
                            Text(p.0).font(DS.F.body).foregroundStyle(on ? DS.C.brandText : DS.C.text)
                            Spacer()
                            if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.brandText) }
                            else { Text(p.1).font(DS.F.mono).foregroundStyle(DS.C.text3) }
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: DS.R.row).fill(on ? DS.C.brandSoft : .clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.row)
                }
                HStack {
                    Text(String(localized: "Custom range")).font(DS.F.body).foregroundStyle(isPreset ? DS.C.text : DS.C.brandText)
                    Spacer()
                    Text("…").font(DS.F.mono).foregroundStyle(DS.C.text3)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: DS.R.row).fill(isPreset ? .clear : DS.C.brandSoft))
            }
            .padding(10).frame(width: 190)
            .background(DS.C.surface2.opacity(0.6))
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    DateBox(label: String(localized: "FROM"), date: from, active: !editingTo) { editingTo = false }
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(DS.C.text3)
                    DateBox(label: String(localized: "TO"), date: to, active: editingTo) { editingTo = true }
                }
                ZStack(alignment: .top) {
                    HStack(alignment: .top, spacing: 24) {
                        MonthGrid(month: shown, range: draft) { pick($0) }
                        MonthGrid(month: shown.adding(months: 1), range: draft) { pick($0) }
                    }
                    HStack {
                        Button { shown = shown.adding(months: -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.icon)
                        Spacer()
                        Button { shown = shown.adding(months: 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.icon)
                    }
                }
                Divider()
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Fmt.dayMonth(draft.start)) – \(Fmt.dayMonthYear(draft.end))").font(DS.F.bodySemibold)
                        let days = String(localized: "\(draft.count) days"), workdays = String(localized: "\(model.dayCalendar.workdays(in: draft).count) workdays")
                        Text(String(localized: "\(days) · \(workdays) · expected \(DurationFormat.short(model.ledger.fund(draft)))"))
                            .font(DS.F.caption).foregroundStyle(DS.C.text2)
                    }
                    Spacer()
                    Button(String(localized: "Cancel"), action: done).buttonStyle(LinkButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(String(localized: "Apply")) { range = draft; done() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .onAppear {
            from = range.start; to = range.end
            shown = range.start.firstOfMonth
        }
    }

    private func pick(_ d: LocalDate) {
        if editingTo {
            if d < from { to = from; from = d } else { to = d }
            editingTo = false
        } else {
            from = d
            if to < d { to = d }
            editingTo = true
        }
    }
}

/// Project filter (design "Statistics · filter projects"): search, All projects (mixed when some are picked) with
/// "Only billable", the projects with their hours in the period, archived ones last; footer "2 of 7 · 68h 40m".
struct ProjectFilter: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<UUID>?
    let range: DateRange
    let done: () -> Void
    @State private var q = ""

    var body: some View {
        let all = model.data.projects
        let hours = Dictionary(uniqueKeysWithValues: all.map { p in (p.id, range.reduce(0) { d, day in d + model.ledger.lines(on: day).filter { $0.projectId == p.id }.reduce(0) { $0 + $1.value } }) })
        let match = all.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        let active = match.filter { !$0.archived }.sorted { (-(hours[$0.id] ?? 0), $0.name) < (-(hours[$1.id] ?? 0), $1.name) }
        let archived = match.filter(\.archived).sorted { $0.name < $1.name }
        let picked = selection ?? Set(all.map(\.id))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(DS.C.text3)
                TextField(String(localized: "Search projects"), text: $q).textFieldStyle(.plain).font(DS.F.body)
            }
            .padding(.horizontal, 12).frame(height: 36)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Button { selection = selection == nil ? [] : nil } label: {
                        HStack(spacing: 10) {
                            BoxCheck(state: selection == nil ? .on : (picked.isEmpty ? .off : .mixed))
                            Text(String(localized: "All projects")).font(DS.F.bodySemibold).foregroundStyle(DS.C.text)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Spacer()
                    Button(String(localized: "Only billable")) { selection = Set(all.filter(\.billable).map(\.id)) }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                }
                .padding(.horizontal, 8).frame(height: 32)
                ForEach(active) { row($0, hours: hours[$0.id] ?? 0, picked: picked) }
                if !archived.isEmpty {
                    Divider().padding(.vertical, 4)
                    SectionLabel(String(localized: "Archived")).padding(.horizontal, 8).padding(.bottom, 2)
                    ForEach(archived) { row($0, hours: hours[$0.id] ?? 0, picked: picked) }
                }
            }
            .padding(6)
            Divider()
            HStack {
                let n = all.filter { picked.contains($0.id) }
                Text(String(localized: "\(n.count) of \(all.count) · \(DurationFormat.short(n.reduce(0) { $0 + (hours[$1.id] ?? 0) }))"))
                    .font(DS.F.caption).foregroundStyle(DS.C.text2)
                Spacer()
                Button(String(localized: "Clear")) { selection = nil }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                Button(String(localized: "Done"), action: done).buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(width: 300)
    }

    private func row(_ p: Project, hours: Int, picked: Set<UUID>) -> some View {
        let on = picked.contains(p.id)
        return Button {
            var s = selection ?? Set(model.data.projects.map(\.id))
            if on { s.remove(p.id) } else { s.insert(p.id) }
            selection = s.count == model.data.projects.count ? nil : s
        } label: {
            HStack(spacing: 10) {
                BoxCheck(state: on ? .on : .off)
                Circle().fill(DS.project(p.color)).frame(width: 7, height: 7).opacity(p.archived ? 0.5 : 1)
                Text(p.name).font(DS.F.body).foregroundStyle(p.archived ? DS.C.text3 : DS.C.text).lineLimit(1)
                Spacer()
                Text(hours > 0 ? DurationFormat.padded(hours) : "–").font(DS.F.mono).foregroundStyle(DS.C.text2)
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(on && selection != nil ? DS.C.brandSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }
}

/// The design's checkbox: rounded square, brand fill when on, a minus when mixed.
struct BoxCheck: View {
    enum State { case off, on, mixed }
    let state: State
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(state == .off ? DS.C.surface : DS.C.brand)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(state == .off ? DS.C.borderStrong : DS.C.brand, lineWidth: 1))
            .overlay {
                if state != .off {
                    Image(systemName: state == .on ? "checkmark" : "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.C.onBrand)
                }
            }
            .frame(width: 16, height: 16)
    }
}

/// Billable filter (design "Statistics · filter billable"): three radio rows with the projects each one means.
struct BillableFilter: View {
    @Environment(AppModel.self) private var model
    @Binding var billable: Bool?
    let done: () -> Void

    var body: some View {
        // Just the three choices — listing the projects under each grew too long (owner 2026-10-08).
        let options: [(Bool?, String, String)] = [
            (nil, String(localized: "Billable + non-billable"), ""),
            (true, String(localized: "Only billable"), ""),
            (false, String(localized: "Only non-billable"), ""),
        ]
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(options, id: \.1) { o in
                    let on = billable == o.0
                    Button { billable = o.0; done() } label: {
                        HStack(alignment: .center, spacing: 10) {
                            ZStack {
                                Circle().strokeBorder(on ? DS.C.brand : DS.C.borderStrong, lineWidth: on ? 5 : 1).frame(width: 16, height: 16)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.1).font(DS.F.bodySemibold).foregroundStyle(DS.C.text)
                                if !o.2.isEmpty { Text(o.2).font(DS.F.caption).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: DS.R.row).fill(on ? DS.C.brandSoft : .clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.row)
                }
            }
            .padding(6)
            Divider()
            Text(String(localized: "Billable comes from the project — change it in Projects.")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 280)
    }

}
