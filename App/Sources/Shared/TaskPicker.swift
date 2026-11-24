import SwiftUI
import TikjotDomain
import TikjotPersistence
import TikjotSuggestions

/// One picker everywhere (§7.5): own search field; typing ranks tasks you logged › assigned to you › more in Jira.
/// `onPick(issue, projectId)` — issue nil = "No task yet" (filed into `projectId`; nil unless `preferProject` is set —
/// the project is never guessed).
struct TaskPicker: View {
    @Environment(AppModel.self) private var model
    var seed: String = ""
    var currentKey: String?
    var preferProject: UUID?
    var allowNoTask = true
    var noTaskTitle = String(localized: "No task — pick it later")
    var autoFocus = true
    /// The description the task is picked for (the capsule's step 2 after ↩ on a new description): a "Step 2" band
    /// on top, tasks used with similar descriptions first, the no-task fallbacks muted at the bottom.
    var contextDescription: String? = nil
    let onPick: (Issue?, UUID?) -> Void
    var onCancel: () -> Void = {}

    @State private var query = ""
    @State private var remote: [Issue] = []
    @State private var searching = false
    /// The last Jira search got no answer: what's listed is the saved tasks only.
    @State private var unreachable = false
    @State private var listHeight: CGFloat = 0
    @State private var highlighted = 0
    /// Set by ↑ ↓ only (not by hover): the list scrolls the highlighted row into view.
    @State private var scrollTarget: Int?
    @State private var newProjectName: String?
    /// The pin hint shows until the first pin, then never again (beta 2026-10-21: nobody found the star).
    @AppStorage("pinHintDone") private var pinHintDone = false
    @FocusState private var focused: Bool

    private enum Row: Hashable {
        /// `muted`: other people's issues ("More in Jira") — shown quieter, below yours.
        case issue(Issue, sub: String?, muted: Bool = false)
        case noTask
        case noProject
        case project(Project)
        case newProject
        case connect
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private var sections: [Section] {
        var out: [Section] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        if model.jiraConnected {
            if q.isEmpty {
                // Step 2 after a new description: tasks used with similar descriptions first.
                if let d = context {
                    let similar = model.tasksUsed(withSimilarTo: d)
                    let rows = similar.map { c -> Row in seen.insert(c.issue.id); return .issue(c.issue, sub: c.recentDescriptions.first) }
                    if !rows.isEmpty { out.append(Section(id: "similar", title: String(localized: "Used with similar descriptions"), rows: rows)) }
                }
                var sugg = model.suggestions(limit: 8).filter { !seen.contains($0.issue.id) }
                if let p = preferProject {
                    sugg.sort { (model.projectId(for: $0.issue) == p ? 1 : 0) > (model.projectId(for: $1.issue) == p ? 1 : 0) }
                }
                let rows = sugg.map { c -> Row in seen.insert(c.issue.id); return .issue(c.issue, sub: c.recentDescriptions.first) }
                if !rows.isEmpty { out.append(Section(id: "yours", title: String(localized: "Your tasks"), rows: rows)) }
            } else {
                // One ranked list (row 12): you logged › assigned to you › more in Jira (others' issues, muted).
                let ranked = model.rankTasks(q, remote: remote)
                let logged = ranked.logged.map { Row.issue($0.issue, sub: $0.recentDescriptions.first ?? projectName($0.issue)) }
                if !logged.isEmpty { out.append(Section(id: "logged", title: String(localized: "You logged"), rows: logged)) }
                let assigned = ranked.assigned.map { Row.issue($0.issue, sub: $0.recentDescriptions.first ?? projectName($0.issue)) }
                if !assigned.isEmpty { out.append(Section(id: "assigned", title: String(localized: "Assigned to you"), rows: assigned)) }
                let more = ranked.more.map { Row.issue($0.issue, sub: projectName($0.issue), muted: true) }
                if !more.isEmpty || searching || unreachable {
                    let title = searching ? String(localized: "More in Jira · searching…")
                        : unreachable ? String(localized: "Jira isn't answering · saved tasks only") : String(localized: "More in Jira")
                    out.append(Section(id: "jira", title: title, rows: more))
                }
            }
            if allowNoTask {
                // Work that isn't a Jira task: file it in a project, or in none at all.
                let projects = model.data.projects.filter { !$0.archived && (q.isEmpty || matches($0, q)) }
                    .sorted { ($0.id == preferProject ? 0 : 1, $0.name) < ($1.id == preferProject ? 0 : 1, $1.name) }
                let projectRows = (q.isEmpty ? Array(projects.prefix(6)) : projects).map { Row.project($0) } + (q.isEmpty ? [.noProject] : [])
                out.append(Section(id: "none", title: "", rows: [.noTask]))
                out.append(Section(id: "projects", title: context == nil ? String(localized: "Or a project without a task") : String(localized: "Or just a project"),
                                   rows: projectRows))
            }
        } else {
            let projects = model.data.projects.filter { !$0.archived && (q.isEmpty || matches($0, q)) }
            out.append(Section(id: "projects", title: String(localized: "Start it in a project"), rows: projects.map { .project($0) } + [.newProject]))
            out.append(Section(id: "connect", title: "", rows: [.connect]))
        }
        return out
    }

    private var flatRows: [Row] { sections.flatMap(\.rows) }

    private var anyPinned: Bool { model.data.issues.contains(where: \.pinned) }

    /// Under the unsearched list of your tasks, until you pin one.
    private func showPinHint(_ secs: [Section]) -> Bool {
        !pinHintDone && !anyPinned && query.isEmpty && newProjectName == nil && secs.contains { $0.id == "yours" }
    }

    /// The description being given a task, nil outside the capsule's step 2.
    private var context: String? {
        let d = contextDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return d.isEmpty ? nil : d
    }

    private func projectName(_ i: Issue) -> String? { model.project(model.projectId(for: i))?.name ?? i.projectName }

    /// A project matches by its name or by one of its Jira keys ("WEB" finds the project that has WEB).
    private func matches(_ p: Project, _ q: String) -> Bool {
        p.name.localizedCaseInsensitiveContains(q) || keys(of: p).contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private func keys(of p: Project) -> [String] { model.data.rules.filter { $0.projectId == p.id }.map(\.value) }

    var body: some View {
        // Ranked once per update (beta 2026-10-22: each row asked for its index in a freshly ranked list — the whole
        // ranking ran ~30 times a render and typing lagged seconds).
        let secs = sections
        let index = Dictionary(secs.flatMap(\.rows).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 6) {
            // Step 2 of starting from a description (K4): says what is being picked, and for what.
            if let d = context {
                HStack(spacing: 6) {
                    Image(systemName: "tag").font(.system(size: 11, weight: .semibold))
                    Text(String(localized: "Step 2 · Pick a task for “\(d)”")).font(DS.F.bodyMedium).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DS.C.brandText)
                .padding(.horizontal, 10)
                .frame(height: DS.H.regular)
                .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.brandSoft))
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 6) {
                Image(systemName: context == nil ? "magnifyingglass" : "tag").foregroundStyle(DS.C.text3).font(.system(size: 12))
                TextField(context != nil ? String(localized: "Search tasks…")
                          : model.jiraConnected ? String(localized: "Search tasks or Jira…") : String(localized: "Search projects…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.F.body)
                    .focused($focused)
                    .onSubmit { pickHighlighted() }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, flatRows.count - 1)); scrollTarget = highlighted; return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); scrollTarget = highlighted; return .handled }
                    .onKeyPress(.escape) { onCancel(); return .handled }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.C.text3) }.buttonStyle(.icon)
                }
                Kbd(text: "esc")
            }
            .padding(.horizontal, 10)
            .frame(height: DS.H.field)
            .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(focused ? DS.C.focusRingStrong : DS.C.borderStrong, lineWidth: focused ? 2 : 1))

            if let name = newProjectName {
                NewProjectInline(name: name) { project in
                    newProjectName = nil
                    if let project { onPick(nil, project.id) }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(secs) { section in
                                if !section.title.isEmpty {
                                    SectionLabel(section.title).padding(.top, 6).padding(.horizontal, 6)
                                } else {
                                    Divider().padding(.vertical, 3)
                                }
                                ForEach(section.rows, id: \.self) { row in
                                    let i = index[row]
                                    rowView(row, index: i, isHighlighted: i == highlighted).id(i)
                                }
                            }
                        }
                        // A ScrollView doesn't report its content height (the popover sized it to a sliver) — measure it.
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    .frame(height: min(max(listHeight, 1), 300))
                    .scrollIndicators(.never)
                    // ↑ ↓ keep the highlighted row in view (audit U9).
                    .onChange(of: scrollTarget) { _, t in
                        guard let t else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(t) }
                        scrollTarget = nil
                    }
                }
            }
            if showPinHint(secs) {
                Label(String(localized: "Pin a task to keep it on top · ⌘P"), systemImage: "star")
                    .font(DS.F.caption).foregroundStyle(DS.C.text2).padding(.horizontal, 4)
            }
            // One line: the longer hint where it fits (popover), the keys alone where it doesn't (inspector).
            ViewThatFits(in: .horizontal) {
                if context != nil {
                    Text(String(localized: "↩ start with this task · ↑↓ move · esc back")).lineLimit(1)
                } else {
                    if model.jiraConnected { Text(String(localized: "Searches key, name, project · ↑↓ move · ↩ choose · esc back")).fixedSize() }
                    Text(String(localized: "↑↓ move · ↩ choose · esc back")).lineLimit(1)
                }
            }
            .font(DS.F.caption).foregroundStyle(DS.C.text3).padding(.horizontal, 4)
        }
        // ⌘P pins the highlighted task (the star's help promises it).
        .background {
            Button("") { pinHighlighted() }.keyboardShortcut("p").opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .onChange(of: anyPinned, initial: true) { _, p in if p { pinHintDone = true } }
        .onAppear {
            model.refreshIfStale()
            if query.isEmpty && !seed.isEmpty && model.jiraConnected { query = "" }
            // Debug/captures: -pickerQuery "text" types into the search (LaunchFlags is empty in Release).
            let a = LaunchFlags.args
            if let i = a.firstIndex(of: "-pickerQuery"), a.indices.contains(i + 1) { query = a[i + 1] }
            if autoFocus { DispatchQueue.main.async { focused = true } }
        }
        .task(id: query) {
            highlighted = 0
            let q = query.trimmingCharacters(in: .whitespaces)
            guard model.jiraConnected, q.count >= 2 else { remote = []; unreachable = false; searching = false; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            searching = true
            let r = await model.searchJira(q)
            if Task.isCancelled { return }
            remote = r.issues
            unreachable = r.unreachable
            searching = false
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, index: Int?, isHighlighted: Bool) -> some View {
        // Tertiary text on the highlighted (brand-soft) row reads as secondary — text3 on brand-soft is under 4.5:1.
        let t3 = isHighlighted ? DS.C.text2 : DS.C.text3
        Button { pick(row) } label: {
            HStack(spacing: 8) {
                switch row {
                case .issue(let i, let sub, let muted):
                    let color = model.project(model.projectId(for: i))?.color ?? "slate"
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            // ● KEY Name — the project dot, as everywhere a task is named (dot = task, edge = time).
                            Circle().fill(DS.project(color)).frame(width: 7, height: 7).opacity(muted ? 0.45 : 1)
                            KeyName(key: i.key, name: i.summary, keyFont: .system(size: 11, weight: .semibold, design: .monospaced),
                                    keyColor: muted ? DS.C.text2 : DS.C.text, nameColor: i.isDone || muted ? t3 : DS.C.text, minName: 90)
                            // Ink on a tint; the signal colour only on the icon.
                            if i.isDone {
                                Chip(text: String(localized: "Done"), color: DS.C.text, fill: DS.C.successSoft, icon: "checkmark", iconColor: DS.C.success)
                            }
                        }
                        if let sub, !sub.isEmpty {
                            Text(sub).font(DS.F.caption).foregroundStyle(t3).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if i.key == currentKey { Text("current").font(DS.F.caption).foregroundStyle(t3) }
                    if let est = i.originalEstimateSeconds, let spent = i.timeSpentSeconds, spent > est {
                        Chip(text: "\(DurationFormat.short(spent)) / \(DurationFormat.short(est))", color: DS.C.text, fill: DS.C.dangerSoft,
                             icon: "exclamationmark.circle", iconColor: DS.C.danger)
                            .help(String(localized: "Over the estimate in Jira"))
                    }
                    // Room for ↩ on every row, left of the star: the star keeps the right edge
                    // and doesn't jump when a row is highlighted (owner 2026-10-21).
                    Image(systemName: "return").font(.system(size: 10)).foregroundStyle(t3).opacity(isHighlighted ? 1 : 0)
                        .accessibilityHidden(!isHighlighted)
                    Button { model.togglePin(i) } label: {
                        Image(systemName: (model.data.issues.first { $0.id == i.id }?.pinned ?? false) ? "star.fill" : "star")
                            .font(.system(size: 10)).foregroundStyle(t3)
                    }
                    .buttonStyle(.icon).help(String(localized: "Pin (⌘P)"))
                case .noTask:
                    Image(systemName: "circle.dashed").foregroundStyle(t3).font(.system(size: 12))
                    Text(context != nil ? String(localized: "Start without a task — pick it later")
                         : query.isEmpty ? noTaskTitle : String(localized: "Keep “\(query)” without a task")).font(DS.F.body).foregroundStyle(DS.C.text2)
                    Spacer()
                case .noProject:
                    Image(systemName: "circle.slash").foregroundStyle(t3).font(.system(size: 12))
                    Text(String(localized: "No project")).font(DS.F.body).foregroundStyle(DS.C.text2)
                    Text(String(localized: "· no task")).font(DS.F.caption).foregroundStyle(t3)
                    Spacer()
                case .project(let p):
                    TimeEdge(color: DS.project(p.color)).frame(height: 16)
                    // Step 2 keeps the no-task fallbacks quiet: the tasks above are the point.
                    Text(p.name).font(DS.F.body).foregroundStyle(context != nil ? DS.C.text2 : DS.C.text)
                    let ks = keys(of: p)
                    if !ks.isEmpty { Text(ks.prefix(3).joined(separator: ", ")).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(t3).lineLimit(1) }
                    Text(String(localized: "· no task")).font(DS.F.caption).foregroundStyle(t3)
                    Spacer()
                case .newProject:
                    Image(systemName: "plus").foregroundStyle(DS.C.brandText).font(.system(size: 11, weight: .semibold))
                    Text(String(localized: "New project…")).font(DS.F.body).foregroundStyle(DS.C.brandText)
                    Spacer()
                case .connect:
                    Image(systemName: "link").foregroundStyle(t3).font(.system(size: 11))
                    Text(String(localized: "Connect Jira to search tasks")).font(DS.F.body).foregroundStyle(DS.C.text2)
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(isHighlighted ? DS.C.brandSoft.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
        .onHover { if $0, let index { highlighted = index } }
    }

    private func pinHighlighted() {
        let rows = flatRows
        guard rows.indices.contains(highlighted), case .issue(let i, _, _) = rows[highlighted] else { return }
        let pinned = model.data.issues.first { $0.id == i.id }?.pinned ?? false
        model.togglePin(i)
        model.showToast(pinned ? String(localized: "\(i.key) unpinned") : String(localized: "\(i.key) pinned"))
    }

    private func pickHighlighted() {
        let rows = flatRows
        guard rows.indices.contains(highlighted) else { return }
        pick(rows[highlighted])
    }

    private func pick(_ row: Row) {
        switch row {
        case .issue(let i, _, _):
            model.touchIssue(i)
            onPick(i, model.ensureProject(for: i))
        // No guessed project (row 13): only the one the caller passed.
        case .noTask: onPick(nil, preferProject)
        case .project(let p): onPick(nil, p.id)
        case .noProject: onPick(nil, nil)
        case .newProject: newProjectName = query
        case .connect:
            MenuBarController.shared?.closePopover()
            AppDelegate.shared?.windows.showSettings(model, tab: .jira)
        }
    }
}

/// "New project…" inline (name, auto colour, billable) — used where Jira isn't connected.
struct NewProjectInline: View {
    @Environment(AppModel.self) private var model
    @State var name: String
    @State private var billable = true
    let done: (Project?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "New project"))
            TextField(String(localized: "Name"), text: $name).textFieldStyle(.plain).fieldStyle()
            Toggle(String(localized: "Billable"), isOn: $billable).toggleStyle(.brandSwitch)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { done(nil) }.buttonStyle(.pill)
                Button(String(localized: "Create")) {
                    let p = model.createProject(name: name.trimmingCharacters(in: .whitespaces), billable: billable)
                    done(p)
                }
                .buttonStyle(.primaryPill)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
    }
}

