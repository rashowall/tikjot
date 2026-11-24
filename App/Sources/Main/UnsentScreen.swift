import SwiftUI
import SyncEngine
import TikjotDomain
import TikjotPersistence

/// Unsent: everything not in Jira yet, by day (newest first); one row = one worklog (task × day);
/// no-task entries one by one; problems inline with their fix (§11.3 "Unsent").
struct UnsentScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var picking = false

    struct Row: Identifiable {
        let id: String
        let day: LocalDate
        let line: WorklogLine?
        let deletedGroup: WorklogGroup?
        let state: SyncState
    }

    private var days: [LocalDate] { Array(model.sendWindow).reversed() }

    private func allRows(_ d: LocalDate) -> [Row] {
        let l = model.ledger
        var out: [Row] = l.lines(on: d).compactMap { line in
            let s = l.state(of: line, lock: model.lock)
            guard s != .synced && s != .locked else { return nil }
            let id = line.group?.id.uuidString ?? line.entries.first!.id.uuidString
            return Row(id: id, day: d, line: line, deletedGroup: nil, state: s)
        }
        let inLines = Set(out.compactMap { $0.line?.group?.id })
        for g in l.groups(on: d) where !inLines.contains(g.id) && [.pendingDelete, .remoteDeleted, .error, .conflict].contains(g.syncState) {
            out.append(Row(id: g.id.uuidString, day: d, line: nil, deletedGroup: g, state: g.syncState))
        }
        return out
    }

    private func rows(_ d: LocalDate) -> [Row] {
        let out = allRows(d)
        return model.unsentFilterNeedsYou ? out.filter(needsYou) : out
    }

    /// Blocks sending — the same rule as everywhere (Ledger.needsYou, audit U1).
    private func needsYou(_ r: Row) -> Bool {
        switch r.state {
        case .noIssue: return r.line?.containsRunning == false
        case .error, .conflict, .remoteDeleted: return true
        default: return r.line?.issue.map { model.unavailableIssues.contains($0) } ?? false
        }
    }

    /// Goes to Jira with Review & send now (a running worklog sends its finished part).
    private func isReady(_ r: Row) -> Bool {
        guard [.unsent, .modified, .pendingDelete].contains(r.state), !needsYou(r) else { return false }
        return r.line.map { model.ledger.sendablePart(of: $0) != nil } ?? true
    }

    var body: some View {
        @Bindable var model = model
        let every = days.flatMap(allRows)
        let all = days.flatMap(rows)
        let totalSeconds = every.compactMap(\.line).reduce(0) { $0 + $1.value }
        // One count (worklogs ready to send) in the header, the button and ⌘A; the rest in words (audit U1).
        let ready = every.filter(isReady)
        let needTask = every.filter { $0.state == .noIssue && needsYou($0) }.count
        let problems = every.filter { $0.state != .noIssue && needsYou($0) }.count
        let running = every.filter { $0.line?.containsRunning == true && $0.state != .noIssue && !isReady($0) && !needsYou($0) }.count
        let needs = model.needsYouNow
        let words = [String(localized: "\(ready.count) ready")]
            + (needTask > 0 ? [String(localized: "\(needTask) need a task")] : [])
            + (problems > 0 ? [String(localized: "\(problems) need you")] : [])
            + (running > 0 ? [String(localized: "\(running) running")] : [])
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Unsent")).font(DS.F.screenTitle)
                        .onAppear {
                            // Debug/captures: -ui unsentReady (the ready rows picked) · unsentNoTask (rows without a task, picker open).
                            DebugUI.open("unsentReady") { selected = Set(ready.map(\.id)) }
                            DebugUI.open("unsentNoTask") {
                                selected = Set(every.filter { $0.state == .noIssue }.map(\.id))
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picking = true }
                            }
                        }
                    Text(String(localized: "Everything not in Jira yet") + (days.last.map { $0 < model.today.firstOfMonth ? " · " + String(localized: "\(Fmt.monthName($0)) stays open until \(Fmt.dayMonth(model.lock.editableUntil($0)))") : "" } ?? ""))
                        .font(DS.F.caption).foregroundStyle(DS.C.text2)
                    if model.jiraConnected && !every.isEmpty {
                        Text(words.joined(separator: " · ")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(DurationFormat.hm(totalSeconds)).font(.system(size: 13, weight: .bold, design: .monospaced)).rolls(DurationFormat.hm(totalSeconds))
                    Text(String(localized: "not in Jira")).font(.system(size: 10)).foregroundStyle(DS.C.text3)
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(ready.count)").font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text(String(localized: "ready to send")).font(.system(size: 10)).foregroundStyle(DS.C.text3)
                }
                if model.jiraConnected {
                    Button { model.requestReview(groups: Set(ready.compactMap { $0.line?.group?.id ?? $0.deletedGroup?.id }), title: String(localized: "Send to Jira")) } label: {
                        Label(String(localized: "Review & send \(ready.count)"), systemImage: "paperplane")
                    }
                    .buttonStyle(.primaryPill).disabled(ready.isEmpty)
                } else {
                    Button(String(localized: "Export CSV")) { model.mainSelection = .statistics; model.exportRequest = true }.buttonStyle(.pill)
                    Button(String(localized: "Connect Jira")) { AppDelegate.shared?.windows.showSettings(model, tab: .jira) }.buttonStyle(.primaryPill)
                }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            Divider().opacity(0.5)
            if !model.jiraConnected {
                VStack(spacing: 12) {
                    Spacer()
                    Illustration(name: "illNoJira", width: 280)
                    Text(String(localized: "Your time is safe here")).font(DS.F.screenTitle)
                    Text(String(localized: "Nothing is lost without Jira. Export it as CSV, or connect Jira to send it.")).foregroundStyle(DS.C.text2)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if every.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Illustration(name: "illSentHero", width: 260)
                    Text(String(localized: "Everything is in Jira")).font(DS.F.screenTitle)
                    Text(String(localized: "Nothing waiting. Nice.")).foregroundStyle(DS.C.text2)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            PillSegmented(selection: $model.unsentFilterNeedsYou, options: [
                                (false, String(localized: "All")),
                                (true, String(localized: "Needs you · \(needs.count)")),
                            ])
                            Spacer()
                            Text(String(localized: "Select rows to review & send them, or to give several entries one task.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                        }
                        // The selection bar sits on top, under the filter (design MfjaN / khdwE); its task dropdown hangs over the list.
                        if !selected.isEmpty { selectionBar(all).zIndex(1) }
                        let firstPrev = days.first { d in d < model.today.firstOfMonth && (!rows(d).isEmpty || model.ledger.dayStatus(d, lock: model.lock) == .missed) }
                        VStack(spacing: 0) {
                            ForEach(days, id: \.self) { d in
                                let rs = rows(d)
                                let missed = model.ledger.dayStatus(d, lock: model.lock) == .missed
                                if !rs.isEmpty || (missed && !model.unsentFilterNeedsYou) || (missed && model.unsentFilterNeedsYou) {
                                    if d == firstPrev {
                                        Text("\(Fmt.monthName(d).uppercased()) · " + String(localized: "open until \(Fmt.dayMonth(model.lock.editableUntil(d)))"))
                                            .font(DS.F.captionMedium).foregroundStyle(DS.C.text2)
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
                                    }
                                    dayHeader(d, rs, missed: missed && rs.isEmpty)
                                    ForEach(rs) { r in UnsentRow(row: r, selected: $selected) }
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                        .clipShape(RoundedRectangle(cornerRadius: DS.R.card))
                        .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
                    }
                    .padding(20)
                    .padding(.bottom, picking ? 260 : 0)
                }
            }
        }
        .background { Button("") { selected = Set(ready.map(\.id)) }.keyboardShortcut("a").opacity(0) }
    }

    private func dayHeader(_ d: LocalDate, _ rs: [Row], missed: Bool) -> some View {
        HStack {
            Text((Fmt.short(d) + (d == model.today ? " · " + String(localized: "today") : "")).uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text2)
                .accessibilityLabel(Fmt.long(d) + (d == model.today ? ", " + String(localized: "today") : ""))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if missed {
                Label(String(localized: "Nothing tracked · expected \(DurationFormat.short(model.ledger.fund(d)))"), systemImage: "calendar.badge.exclamationmark").font(DS.F.captionMedium)
                Button(String(localized: "Add entry")) { model.selectedDay = d; model.mainSelection = .day; model.addEntry(on: d) }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                Button(String(localized: "Add absence")) { model.absenceDraftDays = [d]; model.selectedDay = d; model.mainSelection = .day }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
            } else {
                Text(DurationFormat.hm(rs.compactMap(\.line).reduce(0) { $0 + $1.value })).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(DS.C.text2)
                Button(String(localized: "Review day")) { model.requestReview(days: [d], title: String(localized: "Send \(Fmt.dayName(d, today: model.today)) to Jira")) }
                    .buttonStyle(LinkButtonStyle()).font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(DS.C.surface2)
    }

    private func selectionBar(_ all: [Row]) -> some View {
        let rows = all.filter { selected.contains($0.id) }
        let noTask = rows.filter { $0.state == .noIssue }
        let worklogs = rows.filter { $0.state != .noIssue }
        let secs = rows.compactMap(\.line).reduce(0) { $0 + $1.value }
        let giveTask = !noTask.isEmpty && worklogs.isEmpty
        return HStack(spacing: 12) {
            // The design's checkbox in its mixed state: a click clears the selection.
            Button { selected = []; picking = false } label: {
                RoundedRectangle(cornerRadius: 4).fill(DS.C.brand)
                    .overlay { Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.C.onBrand) }
                    .frame(width: 16, height: 16)
                    .padding(4).contentShape(Rectangle()).padding(-4)
            }
            .buttonStyle(.dot)
            .accessibilityLabel(String(localized: "Clear selection"))
            Group {
                if giveTask {
                    Text(String(localized: "\(noTask.count) selected · \(DurationFormat.hm(secs)) without a task"))
                } else {
                    Text(String(localized: "\(rows.count) selected") + " · " + String(localized: "\(worklogs.count) worklogs") + " · " + DurationFormat.hm(secs))
                }
            }
            .font(DS.F.bodySemibold).foregroundStyle(DS.C.text).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if giveTask {
                Button { picking.toggle() } label: { Label(String(localized: "Give them one task…"), systemImage: "tag") }
                    .buttonStyle(.primaryPill)
            } else {
                Button {
                    model.requestReview(groups: Set(worklogs.compactMap { $0.line?.group?.id ?? $0.deletedGroup?.id }), title: String(localized: "Send \(worklogs.count) worklogs to Jira"))
                } label: { Label(String(localized: "Review & send \(worklogs.count)"), systemImage: "paperplane") }
                .buttonStyle(.primaryPill).disabled(worklogs.isEmpty)
            }
            Button(String(localized: "Clear")) { selected = []; picking = false }
                .buttonStyle(LinkButtonStyle()).font(DS.F.bodySemibold).padding(.horizontal, 12)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.C.brandSoft))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.C.brand, lineWidth: 1))
        // The task search drops down from the bar, over its button (design khdwE): the shared picker + what happens.
        .overlay(alignment: .topTrailing) {
            if giveTask && picking {
                VStack(alignment: .leading, spacing: 0) {
                    TaskPicker(preferProject: noTask.first?.line?.projectId) { i, p in
                        model.setTask(i, projectId: p, for: noTask.flatMap { $0.line?.entries ?? [] })
                        if let i, let p2 = model.projectId(for: i), noTask.contains(where: { $0.line?.projectId != p2 }) {
                            model.showToast(String(localized: "Moved to \(model.project(p2)?.name ?? "") — the task's project"))
                        }
                        picking = false
                        selected = []
                    } onCancel: { picking = false }
                    DropdownNote(text: String(localized: "Each entry keeps its description. Entries on the same day become one worklog."))
                }
                .padding(.horizontal, 6).padding(.vertical, 8)
                .background { TaskDropdownCard() }
                .frame(width: 360)
                .offset(x: -64, y: 8)
            }
        }
    }
}

/// The design's task dropdown card (Task picker mbqxJ): surface, radius 14, border, a soft shadow.
struct TaskDropdownCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface)
            .shadow(color: Color(hex: "#17152A2E")!, radius: 12, y: 8)
            .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
    }
}

/// The footer note under a task dropdown (design: 10.5, tertiary, line height 1.4).
struct DropdownNote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(DS.C.text3).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8))
    }
}

struct UnsentRow: View {
    @Environment(AppModel.self) private var model
    let row: UnsentScreen.Row
    @Binding var selected: Set<String>
    @State private var picking = false

    var body: some View {
        let line = row.line
        let issue = model.issue(line?.issue ?? row.deletedGroup?.issueRef)
        let project = model.project(line?.projectId)
        let color = project?.color ?? "slate"
        let problem = [.error, .conflict, .remoteDeleted].contains(row.state)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: Binding(get: { selected.contains(row.id) }, set: { v in
                    if NSEvent.modifierFlags.contains(.shift), v { selected.insert(row.id) }
                    if v { selected.insert(row.id) } else { selected.remove(row.id) }
                }))
                .toggleStyle(.brandCheckbox).labelsHidden().padding(.top, 2)
                .disabled(line.map { model.ledger.sendablePart(of: $0) == nil } ?? false)
                // The checkbox carries the whole row for VoiceOver; the fixes (Retry, Pick task…) stay their own buttons.
                .accessibilityLabel(spoken(issue: issue, project: project))
                TimeEdge(color: DS.project(color)).frame(height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    if row.state == .noIssue {
                        DescriptionLabel(text: line?.entries.first?.description.isEmpty == false ? line!.entries.first!.description : String(localized: "No description"),
                                         font: DS.F.bodySemibold)
                        // Design tag (zRSb5): warning-soft, padding 2/7, radius 9, 11 regular, ink text. The row's one
                        // no-task icon is the NoTaskMark in the state column.
                        Text(String(localized: "No task · \(project?.name ?? "")")).font(.system(size: 11)).foregroundStyle(DS.C.text)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 9).fill(DS.C.warningSoft))
                    } else {
                        HStack(spacing: 6) {
                            Circle().fill(DS.project(color)).frame(width: 7, height: 7)
                            KeyName(key: issue?.key ?? "", name: issue?.summary ?? "", nameFont: DS.F.bodySemibold)
                        }
                        if let line, !line.descriptions.isEmpty {
                            HStack(spacing: 5) {
                                Image(systemName: "message").font(.system(size: 10)).foregroundStyle(DS.C.text3)
                                Text(line.descriptions.joined(separator: " · ")).font(DS.F.caption).foregroundStyle(DS.C.text2).lineLimit(1)
                            }
                        }
                    }
                }
                Spacer()
                if let line, line.raw != line.value, row.state != .noIssue, !line.containsRunning {
                    Text("\(DurationFormat.hm(line.raw)) →").font(.system(size: 10, design: .monospaced)).foregroundStyle(DS.C.text3)
                }
                // A worklog with the timer in it shows what is sent now (+running later) — the Review number (audit U5).
                Text(line.map { JiraBox.valueText($0, model.ledger) } ?? DurationFormat.hm(row.deletedGroup?.lastSent?.durationSeconds ?? 0)).font(.system(size: 13, weight: .bold, design: .monospaced))
                stateLabel.frame(width: 110, alignment: .leading)
            }
            // The note and its fixes share one line (design tltlf).
            HStack(spacing: 12) {
                if let note = noteText {
                    Text(note).font(DS.F.caption).foregroundStyle(problem ? DS.C.text2 : DS.C.text3)   // ink on the tint
                }
                fixes
            }
            .padding(.leading, 40)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(problem ? DS.C.dangerSoft.opacity(0.5) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border.opacity(0.6)).frame(height: 0.5) }
    }

    private func spoken(issue: Issue?, project: Project?) -> String {
        let line = row.line
        let what = row.state == .noIssue
            ? [line?.entries.first?.description.isEmpty == false ? line!.entries.first!.description : String(localized: "No description"),
               String(localized: "No task · \(project?.name ?? "")")]
            : ["\(issue?.key ?? "") \(issue?.summary ?? "")", line?.descriptions.joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }
        let time = line.map { JiraBox.valueText($0, model.ledger) } ?? DurationFormat.hm(row.deletedGroup?.lastSent?.durationSeconds ?? 0)
        return ([Fmt.long(row.day)] + what + [time, stateWord, noteText].compactMap { $0 }).joined(separator: ", ")
    }

    private var stateWord: String? {
        switch row.state {
        case .unsent: String(localized: "Not sent")
        case .modified: String(localized: "Update")
        case .pendingDelete: String(localized: "Delete")
        case .noIssue: String(localized: "No task")
        case .conflict: String(localized: "Conflict")
        case .error: String(localized: "Failed")
        case .remoteDeleted: String(localized: "Deleted in Jira")
        default: nil
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch row.state {
        // A state word, not a button: "Not sent" is quiet (text-tertiary); signal colour only on the icon.
        case .unsent: state(String(localized: "Not sent"), "circle.dashed", DS.C.text3, text: DS.C.text3)
        case .modified: state(String(localized: "Update"), "arrow.triangle.2.circlepath", DS.C.text2)
        case .pendingDelete: state(String(localized: "Delete"), "trash", DS.C.text2)
        case .noIssue: HStack(spacing: 5) { NoTaskMark(size: 12); Text(String(localized: "No task")).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.C.text) }
        case .conflict: state(String(localized: "Conflict"), "arrow.left.arrow.right", DS.C.danger)
        case .error: state(String(localized: "Failed"), "exclamationmark.circle", DS.C.danger)
        case .remoteDeleted: state(String(localized: "Deleted in Jira"), "trash.slash", DS.C.warning)
        default: EmptyView()
        }
    }

    private func state(_ title: String, _ icon: String, _ iconColor: Color, text: Color = DS.C.text) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(iconColor).frame(width: 12)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(text)
        }
    }

    private var noteText: String? {
        let g = row.line?.group ?? row.deletedGroup
        switch row.state {
        case .noIssue: return String(localized: "Stays here until it has a task.")
        case .modified: return g?.lastSent.map { String(localized: "Updates the worklog already in Jira (was \(DurationFormat.hm($0.durationSeconds))).") }
        case .conflict: return String(localized: "Changed in Jira (\(DurationFormat.hm(g?.remoteVersion?.durationSeconds ?? 0))) and here (\(DurationFormat.hm(row.line?.value ?? 0))).")
        case .error: return String(localized: "Jira said no: \(g?.lastError?.display ?? "")")
        case .remoteDeleted: return String(localized: "Someone deleted it in Jira.")
        default: return row.line?.containsRunning == true ? String(localized: "The running entry is left out until you stop it.") : nil
        }
    }

    @ViewBuilder
    private var fixes: some View {
        let g = row.line?.group ?? row.deletedGroup
        HStack(spacing: 12) {
            switch row.state {
            case .noIssue:
                Button(String(localized: "Pick task")) { picking = true }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
            case .conflict:
                Button(String(localized: "Take Jira's")) { if let id = g?.id { Task { await model.takeJira(id) } } }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                Button(String(localized: "Keep mine")) { if let id = g?.id { Task { await model.keepMine(id) } } }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
            case .error:
                if g?.remoteWorklogId != nil {
                    Button(String(localized: "Take Jira's")) { if let id = g?.id { Task { await model.keepJira(id) } } }
                        .buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium).help(String(localized: "Leave the worklog as it is in Jira — tikjot follows it"))
                } else {
                    Button(String(localized: "Pick another task")) { picking = true }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                }
                Button(String(localized: "Retry")) { if let id = g?.id { Task { await model.retry(id) } } }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
            case .remoteDeleted:
                Button(String(localized: "Send again")) { if let id = g?.id { Task { await model.sendAgain(id) } } }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                Button(String(localized: "Remove here")) { if let id = g?.id { Task { await model.removeLocally(id) } } }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
            default: EmptyView()
            }
        }
        .surfacePopover(isPresented: $picking) {
            TaskPicker(seed: row.line?.entries.first?.description ?? "", preferProject: row.line?.projectId) { i, p in
                model.setTask(i, projectId: p, for: row.line?.entries ?? [])
                picking = false
            } onCancel: { picking = false }
            .padding(10).frame(width: 420).environment(model)
        }
    }
}
