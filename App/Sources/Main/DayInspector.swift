import SwiftUI
import SyncEngine
import TikjotDomain
import TikjotPersistence

/// Inspector (§7.3): entry · multi-select · Day panel when nothing is selected.
struct DayInspector: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate

    var body: some View {
        let sel = model.selectedEntries.filter { LocalDate($0.start, calendar: .current) == day }
        GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sel.count == 1, let e = sel.first {
                    if e.kind == .breakTime {
                        BreakInspector(entry: e)
                    } else {
                        EntryInspector(entry: e, day: day).id(e.id)
                    }
                } else if sel.count > 1 {
                    MultiInspector(entries: sel, day: day)
                } else {
                    DayPanel(day: day)
                }
            }
            .padding(20)
            // Fill the column so the shortcuts line sits at the bottom.
            .frame(minHeight: geo.size.height, alignment: .top)
        }
        }
    }
}

struct BreakInspector: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(String(localized: "Break"))
            Text(String(localized: "\(Fmt.range(entry.start, entry.end)) · doesn't count, never sent")).font(DS.F.body)
            Button(String(localized: "Remove break")) { model.delete([entry]) }.buttonStyle(.dangerPill)
        }
    }
}

struct EntryInspector: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    let day: LocalDate
    @State private var desc = ""
    @State private var start = Clock.now
    @State private var end = Clock.now
    @State private var length = 0
    @State private var picking = false
    @State private var commandOverTask = false
    @State private var jiraLinkHover = false
    @State private var overlapChoice: OverlapChoices.Choice = .keepBoth
    @FocusState private var descFocused: Bool
    @State private var suggestion: Int?

    var body: some View {
        let locked = !model.lock.canEditEntries(on: day, today: model.today)
        let current = model.data.entries.first { $0.id == entry.id } ?? entry
        let issue = model.issue(for: current)
        let project = model.project(current.projectId)
        let line = model.ledger.lines(on: day).first { $0.entries.contains { $0.id == entry.id } }
        let state = line.map { model.ledger.state(of: $0, lock: model.lock) }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionLabel(String(localized: "Entry"))
                Spacer()
                if let state { StateBadge(state: state, imported: current.source == .imported) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Description")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                DescriptionEditField(placeholder: String(localized: "What did you do?"), text: $desc, entry: current,
                                     focused: $descFocused, highlighted: $suggestion, locked: locked, focusedStyle: descFocused,
                                     identifier: "inspector.description", maxLines: 8, submit: saveDescription) { s in
                    // An earlier entry: its description and its task.
                    saveDescription()
                    if let x = model.data.entries.first(where: { $0.id == entry.id }) {
                        model.setTask(model.issue(instanceId: s.instanceId, issueId: s.issueId), projectId: s.projectId, for: [x])
                    }
                }
                .onChange(of: descFocused) { _, f in if !f { saveDescription() } }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(localized: "Task")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    Spacer()
                    // Beta 2026-10-25: a quiet link next to the label, only when the entry has a task.
                    // Quiet until you point at it (owner 2026-10-25: brand text read like the main action).
                    if let url = model.jiraURL(current.issueRef) {
                        Link(destination: url) {
                            HStack(spacing: 2) {
                                Text(String(localized: "Open in Jira")).underline(jiraLinkHover)
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(jiraLinkHover ? DS.C.brandText : DS.C.text3)
                        }
                        .onHover { jiraLinkHover = $0 }
                        .help(String(localized: "Open \(issue?.key ?? "") in Jira"))
                        .accessibilityIdentifier("inspector.openInJira")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    taskField(issue: issue, project: project, locked: locked)
                    if let project {
                        Text("\(project.name) · \(project.billable ? String(localized: "billable") : String(localized: "non-billable"))")
                            .font(DS.F.caption).foregroundStyle(DS.C.text3)
                    }
                    if let issue, issue.availability != .ok {
                        BannerView(kind: .warning, icon: "exclamationmark.triangle", text: String(localized: "This task isn't available in Jira any more."),
                                   action: String(localized: "Pick another task")) { picking = true }
                    }
                }
                    // Design Ozx1Y: the picker drops down over what's below instead of pushing it. On the whole group,
                    // so the project line under the field can't draw through it.
                    .overlay(alignment: .topLeading) {
                        if picking {
                            TaskPicker(seed: desc, currentKey: issue?.key, preferProject: current.projectId) { i, p in
                                model.setTask(i, projectId: p, for: [current])
                                picking = false
                            } onCancel: { picking = false }
                                .padding(.vertical, 8).padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                                .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border, lineWidth: 1))
                                .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, -9)
                                .offset(y: DS.H.field + 4)
                                .transition(.opacity)
                        }
                    }
            }
            .zIndex(1)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Time")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                HStack(spacing: 8) {
                    TimeField(label: String(localized: "Start"), date: $start, day: day, readOnly: locked) { saveTimes() }
                    if current.isRunning {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "END")).font(DS.F.sectionLabel).foregroundStyle(DS.C.text3)
                            Text(String(localized: "now")).font(DS.F.monoBig).foregroundStyle(DS.C.tickText).frame(height: DS.H.field)
                        }
                    } else {
                        TimeField(label: String(localized: "End"), date: $end, day: day, readOnly: locked) { saveTimes() }
                        LengthField(label: String(localized: "Length"), seconds: $length, readOnly: locked) {
                            end = start.addingTimeInterval(TimeInterval(length)); saveTimes()
                        }
                    }
                }
            }
            if let o = overlap(current), !locked {
                OverlapChoices(other: o.0, otherTitle: o.0.description.isEmpty ? model.taskLabel(for: o.0) : o.0.description,
                               overlap: o.1, thisEnd: current.effectiveEnd(now: model.now), choice: $overlapChoice)
                if overlapChoice != .keepBoth {
                    HStack { Spacer(); Button(String(localized: "Apply")) { applyOverlap(current, o.0) }.buttonStyle(.primaryPill) }
                }
            }
            if let line, !line.isNoIssue { JiraBox(line: line, state: state ?? .unsent) }
            if !locked {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Actions")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    // Design `inspector/actions` (T4RLn): 6 pt gaps, 30 pt buttons.
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            actionButton(String(localized: "Continue"), "play") { model.continueEntry(current); model.selectedDay = model.today }
                            actionButton(String(localized: "Merge"), "arrow.triangle.merge") { model.mergeSelectionWithPrevious() }
                                .disabled(current.isRunning)
                                .help(current.isRunning ? AppModel.mergeRefusal(.running) : String(localized: "Merge with the previous entry of the same task (M)"))
                        }
                        GridRow {
                            actionButton(String(localized: "Split…"), "scissors") { model.splitRequest = current.id }.disabled(current.isRunning)
                                .help(String(localized: "Split this entry in two (S)"))
                            Button(role: .destructive) { model.delete([current]) } label: {
                                Label(String(localized: "Delete"), systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(PillButtonStyle(kind: .danger, height: 30))
                            .help(String(localized: "Delete this entry (⌫)"))
                        }
                    }
                }
            } else {
                Well { Label(String(localized: "This day is locked — read-only. Jira changes still arrive, marked."), systemImage: "lock").font(DS.F.caption) }
            }
            Spacer(minLength: 16)
            ShortcutsLink()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { load(current) }
        .onChange(of: model.version) { _, _ in if !descFocused, let e = model.data.entries.first(where: { $0.id == entry.id }) { load(e) } }
        .onChange(of: model.inspectorPickTask) { _, v in if v { picking = true; model.inspectorPickTask = false } }
    }

    /// The Task field: `● KEY Name ⌄` on surface-2; without a task an amber-outlined `○ No task` with a "Pick task" pill (Ozx1Y).
    private func taskField(issue: Issue?, project: Project?, locked: Bool) -> some View {
        let jira = model.jiraURL(entry.issueRef) != nil && issue != nil
        let link = commandOverTask && jira
        return Button {
            // As in the popover: ⌘-click opens the task in Jira (also on a locked day), a plain click picks another.
            if NSEvent.modifierFlags.contains(.command), jira { model.openInJira(entry.issueRef); return }
            if !locked { picking.toggle() }
        } label: {
            HStack(spacing: 6) {
                if let issue {
                    Circle().fill(DS.project(project?.color ?? "slate")).frame(width: 7, height: 7)
                    KeyName(key: issue.key, name: issue.summary, stacked: false, link: link)
                    Spacer(minLength: 4)
                    if link {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.C.brandText)
                    } else if !locked {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.C.text2)
                    }
                } else {
                    Image(systemName: "circle.dashed").font(.system(size: 12)).foregroundStyle(DS.C.text3)
                    Text(String(localized: "No task")).font(.system(size: 12)).foregroundStyle(DS.C.text2)
                    Spacer(minLength: 4)
                    if !locked {
                        Label(String(localized: "Pick task"), systemImage: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.onBrand)
                            .padding(.horizontal, 10).frame(height: DS.H.small)
                            .background(Capsule().fill(DS.C.brand))
                    }
                }
            }
            .padding(.leading, 10).padding(.trailing, issue == nil && !locked ? 4 : 10).frame(height: DS.H.field)
            .background(RoundedRectangle(cornerRadius: DS.R.field).fill(issue == nil ? DS.C.surface : DS.C.surface2))
            .overlay {
                if issue == nil && !locked {
                    RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(DS.C.warning, lineWidth: 1.5)
                } else if picking {
                    RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(DS.C.focusRingStrong, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.field)
        .commandHover($commandOverTask)
        .help(!jira ? "" : locked ? String(localized: "⌘-click opens \(issue?.key ?? "") in Jira")
                                  : String(localized: "Change task · ⌘-click opens \(issue?.key ?? "") in Jira"))
    }

    private func load(_ e: TimeEntry) {
        desc = e.description
        start = e.start
        end = e.effectiveEnd(now: model.now)
        length = Int(end.timeIntervalSince(start))
    }

    private func saveDescription() {
        guard var x = model.data.entries.first(where: { $0.id == entry.id }), x.description != desc else { return }
        x.description = desc.trimmingCharacters(in: .newlines)
        model.update(x, name: "Edit description")
    }

    private func saveTimes() {
        guard var x = model.data.entries.first(where: { $0.id == entry.id }) else { return }
        if end <= start { end = start.addingTimeInterval(60) }
        length = Int(end.timeIntervalSince(start))
        x.start = start
        if x.end != nil { x.end = end }
        model.update(x, name: "Change time")
    }

    private func overlap(_ e: TimeEntry) -> (TimeEntry, Seconds)? {
        for o in EntryOps.overlaps(model.ledger.workEntries(on: day), now: model.now) where o.a == e.id || o.b == e.id {
            let other = o.a == e.id ? o.b : o.a
            if let x = model.data.entries.first(where: { $0.id == other }) { return (x, o.seconds) }
        }
        return nil
    }

    private func applyOverlap(_ e: TimeEntry, _ other: TimeEntry) {
        switch overlapChoice {
        case .keepBoth: return
        case .trimThis: model.apply(EntryOps.trim(e, before: other), name: "Trim")
        case .moveOther: model.apply(EntryOps.move(other, after: e, now: model.now), name: "Move after")
        }
        overlapChoice = .keepBoth
    }

    private func actionButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(PillButtonStyle(height: 30))
    }
}

struct StateBadge: View {
    let state: SyncState
    var imported = false
    var body: some View {
        switch state {
        case .synced: Chip(text: imported ? String(localized: "From Jira") : String(localized: "In Jira"), color: DS.C.text, fill: DS.C.successSoft, icon: "checkmark.circle", iconColor: DS.C.success)
        case .unsent: Chip(text: String(localized: "Not sent"), icon: "circle.dashed")
        case .modified: Chip(text: String(localized: "Changed"), color: DS.C.text, fill: DS.C.warningSoft, icon: "circle.dotted", iconColor: DS.C.warning)
        case .error: Chip(text: String(localized: "Failed"), color: DS.C.text, fill: DS.C.dangerSoft, icon: "exclamationmark.circle", iconColor: DS.C.danger)
        case .conflict: Chip(text: String(localized: "Conflict"), color: DS.C.text, fill: DS.C.dangerSoft, icon: "arrow.left.arrow.right", iconColor: DS.C.danger)
        case .remoteDeleted: Chip(text: String(localized: "Deleted in Jira"), color: DS.C.text, fill: DS.C.warningSoft, icon: "trash", iconColor: DS.C.warning)
        case .locked: Chip(text: String(localized: "Locked"), icon: "lock")
        case .noIssue: Chip(text: String(localized: "No task"), color: DS.C.text, fill: DS.C.warningSoft, noTask: true)
        case .pendingDelete: Chip(text: String(localized: "Will be deleted"), icon: "trash")
        }
    }
}

/// Jira box (§7.3 "Jira box in the inspector" mirrors §9.6).
struct JiraBox: View {
    @Environment(AppModel.self) private var model
    let line: WorklogLine
    let state: SyncState

    var body: some View {
        let g = line.group
        let key = model.issue(line.issue)?.key ?? ""
        Well {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(title)
                // Not sent yet (design eNAPI): where it goes, what goes, and the comment.
                // With the timer running, the worklog shows what Review sends now (audit U5).
                if state == .unsent {
                    let part = model.ledger.sendablePart(of: line)
                    let raw = part?.raw ?? line.raw, value = part?.value ?? line.value
                    let n = line.entries.count
                    let amount = line.containsRunning && part == nil ? Self.valueText(line, model.ledger)
                        : (raw == value ? DurationFormat.hm(value) : "\(DurationFormat.hm(raw)) → \(DurationFormat.hm(value))")
                    row(String(localized: "Goes as"), "\(key) · \(Fmt.short(line.date))")
                    row(String(localized: "Worklog"), "\(amount) · " + (n == 1 ? String(localized: "1 entry") : String(localized: "\(n) entries")))
                    if !line.comment.isEmpty { row(String(localized: "Comment"), line.commentLine, truncates: true) }
                } else {
                    // The task (and its key) is right above — the worklog line only needs the day.
                    row(String(localized: "Worklog · \(Fmt.short(line.date))"), Self.valueText(line, model.ledger))
                }
                switch state {
                case .synced, .locked:
                    if let sent = g?.updatedAt { row(String(localized: "Sent"), Fmt.time(sent)) }
                    row(String(localized: "Rounding"), roundingText + " · " + (line.raw == line.value ? String(localized: "no change") : "\(DurationFormat.hm(line.raw)) → \(DurationFormat.hm(line.value))"))
                    if let was = g?.changedInJiraWas { Text(String(localized: "Changed in Jira (was \(DurationFormat.hm(was)))")).font(DS.F.caption).foregroundStyle(DS.C.warningText) }
                case .unsent:
                    reviewButton(key, wide: true)
                case .modified:
                    if let s = g?.lastSent { row(String(localized: "Jira now"), DurationFormat.hm(s.durationSeconds)) }
                    row(String(localized: "After send"), DurationFormat.hm(line.value))
                    reviewButton(key)
                case .error:
                    Text(g?.lastError?.display ?? "").font(DS.F.caption).foregroundStyle(DS.C.dangerText)
                    HStack {
                        // Already in Jira (an update was refused): moving it to another task makes no sense —
                        // leave Jira as it is instead (beta 2026-10-25).
                        if g?.remoteWorklogId != nil {
                            Button(String(localized: "Take Jira's")) { if let id = g?.id { Task { await model.keepJira(id) } } }
                                .buttonStyle(.pill(.secondary, height: DS.H.small)).help(String(localized: "Leave the worklog as it is in Jira — tikjot follows it"))
                        } else {
                            Button(String(localized: "Pick another task")) { model.inspectorPickTask = true }.buttonStyle(.pill(.secondary, height: DS.H.small))
                        }
                        Button(String(localized: "Retry")) { if let id = g?.id { Task { await model.retry(id) } } }.buttonStyle(.pill(.primary, height: DS.H.small))
                    }
                case .conflict:
                    if let r = g?.remoteVersion { row(String(localized: "Jira"), DurationFormat.hm(r.durationSeconds)) }
                    row(String(localized: "Here"), DurationFormat.hm(line.value))
                    HStack {
                        Button(String(localized: "Take Jira's")) { if let id = g?.id { Task { await model.takeJira(id) } } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                        Button(String(localized: "Keep mine")) { if let id = g?.id { Task { await model.keepMine(id) } } }.buttonStyle(.pill(.primary, height: DS.H.small))
                    }
                case .remoteDeleted:
                    Text(String(localized: "Deleted in Jira.")).font(DS.F.caption)
                    HStack {
                        Button(String(localized: "Send again")) { if let id = g?.id { Task { await model.sendAgain(id) } } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                        Button(String(localized: "Remove here")) { if let id = g?.id { Task { await model.removeLocally(id) } } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                    }
                default: EmptyView()
                }
            }
        }
    }

    private var roundingText: String {
        let r = model.settings.rounding
        return r.unitMinutes == 0 ? String(localized: "off") : "\(r.unitMinutes) min, \(r.mode.rawValue)"
    }

    private var title: String {
        switch state {
        case .synced, .locked: return String(localized: "In Jira")
        case .unsent: return String(localized: "Not in Jira yet")
        default: return String(localized: "Jira")
        }
    }

    /// `wide`: the design's full-width secondary button with a brand icon and label (eNAPI); otherwise the small primary pill.
    @ViewBuilder
    private func reviewButton(_ key: String, wide: Bool = false) -> some View {
        let button = Button { if let g = line.group { model.requestReview(groups: [g.id], title: String(localized: "Send \(key) to Jira")) } } label: {
            ViewThatFits(in: .horizontal) {
                Label(String(localized: "Review & send \(key)"), systemImage: "paperplane").fixedSize()
                Label(String(localized: "Review & send"), systemImage: "paperplane")
            }
            .foregroundStyle(wide ? DS.C.brandText : DS.C.onBrand)
            .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
        }
        Group {
            if wide { button.buttonStyle(PillButtonStyle(height: 30)) } else { button.buttonStyle(.pill(.primary, height: DS.H.small)) }
        }
        // The running entry is left out (Review says so) — only a worklog with nothing finished yet waits.
        .disabled(model.ledger.sendablePart(of: line) == nil || !model.jiraConnected)
    }

    /// "1h 40m" — or "1h 40m · +running later" while the timer runs in this worklog; "running" when nothing is finished.
    static func valueText(_ line: WorklogLine, _ l: Ledger) -> String {
        guard line.containsRunning else { return DurationFormat.hm(line.value) }
        guard let part = l.sendablePart(of: line) else { return String(localized: "running") }
        return DurationFormat.hm(part.value) + " · " + String(localized: "+running later")
    }

    // Design rows: label 12 text-secondary, value mono 12/600 (a long comment shortens instead of pushing the label).
    private func row(_ a: String, _ b: String, truncates: Bool = false) -> some View {
        HStack {
            Text(a).font(.system(size: 12)).foregroundStyle(DS.C.text2).lineLimit(1).layoutPriority(truncates ? 1 : 0)
            Spacer(minLength: 8)
            Text(b).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text).lineLimit(1)
                .truncationMode(.tail).fixedSize(horizontal: !truncates, vertical: false)
        }
    }
}

/// One quiet line at the bottom of every inspector state instead of a list of hints (owner 2026-10-25: the actions
/// were there three times — buttons, hints, right-click menu). Opens the Keyboard shortcuts sheet, as ? does.
struct ShortcutsLink: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { model.showShortcuts = true } label: {
            HStack(spacing: 8) {
                Kbd(text: "?")
                Text(String(localized: "All keyboard shortcuts")).font(DS.F.caption).foregroundStyle(hover ? DS.C.text2 : DS.C.text3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityIdentifier("inspector.shortcuts")
    }
}

/// Multi-select (design PeKKi): count, total + span, the entries in a well, Actions (send what can go, one task for
/// all, merge, delete), selection shortcuts at the bottom.
struct MultiInspector: View {
    @Environment(AppModel.self) private var model
    let entries: [TimeEntry]
    let day: LocalDate
    @State private var picking = false

    var body: some View {
        let total = entries.reduce(0) { $0 + $1.duration(now: model.now) }
        let mergeProblem = EntryOps.mergeProblem(entries, within: model.ledger.workEntries(on: day))
        let withTask = entries.filter(\.hasIssue)
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(String(localized: "\(entries.count) entries selected"))
            HStack(alignment: .lastTextBaseline) {
                Text(DurationFormat.hm(total)).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(DS.C.text)
                Spacer(minLength: 8)
                Text(Fmt.range(entries.first!.start, entries.last!.effectiveEnd(now: model.now)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.C.text2)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { e in entryRow(e) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface2))
            if picking {
                TaskPicker(preferProject: entries.first?.projectId) { i, p in model.setTask(i, projectId: p, for: entries); picking = false } onCancel: { picking = false }
            } else if model.lock.canEditEntries(on: day, today: model.today) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Actions")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    if !withTask.isEmpty && model.jiraConnected {
                        let groups = Set(withTask.compactMap(\.worklogGroupId))
                        Button { model.requestReview(groups: groups, title: String(localized: "Send \(groups.count) tasks to Jira")) } label: {
                            actionLabel(groups.count == 1 ? String(localized: "Review & send 1 task") : String(localized: "Review & send \(groups.count) tasks"),
                                        "paperplane", color: DS.C.brandText, icon: DS.C.brand)
                        }
                        .buttonStyle(PillButtonStyle(height: 30))
                        if withTask.count < entries.count { note(sendNote(withTask)) }
                    }
                    Button { picking = true } label: {
                        actionLabel(entries.count == 2 ? String(localized: "Give both one task…") : String(localized: "Give all one task…"), "tag")
                    }
                    .buttonStyle(PillButtonStyle(height: 30))
                    Button { model.mergeSelectionWithPrevious() } label: { actionLabel(String(localized: "Merge"), "arrow.triangle.merge") }
                        .buttonStyle(PillButtonStyle(height: 30)).disabled(mergeProblem != nil)
                    if let mergeProblem { note(AppModel.mergeRefusal(mergeProblem)) }
                    Button(role: .destructive) { model.delete(entries) } label: {
                        actionLabel(String(localized: "Delete \(entries.count) entries"), "trash", color: DS.C.dangerText, icon: DS.C.danger)
                    }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 30))
                }
            }
            Spacer(minLength: 16)
            ShortcutsLink()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Esc clears the selection (the shortcuts sheet lists it); while the picker is open its own Esc goes back.
        .background {
            if !picking {
                Button("") { model.selectedEntryIds = [] }.keyboardShortcut(.cancelAction)
                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func entryRow(_ e: TimeEntry) -> some View {
        let issue = model.issue(for: e)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                DescriptionLabel(text: e.description.isEmpty ? model.taskLabel(for: e) : e.description, font: .system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text(DurationFormat.short(e.duration(now: model.now))).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text)
            }
            HStack(spacing: 5) {
                if let issue {
                    Circle().fill(DS.project(model.project(e.projectId)?.color ?? "slate")).frame(width: 7, height: 7)
                    KeyName(key: issue.key, name: issue.summary, nameFont: .system(size: 11), nameColor: DS.C.text2, spacing: 5, minName: 60, stacked: false)
                } else {
                    Image(systemName: "circle.dashed").font(.system(size: 9)).foregroundStyle(DS.C.text3).frame(width: 10, height: 10)
                    Text(String(localized: "No task")).font(.system(size: 11)).foregroundStyle(DS.C.text2)
                }
            }
        }
    }

    /// "ABC-981 goes; “workshop prep” has no task and stays."
    private func sendNote(_ withTask: [TimeEntry]) -> String {
        var keys: [String] = []
        for e in withTask { if let k = model.issue(for: e)?.key, !keys.contains(k) { keys.append(k) } }
        let goes = keys.count == 1 ? String(localized: "\(keys[0]) goes") : String(localized: "\(keys.joined(separator: ", ")) go")
        let left = entries.filter { !$0.hasIssue }
        let stays = left.count == 1
            ? String(localized: "“\(left[0].description.isEmpty ? model.taskLabel(for: left[0]) : left[0].description)” has no task and stays.")
            : String(localized: "\(left.count) entries have no task and stay.")
        return "\(goes); \(stays)"
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DS.F.caption).foregroundStyle(DS.C.text3).fixedSize(horizontal: false, vertical: true)
    }

    private func actionLabel(_ title: String, _ systemImage: String, color: Color? = nil, icon: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(icon ?? color ?? DS.C.text)
            Text(title).foregroundStyle(color ?? DS.C.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Nothing selected → Day panel (design W2BOOK): DAY + status chip, worked of fund with a bar, a 3-row summary,
/// tasks today (and time without a task), absences, Add absence, shortcuts at the bottom.
struct DayPanel: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    @State private var addAbsence = false
    @State private var overview = false

    var body: some View {
        let l = model.ledger
        let cal = model.dayCalendar
        let worked = l.worked(day), fund = l.fund(day)
        let type = cal.dayType(day)
        let dayOff = type == .weekend || type == .holiday
        let lines = l.lines(on: day).filter { !$0.isNoIssue }
        let tasks = Dictionary(grouping: lines, by: { $0.issue! })
        let notSent = l.lines(on: day).filter { !$0.isNoIssue && ![.synced, .locked].contains(l.state(of: $0, lock: model.lock)) }.count
        // Needs you = blocks sending (audit U1); everything else not sent is a calm "not in Jira".
        let need = NeedsYouText.items(model.needsYou(on: day))
        let absences = model.absences(on: day)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(String(localized: "DAY")).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text3)
                Spacer()
                if type == .holiday {
                    StatusBadge(text: String(localized: "Holiday"), icon: "sun.max", iconColor: DS.C.brand, fill: DS.C.brandSoft)
                } else if type == .weekend {
                    StatusBadge(text: String(localized: "Weekend"), icon: "cup.and.saucer", iconColor: DS.C.text2, fill: DS.C.surface2)
                } else if let need {
                    StatusBadge(text: need, icon: "exclamationmark.circle", iconColor: DS.C.warning, fill: DS.C.warningSoft)
                } else if notSent > 0 && model.jiraConnected {
                    StatusBadge(text: String(localized: "\(notSent) worklogs not in Jira"), icon: "circle.dotted", iconColor: DS.C.text2, fill: DS.C.surface2)
                } else if worked > 0 && model.jiraConnected && day <= model.today {
                    StatusBadge(text: String(localized: "In Jira"), icon: "checkmark.circle", iconColor: DS.C.success, fill: DS.C.successSoft)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DurationFormat.hm(worked)).font(DS.F.number(20)).foregroundStyle(DS.C.text)
                    Spacer()
                    Text(String(localized: "of \(DurationFormat.short(fund)) expected")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(DS.C.surface2)
                        RoundedRectangle(cornerRadius: 3).fill(DS.C.brand)
                            .frame(width: g.size.width * min(1, fund > 0 ? CGFloat(worked) / CGFloat(fund) : (worked > 0 ? 1 : 0)))
                    }
                }
                .frame(height: 6)
            }
            .padding(.bottom, 8)   // room before the task list (owner 2026-10-14)
            // Expected / rounded / day balance were here — the toolbar has them (owner 2026-10-14: simpler panel).
            let noTask = l.noIssueSeconds(day)
            if !tasks.isEmpty || noTask > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    // What you did, in words, is in the Day overview (owner 2026-10-14: descriptions here made it full).
                    Text(String(localized: "Tasks today")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    // Stable order (most time first): dictionary order changes on every launch.
                    let total = { (r: IssueRef) in tasks[r]!.reduce(0) { $0 + $1.value } }
                    let refs = tasks.keys.sorted { (total($0), model.issue($1)?.key ?? "") > (total($1), model.issue($0)?.key ?? "") }
                    ForEach(refs, id: \.self) { ref in
                        let ls = tasks[ref]!
                        let i = model.issue(ref)
                        HStack(spacing: 6) {
                            Circle().fill(DS.project(model.project(ls.first?.projectId)?.color ?? "slate")).frame(width: 8, height: 8)
                            KeyName(key: i?.key ?? "", name: i?.summary ?? "", nameFont: .system(size: 12), minName: 60, stacked: false)
                            Spacer(minLength: 4)
                            Text(DurationFormat.short(ls.reduce(0) { $0 + $1.value })).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            StateMark(status: ls.allSatisfy { model.ledger.state(of: $0, lock: model.lock) == .synced } ? .allInJira : .waiting)
                                .frame(width: 16)
                        }
                        .frame(height: 28)
                    }
                    if noTask > 0 {
                        HStack(spacing: 6) {
                            NoTaskMark(size: 11).frame(width: 8)
                            Text(String(localized: "No task")).font(.system(size: 12)).foregroundStyle(DS.C.text2)
                            Spacer(minLength: 4)
                            Text(DurationFormat.short(noTask)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Color.clear.frame(width: 16, height: 1)
                        }
                        .frame(height: 28)
                    }
                }
            }
            if !absences.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Absences")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    ForEach(absences) { a in
                        HStack(spacing: 6) {
                            Image(systemName: model.absenceType(a.typeId)?.icon ?? "calendar").font(.system(size: 12)).foregroundStyle(DS.C.brand).frame(width: 14)
                            Text(absenceTitle(a)).font(.system(size: 12)).foregroundStyle(DS.C.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(absenceAmount(a, cal)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .frame(height: 28)
                    }
                }
            }
            if type == .weekend {
                Text(String(localized: "Weekend work is all overtime. It goes to Jira like any other day.")).font(DS.F.caption).foregroundStyle(DS.C.text2)
            } else if type == .holiday {
                Text(String(localized: "Anything you track today counts as overtime and goes to Jira like any other day.")).font(DS.F.caption).foregroundStyle(DS.C.text2)
            }
            let canAddAbsence = type != .weekend && model.lock.canEditAbsences(on: day, today: model.today)
            if canAddAbsence || !tasks.isEmpty || noTask > 0 {
                HStack(spacing: 8) {
                    if canAddAbsence {
                        Button { addAbsence = true } label: { Label(String(localized: "Add absence"), systemImage: "calendar.badge.plus") }.buttonStyle(.pill)
                    }
                    if !tasks.isEmpty || noTask > 0 {
                        Button { overview = true } label: { Label(String(localized: "Day overview"), systemImage: "list.bullet.rectangle") }
                            .buttonStyle(.pill)
                            .help(String(localized: "What you did this day — every task with its descriptions"))
                    }
                }
            }
            Spacer(minLength: 16)
            ShortcutsLink()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .surfaceSheet(isPresented: $addAbsence) {
            AbsenceForm(initialDay: day) { addAbsence = false }.padding(20).frame(width: 460).environment(model)
        }
        .surfaceSheet(isPresented: $overview) {
            DayOverview(day: day) { overview = false }.environment(model)
        }
    }

    private func absenceAmount(_ a: Absence, _ cal: DayCalendar) -> String { model.absenceAmount(a, on: day) }

    private func absenceTitle(_ a: Absence) -> String { model.absenceTitle(a, on: day) }
}

extension AppModel {
    /// "Doctor · 15:00–17:00" for an hour absence, else the type's name.
    func absenceTitle(_ a: Absence, on day: LocalDate) -> String {
        let name = absenceType(a.typeId)?.name ?? ""
        guard a.unit == .hours, let sm = a.startMinutes else { return name }
        let start = day.at(minutes: sm, in: timeCalendar)
        return "\(name) · \(Fmt.range(start, start.addingTimeInterval(TimeInterval(a.amountSeconds))))"
    }

    /// How much of the day an absence takes: its hours, half or the whole day's base fund.
    func absenceAmount(_ a: Absence, on day: LocalDate) -> String {
        let cal = dayCalendar
        return DurationFormat.short(a.unit == .hours ? a.amountSeconds : (a.unit == .halfDay ? cal.schedule.period(on: day).dailySeconds / 2 : cal.baseFund(day)))
    }
}
