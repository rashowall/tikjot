import SwiftUI
import TikjotDomain

/// ⌘K command bar (§11.4): start a task, go to a project/day/statistics, run any action.
struct CommandBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    enum Section { case task, go, action }

    struct Cmd: Identifiable {
        let id = UUID()
        var section: Section = .action
        let icon: String
        let title: String
        let hint: String
        /// Task rows: Jira key, project colour and a quiet detail beside the name.
        var key: String?
        var dot: String?
        var detail: String?
        let run: @MainActor () -> Void
    }

    private var commands: [Cmd] {
        var out: [Cmd] = []
        let query = q.trimmingCharacters(in: .whitespaces)
        // Start a task
        let tasks = query.isEmpty ? model.suggestions(limit: 4) : model.searchLocal(query).prefix(5).map { $0 }
        for c in tasks {
            let project = model.project(model.projectId(for: c.issue))
            out.append(Cmd(section: .task, icon: "play", title: c.issue.summary, hint: "", key: c.issue.key,
                           dot: project?.color ?? "slate", detail: project?.name) {
                model.start(issue: c.issue, projectId: model.projectId(for: c.issue))
            })
        }
        // Go to
        for s in MainSection.allCases where query.isEmpty || String(localized: "Go to \(s.title)").localizedCaseInsensitiveContains(query) {
            out.append(Cmd(section: .go, icon: s.icon, title: s.title, hint: "⌘\((MainSection.allCases.firstIndex(of: s) ?? 0) + 1)") { model.mainSelection = s })
        }
        for p in model.data.projects where !p.archived && (!query.isEmpty && p.name.localizedCaseInsensitiveContains(query)) {
            out.append(Cmd(section: .go, icon: "folder", title: p.name, hint: "") { model.mainSelection = .projects })
        }
        if let d = parseDay(query) {
            out.append(Cmd(section: .go, icon: "calendar", title: String(localized: "Open \(Fmt.long(d))"), hint: "") { model.selectedDay = d; model.mainSelection = .day })
        }
        // Actions
        let actions: [Cmd] = [
            Cmd(icon: "plus", title: String(localized: "Add entry"), hint: "N") { model.mainSelection = .day; model.addEntry(on: model.selectedDay) },
            Cmd(icon: "calendar.badge.plus", title: String(localized: "Add absence…"), hint: "") { MenuBarController.shared?.showPopover(); model.popoverEditing = .absence },
            Cmd(icon: "paperplane", title: String(localized: "Review & send"), hint: "⇧⌘S") { model.requestReviewForSelection() },
            Cmd(icon: "arrow.clockwise", title: String(localized: "Refresh from Jira"), hint: "⌘R") { Task { await model.refreshAll() } },
            Cmd(icon: "stop.circle", title: String(localized: "Stop timer"), hint: "⌥⌘S") { model.stop() },
            Cmd(icon: "square.and.arrow.down", title: String(localized: "Export CSV…"), hint: "⌘E") { model.mainSelection = .statistics; model.exportRequest = true },
            Cmd(icon: "gearshape", title: String(localized: "Settings…"), hint: "⌘,") { AppDelegate.shared?.windows.showSettings(model) },
            Cmd(icon: "arrow.uturn.backward", title: String(localized: "Undo"), hint: "⌘Z") { model.undo() },
        ]
        out += actions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        return out
    }

    private func parseDay(_ s: String) -> LocalDate? {
        let low = s.lowercased()
        if low == "today" || low == "dnes" { return model.today }
        if low == "yesterday" || low == "včera" { return model.today.adding(days: -1) }
        if let d = LocalDate(s) { return d }
        let parts = s.split(whereSeparator: { $0 == "." || $0 == "/" || $0 == " " }).compactMap { Int($0) }
        if parts.count >= 2, (1...31).contains(parts[0]), (1...12).contains(parts[1]) {
            return LocalDate(year: parts.count > 2 ? parts[2] : model.today.year, month: parts[1], day: parts[0])
        }
        return nil
    }

    var body: some View {
        let cmds = commands
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(DS.C.text3)
                TextField(String(localized: "Start a task, go to, or run an action…"), text: $q)
                    .textFieldStyle(.plain).font(.system(size: 17, weight: .medium))
                    .focused($focused)
                    .onSubmit { run(cmds) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, cmds.count - 1); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                Kbd(text: "esc")
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Rectangle().fill(DS.C.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(cmds.enumerated()), id: \.element.id) { i, c in
                            if i == 0 || cmds[i - 1].section != c.section {
                                SectionLabel(sectionTitle(c.section))
                                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                            }
                            row(c, on: i == highlighted) { highlighted = i; run(cmds) }
                                .id(c.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, h in
                    if cmds.indices.contains(h) { proxy.scrollTo(cmds[h].id) }
                }
            }
            .frame(height: 340)
            HStack(spacing: 16) {
                footerHint("↑↓", String(localized: "move"))
                footerHint("↩", String(localized: "start / open"))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(DS.C.surface2)
            .overlay(alignment: .top) { Rectangle().fill(DS.C.border).frame(height: 1) }
        }
        .frame(width: 600)
        .background(DS.C.surface)
        .onAppear { focused = true }
        .onChange(of: q) { _, _ in highlighted = 0 }
    }

    private func sectionTitle(_ s: Section) -> String {
        switch s {
        case .task: String(localized: "Start a task")
        case .go: String(localized: "Go to")
        case .action: String(localized: "Actions")
        }
    }

    private func row(_ c: Cmd, on: Bool, action: @escaping () -> Void) -> some View {
        // Tertiary text on the brand-soft highlight reads as secondary (text3 on brand-soft is under 4.5:1).
        let t3 = on ? DS.C.text2 : DS.C.text3
        return Button(action: action) {
            HStack(spacing: 10) {
                if let dot = c.dot {
                    Circle().fill(DS.project(dot)).frame(width: 8, height: 8)
                } else {
                    Image(systemName: c.icon).font(.system(size: 13)).foregroundStyle(DS.C.text2).frame(width: 16)
                }
                HStack(spacing: 6) {
                    if let key = c.key { Text(key).font(DS.F.key).foregroundStyle(DS.F.keyColor).fixedSize() }
                    Text(c.title).font(DS.F.body).foregroundStyle(DS.C.text).lineLimit(1)
                    if let d = c.detail, !d.isEmpty { Text(d).font(.system(size: 12)).foregroundStyle(t3).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if c.section == .task {
                    if on { Text("↩ " + String(localized: "start")).font(DS.F.key).foregroundStyle(DS.C.brandText) }
                } else if !c.hint.isEmpty {
                    Text(c.hint).font(DS.F.key).foregroundStyle(t3)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(on ? DS.C.brandSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(DS.C.text2)
            Text(label).font(DS.F.caption).foregroundStyle(DS.C.text3)
        }
    }

    private func run(_ cmds: [Cmd]) {
        guard cmds.indices.contains(highlighted) else { return }
        let c = cmds[highlighted]
        dismiss()
        c.run()
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Group { let title: String; let rows: [(key: String, label: String)] }

    /// The design's four columns (G3Kpzf); time-field keys sit under Jira and selection under Timer to keep the columns even.
    private var columns: [[Group]] {
        [
            [Group(title: String(localized: "Timer · anywhere on the Mac"), rows: [
                ("⌥⌘T", String(localized: "open timer, start or switch")),
                ("⌥⌘S", String(localized: "stop / continue last")),
                ("⌘K", String(localized: "start a task, go anywhere")),
            ]),
             // From the inspector's old hint list (2026-10-25) — the sheet is now the one place for all of them.
             Group(title: String(localized: "Select"), rows: [
                ("⇧ click", String(localized: "add / remove from selection")),
                ("Esc", String(localized: "clear selection")),
             ])],
            [Group(title: String(localized: "Move around"), rows: [
                ("← →", String(localized: "previous / next day")),
                ("T", String(localized: "today")),
                ("⌘1–6", String(localized: "Day … Projects")),
                ("↑ ↓ · ⇥", String(localized: "previous / next entry")),
                ("?", String(localized: "this sheet")),
            ])],
            [Group(title: String(localized: "Edit the day"), rows: [
                ("N", String(localized: "new entry in free time")),
                ("S", String(localized: "split…")),
                ("M", String(localized: "merge with previous")),
                ("⌫", String(localized: "delete")),
                ("⌘A", String(localized: "select all")),
                ("⌘Z / ⇧⌘Z", String(localized: "undo / redo")),
                ("⌥ drag", String(localized: "move without snapping")),
            ])],
            [Group(title: String(localized: "Jira"), rows: [
                ("⇧⌘S", String(localized: "review & send")),
                ("⌘R", String(localized: "refresh from Jira")),
                ("⌘,", String(localized: "settings")),
            ]),
             Group(title: String(localized: "Time fields"), rows: [
                ("↑ ↓", String(localized: "±5 min")),
                ("⇧↑ ⇧↓", String(localized: "±1 min")),
                ("1020 · 10:20 · 10.20", String(localized: "typed times")),
             ])],
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Keyboard shortcuts")).font(DS.F.display(24, .heavy)).foregroundStyle(DS.C.text)
                Spacer()
                Text(String(localized: "Press ? anytime · esc to close")).font(.system(size: 12)).foregroundStyle(DS.C.text3)
            }
            HStack(alignment: .top, spacing: 28) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(col, id: \.title) { g in
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(g.title)
                                ForEach(g.rows, id: \.key) { r in shortcutRow(r.key, r.label) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(28)
        .frame(width: 900)
        .background(DS.C.surface)
        .background {
            // Return and esc close the sheet, as the former Done button did.
            Button("") { dismiss() }.keyboardShortcut(.defaultAction).opacity(0).accessibilityHidden(true)
            Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
    }

    /// Keycap + label on one line; when a wide keycap leaves no room, the label goes under it instead of breaking words.
    private func shortcutRow(_ key: String, _ label: String) -> some View {
        let text = Text(label).font(.system(size: 12)).foregroundStyle(DS.C.text2)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { Kbd(text: key).fixedSize(); text.fixedSize() }
            VStack(alignment: .leading, spacing: 4) { Kbd(text: key).fixedSize(); text.fixedSize(horizontal: false, vertical: true) }
        }
    }
}
