import SwiftUI
import TikjotDomain
import TikjotPersistence

/// Projects (§10.4): list + inspector; keys belong to one project only; archive; merge; first-run proposals.
struct ProjectsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selected: UUID?
    @State private var query = ""
    @State private var creating = false
    /// The colour the new-project panel picked (shown on its row in the list).
    @State private var newProjectColor = "slate"

    var body: some View {
        let ps = model.data.projects.filter { p in
            query.isEmpty || p.name.localizedCaseInsensitiveContains(query) || model.data.rules.contains { $0.projectId == p.id && $0.value.localizedCaseInsensitiveContains(query) }
        }
        let month = DateRange.month(of: model.today)
        // Design: most hours this month first (archived last).
        let hours = Dictionary(uniqueKeysWithValues: model.data.projects.map { ($0.id, secs($0, month)) })
        let sorted = ps.sorted { a, b in (a.archived ? 1 : 0, -(hours[a.id] ?? 0), a.name) < (b.archived ? 1 : 0, -(hours[b.id] ?? 0), b.name) }
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Projects")).font(DS.F.screenTitle)
                    Text(String(localized: "\(model.data.projects.filter { !$0.archived }.count) active · \(model.data.projects.filter(\.archived).count) archived") +
                         (model.jiraConnected ? " · " + String(localized: "Jira keys decide which project a task belongs to") : ""))
                        .font(DS.F.caption).foregroundStyle(DS.C.text2)
                }
                Spacer()
                Button { creating = true } label: { Label(String(localized: "New project"), systemImage: "plus") }.buttonStyle(.pill)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.pendingProjectSuggestions.isEmpty || (model.data.projects.isEmpty && model.jiraConnected) {
                            FirstRunProposals()
                        }
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(DS.C.text3)
                            TextField(String(localized: "Search projects or keys…"), text: $query).textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 10).frame(width: 320, height: DS.H.field)
                        .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
                        .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(DS.C.borderStrong, lineWidth: 1))
                        VStack(spacing: 0) {
                            HStack {
                                Text(String(localized: "PROJECT")).frame(maxWidth: .infinity, alignment: .leading)
                                if model.jiraConnected { Text(String(localized: "KEYS")).frame(width: 140, alignment: .leading) }
                                Text(Fmt.monthShort(month.start).uppercased()).frame(width: 80, alignment: .trailing)
                                Text(String(localized: "BILLABLE")).frame(width: 80, alignment: .leading).padding(.leading, 12)
                            }
                            .font(DS.F.sectionLabel).foregroundStyle(DS.C.text3).padding(.horizontal, 14).frame(height: 30)
                            .background(DS.C.surface2)
                            ForEach(sorted) { p in
                                // Tertiary text on the selected (brand-soft) row reads as secondary (text3 there is under 4.5:1).
                                let t3 = (selected ?? sorted.first?.id) == p.id ? DS.C.text2 : DS.C.text3
                                HStack {
                                    HStack(spacing: 8) {
                                        Circle().fill(DS.project(p.color)).frame(width: 12, height: 12)
                                        Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.archived ? t3 : DS.C.text)
                                        if p.archived { Chip(text: String(localized: "archived")) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if model.jiraConnected {
                                        Text(listedKeys(p).joined(separator: ", "))
                                            .font(DS.F.mono).foregroundStyle(DS.C.text2).frame(width: 140, alignment: .leading)
                                    }
                                    Text(hoursText(p, month)).font(.system(size: 12, weight: .bold, design: .monospaced)).frame(width: 80, alignment: .trailing)
                                    Text(p.billable ? String(localized: "billable") : "—").font(.system(size: 12)).foregroundStyle(p.billable ? DS.C.text : t3).frame(width: 80, alignment: .leading).padding(.leading, 12)
                                }
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(!creating && (selected ?? sorted.first?.id) == p.id ? DS.C.brandSoft : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = p.id }
                                .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border.opacity(0.6)).frame(height: 0.5) }
                            }
                            if creating {
                                // The project being created, as in the design: a row at the end, selected.
                                HStack(spacing: 10) {
                                    Circle().fill(DS.project(newProjectColor)).frame(width: 12, height: 12)
                                    Text(String(localized: "New project")).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.C.text2)
                                    Spacer()
                                }
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(DS.C.brandSoft)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                        .clipShape(RoundedRectangle(cornerRadius: DS.R.card))
                        .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
                        if ps.isEmpty {
                            Text(String(localized: "No projects yet. A project groups your time (and Jira keys) — e.g. a client or a team.")).font(DS.F.body).foregroundStyle(DS.C.text2)
                        }
                    }
                    .padding(20)
                }
                Divider().opacity(0.5)
                Group {
                    if creating {
                        NewProjectPanel(color: $newProjectColor) { p in creating = false; if let p { selected = p.id } }
                    } else if let id = selected ?? sorted.first?.id, let p = model.data.projects.first(where: { $0.id == id }) {
                        ProjectInspector(project: p).id(p.id)
                    } else {
                        Text(String(localized: "Select a project")).foregroundStyle(DS.C.text3).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 360)
                .background(DS.C.surface)
            }
        }
        .onAppear {
            if let s = model.projectsSelection { selected = s; model.projectsSelection = nil }
            // Debug/captures: -projectNew opens New project.
            if LaunchFlags.args.contains("-projectNew") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { creating = true } }
        }
        .onChange(of: model.projectsSelection) { _, v in if let v { selected = v; model.projectsSelection = nil } }
    }

    private func secs(_ p: Project, _ r: DateRange) -> Seconds {
        let last = min(r.end, model.today)
        guard last >= r.start else { return 0 }
        return DateRange(r.start, last).reduce(0) { d, day in d + model.ledger.lines(on: day).filter { $0.projectId == p.id }.reduce(0) { $0 + $1.value } }
    }

    /// The keys in the list: the connected sites' (an archived site's key only when it has no other), each once.
    private func listedKeys(_ p: Project) -> [String] {
        let rules = model.data.rules.filter { $0.projectId == p.id }
        let active = Set(model.activeInstances.map(\.id))
        let live = rules.filter { active.contains($0.instanceId) }
        return Set((live.isEmpty ? rules : live).map(\.value)).sorted()
    }

    private func hoursText(_ p: Project, _ r: DateRange) -> String {
        let s = secs(p, r)
        return s == 0 ? "—" : DurationFormat.hm(s)
    }
}

struct ProjectInspector: View {
    /// Spectrum order of the design's swatch row.
    static let swatchOrder = ["rose", "tangerine", "amber", "olive", "green", "jade", "cyan", "sky", "blue", "grape", "magenta", "slate"]
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var addingKey = false
    @State private var newKey = ""
    @State private var merging = false
    @State private var customColor = Color.blue

    var body: some View {
        let rules = model.data.rules.filter { $0.projectId == project.id }
        let hasEntries = model.data.entries.contains { $0.projectId == project.id }
        GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Circle().fill(DS.project(project.color)).frame(width: 16, height: 16)
                    Text(project.name).font(DS.F.screenTitle)
                }
                if project.archived {
                    // Design "archived": what archiving means, right under the name.
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "archivebox").font(.system(size: 12)).foregroundStyle(DS.C.text2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Archived")).font(DS.F.captionMedium).foregroundStyle(DS.C.text)
                            Text(String(localized: "Hidden from task pickers. Past entries, reports and exports keep it.")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface2))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(localized: "Name")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    // Saved on Enter, on focus loss and when the selection changes (the inspector goes away).
                    TextField("", text: $name).textFieldStyle(.plain).fieldStyle()
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .onChange(of: nameFocused) { _, f in if !f { commitName() } }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Colour")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    // Design (Colour/Sw): one row in spectrum order, then a "Custom" rainbow swatch.
                    HStack(spacing: 5) {
                        ForEach(Self.swatchOrder.filter { ProjectPalette.names.contains($0) }, id: \.self) { c in
                            Button { var p = project; p.color = c; model.updateProject(p) } label: {
                                Circle().fill(DS.project(c)).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(DS.C.text, lineWidth: project.color == c ? 2 : 0).padding(-3))
                                    .padding(3).contentShape(Rectangle()).padding(-3)   // 24 pt hit target
                            }.buttonStyle(.dot).help(c)
                        }
                        ZStack {
                            Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center))
                                .overlay(Circle().fill(.white).frame(width: 6, height: 6))
                                .overlay(Circle().strokeBorder(DS.C.text, lineWidth: project.color.hasPrefix("#") ? 2 : 0).padding(-3))
                                .allowsHitTesting(false)
                            // The system colour well sits invisibly on top, so a click opens the picker.
                            ColorPicker("", selection: $customColor, supportsOpacity: false).labelsHidden()
                                .opacity(0.02)
                                .onChange(of: customColor) { _, c in
                                    var p = project
                                    p.color = ContrastCheck.safeHex(c)
                                    model.updateProject(p)
                                }
                        }
                        .frame(width: 18, height: 18)
                        .help(String(localized: "Custom colour (darkened if needed for contrast)"))
                    }
                }
                if model.jiraConnected || !rules.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Rules · tasks that belong here")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                        ForEach(rules) { r in
                            HStack {
                                Image(systemName: "key").font(.system(size: 11)).foregroundStyle(DS.C.text3)
                                // Mono only for the key itself; the Jira site name is prose.
                                HStack(spacing: 6) {
                                    Text(r.value).font(DS.F.key).foregroundStyle(DS.C.text).fixedSize()
                                    Text(model.data.instances.first { $0.id == r.instanceId }?.name ?? "").font(DS.F.caption).foregroundStyle(DS.C.text3)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                                Button { model.removeKey(r) } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.icon)
                            }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(DS.C.surface2))
                        }
                        if addingKey {
                            KeyAdder(project: project) { addingKey = false }
                        } else if model.jiraConnected {
                            Button { addingKey = true } label: { Label(String(localized: "Add Jira key"), systemImage: "plus") }.buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                        }
                    }
                }
                Toggle(isOn: Binding(get: { project.billable }, set: { var p = project; p.billable = $0; model.updateProject(p) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(localized: "Billable")).font(DS.F.bodySemibold)
                        Text(String(localized: "Counts towards utilization")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                    }
                }
                .toggleStyle(.brandSwitch)
                Toggle(isOn: Binding(get: { project.excludeFromWorked }, set: { var p = project; p.excludeFromWorked = $0; model.updateProject(p) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(localized: "Don't count as worked")).font(DS.F.bodySemibold)
                        Text(String(localized: "For Jira tasks that track absences (e.g. a vacation task)")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                    }
                }
                .toggleStyle(.brandSwitch)
                Well {
                    VStack(spacing: 5) {
                        let m = DateRange.month(of: model.today)
                        let pm = DateRange.month(of: model.today.firstOfMonth.adding(months: -1))
                        let sum = { (r: DateRange) in DateRange(r.start, min(r.end, model.today)).reduce(0) { d, day in d + model.ledger.lines(on: day).filter { $0.projectId == project.id }.reduce(0) { $0 + $1.value } } }
                        row(String(localized: "This month"), DurationFormat.hm(sum(m)))
                        row(Fmt.monthName(pm.start), DurationFormat.hm(sum(pm)))
                        row(String(localized: "Tasks used"), "\(Set(model.data.entries.filter { $0.projectId == project.id }.compactMap(\.issueId)).count)")
                    }
                }
                Spacer(minLength: 20)   // the footer sits at the bottom of the panel (design)
                HStack {
                    Button { var p = project; p.archived.toggle(); model.updateProject(p) } label: {
                        Label(project.archived ? String(localized: "Unarchive") : String(localized: "Archive project"), systemImage: "archivebox")
                    }
                    .buttonStyle(LinkButtonStyle(color: DS.C.text2))
                    Spacer()
                    if hasEntries {
                        Button(String(localized: "Merge into…")) { merging = true }.buttonStyle(LinkButtonStyle(color: DS.C.text2))
                    } else {
                        Button(String(localized: "Delete")) { model.deleteProject(project) }.buttonStyle(LinkButtonStyle(color: DS.C.dangerText))
                    }
                }
                if hasEntries {
                    Text(String(localized: "A project with entries can't be deleted — merge it into another.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                }
            }
            .padding(20)
            .frame(minHeight: geo.size.height, alignment: .top)
        }
        }
        .onAppear {
            name = project.name
            if LaunchFlags.args.contains("-projectMerge") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { merging = true } }
            // Debug/captures: -projectKey "FIN" types a key into Add Jira key (FIN belongs to Finance: the conflict).
            if LaunchFlags.args.contains("-projectKey") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { addingKey = true } }
        }
        .onDisappear { commitName() }
        .surfaceSheet(isPresented: $merging) { MergeProjectSheet(project: project) { merging = false }.environment(model) }
    }

    /// Writes the typed name back (against the current project, not the snapshot this view was built with); an empty
    /// name or no change is ignored.
    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, var p = model.data.projects.first(where: { $0.id == project.id }), p.name != n else { return }
        p.name = n
        model.updateProject(p)
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a).font(DS.F.caption).foregroundStyle(DS.C.text2); Spacer(); Text(b).font(DS.F.mono) }
    }
}

/// Adds a key; if it belongs to another project the conflict is shown with what moving re-files (§10.4).
struct KeyAdder: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let done: () -> Void
    @State private var key = LaunchFlags.args.firstIndex(of: "-projectKey").flatMap { i in LaunchFlags.args.indices.contains(i + 1) ? LaunchFlags.args[i + 1] : nil } ?? ""
    @State private var instance: UUID?

    var body: some View {
        let inst = instance ?? model.activeInstances.first?.id
        let k = key.trimmingCharacters(in: .whitespaces).uppercased()
        let owner = model.data.rules.first { $0.instanceId == inst && $0.value == k && $0.projectId != project.id }
        let affected = model.data.entries.filter { e in model.issue(for: e).map { $0.projectKey == k && $0.instanceId == inst } ?? false }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(String(localized: "Key, e.g. PMO"), text: $key).textFieldStyle(.plain).fieldStyle()
                    .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(owner == nil ? .clear : DS.C.warning, lineWidth: 1.5))
                if model.activeInstances.count > 1 {
                    Picker("", selection: Binding(get: { inst }, set: { instance = $0 })) {
                        ForEach(model.activeInstances) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().frame(width: 140)
                }
            }
            let unused = model.unmappedKeys().filter { $0.0 == inst }.map(\.1)
            if !unused.isEmpty {
                Text(String(localized: "Keys you used without a project")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                FlowChips(items: unused) { u in
                    Button { key = u } label: { Chip(text: u, color: DS.C.brandText, fill: DS.C.brandSoft) }.buttonStyle(.chip)
                }
            }
            if let owner, let op = model.project(owner.projectId) {
                // Design "key conflict": what moving means, then Move here / Keep it there.
                let tasks = Set(affected.compactMap(\.issueId)).count
                let secs = affected.reduce(0) { $0 + $1.duration(now: model.now) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(DS.C.warningText)
                        Text(String(localized: "\(k) already belongs to \(op.name). Each key can be in one project only.")).font(DS.F.captionMedium).foregroundStyle(DS.C.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text((tasks == 1 ? String(localized: "Moving it re-files 1 task (\(DurationFormat.short(secs))) under \(project.name)")
                                     : String(localized: "Moving it re-files \(tasks) tasks (\(DurationFormat.short(secs))) under \(project.name)")) +
                         (op.billable != project.billable ? String(localized: " and changes their billable status to yours") : "") +
                         ". " + String(localized: "Nothing changes in Jira."))
                        .font(DS.F.caption).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button {
                            if let inst { model.assignKey(k, instanceId: inst, to: project.id) }
                            done()
                        } label: { Label(String(localized: "Move \(k) here"), systemImage: "arrow.left.arrow.right").fixedSize() }
                        .buttonStyle(.primaryPill)
                        Button(action: done) { Text(String(localized: "Keep it in \(op.name)")).lineLimit(1).fixedSize() }.buttonStyle(.pill)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.warningSoft))
            } else {
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel"), action: done).buttonStyle(.pill)
                    Button(String(localized: "Add")) {
                        if let inst { model.assignKey(k, instanceId: inst, to: project.id) }
                        done()
                    }
                    .buttonStyle(.primaryPill).disabled(k.isEmpty || inst == nil)
                    .help(k.isEmpty ? String(localized: "Type a Jira key first") : "")
                }
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface2))
    }
}

/// New project (design "Main · Projects · new project"): the inspector column becomes the form — name, a colour
/// picked for you, the Jira keys that file tasks here (or, without Jira, a note), Billable / Don't count as worked.
struct NewProjectPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var color: String
    let done: (Project?) -> Void
    @State private var name = ""
    @State private var billable = true
    @State private var excluded = false
    @State private var keys: [String] = []
    @State private var keyText = ""
    @State private var autoColor = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let unused = model.unmappedKeys()
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(DS.project(color)).frame(width: 16, height: 16)
                Text(String(localized: "New project")).font(DS.F.screenTitle)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Name")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                TextField(String(localized: "Name, e.g. a client or a team"), text: $name).textFieldStyle(.plain).fieldStyle(focused: nameFocused)
                    .focused($nameFocused).focusEffectDisabled()
                    .onSubmit(create)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Colour")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                HStack(spacing: 5) {
                    ForEach(ProjectInspector.swatchOrder.filter { ProjectPalette.names.contains($0) }, id: \.self) { c in
                        Button { color = c } label: {
                            Circle().fill(DS.project(c)).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(DS.C.text, lineWidth: color == c ? 2 : 0).padding(-3))
                                .padding(3).contentShape(Rectangle()).padding(-3)
                        }.buttonStyle(.dot).help(c)
                    }
                }
                if color == autoColor {
                    Text(String(localized: "Colour picked for you — no other project uses it yet.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if model.jiraConnected {
                    Text(String(localized: "Rules · tasks that belong here")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    ForEach(keys, id: \.self) { k in
                        HStack {
                            Image(systemName: "key").font(.system(size: 11)).foregroundStyle(DS.C.text3)
                            Text(k).font(DS.F.key)
                            Spacer()
                            Button { keys.removeAll { $0 == k } } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.icon)
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: DS.R.row).fill(DS.C.surface2))
                    }
                    TextField(String(localized: "Jira key, e.g. SEC"), text: $keyText).textFieldStyle(.plain).fieldStyle()
                        .onSubmit { add(keyText) }
                    let free = unused.map(\.1).filter { !keys.contains($0) }
                    if !free.isEmpty {
                        HStack(spacing: 6) {
                            Text(String(localized: "Keys you used without a project")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                            ForEach(free.prefix(4), id: \.self) { k in
                                Button { add(k) } label: { Chip(text: "+ \(k)", color: DS.C.brandText, fill: DS.C.brandSoft) }.buttonStyle(.chip)
                            }
                        }
                    }
                    Button { add(keyText) } label: { Label(String(localized: "Add Jira key"), systemImage: "plus") }
                        .buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium).disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Text(String(localized: "Tasks · come with Jira")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
                    Text(String(localized: "Without Jira you pick the project on each entry yourself. When you connect Jira, add its keys here and tasks file themselves."))
                        .font(DS.F.caption).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
                    Button { AppDelegate.shared?.windows.showSettings(model, tab: .jira) } label: { Label(String(localized: "Connect Jira…"), systemImage: "link") }
                        .buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                }
            }
            Toggle(isOn: $billable) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Billable")).font(DS.F.bodySemibold)
                    Text(String(localized: "Counts towards utilization")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                }
            }.toggleStyle(.brandSwitch)
            Toggle(isOn: $excluded) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Don't count as worked")).font(DS.F.bodySemibold)
                    Text(String(localized: "For Jira tasks that track absences (e.g. a vacation task)")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                }
            }.toggleStyle(.brandSwitch)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { done(nil) }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button(action: create) { Label(String(localized: "Create project"), systemImage: "plus") }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Give the project a name first") : "")
            }
            .accessibilityIdentifier("newProject.actions")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            autoColor = ProjectPalette.nextUnused(model.data.projects.map(\.color))
            color = autoColor
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    private func add(_ raw: String) {
        let k = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !k.isEmpty, !keys.contains(k) else { return }
        keys.append(k); keyText = ""
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if !keyText.trimmingCharacters(in: .whitespaces).isEmpty { add(keyText) }
        let ks: [(UUID, String)] = model.activeInstances.first.map { i in keys.map { (i.id, $0) } } ?? []
        done(model.createProject(name: n, color: color, billable: billable, excludeFromWorked: excluded, keys: ks))
    }
}

/// First run: projects suggested from Jira projects found in imported worklogs (§10.4).
struct FirstRunProposals: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: Set<String> = []

    var body: some View {
        let items = model.unmappedKeys()
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Projects found in your Jira worklogs")).font(DS.F.bodySemibold)
                Text(String(localized: "Confirm the ones you want — name, colour and billable can be changed any time.")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                ForEach(items, id: \.1) { item in
                    Toggle(isOn: Binding(get: { chosen.contains(item.1) }, set: { if $0 { chosen.insert(item.1) } else { chosen.remove(item.1) } })) {
                        HStack {
                            Text(model.pendingProjectSuggestions[item.1]?.0 ?? item.1).font(DS.F.body)
                            Text(item.1).font(DS.F.mono).foregroundStyle(DS.C.text2)
                            Spacer()
                            Text(DurationFormat.hm(model.data.entries.filter { e in model.issue(for: e)?.projectKey == item.1 }.reduce(0) { $0 + $1.duration(now: model.now) }))
                                .font(DS.F.mono).foregroundStyle(DS.C.text2)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                HStack {
                    Button(String(localized: "Not now")) { model.pendingProjectSuggestions = [:] }.buttonStyle(.pill)
                    Button(String(localized: "Create \(chosen.count) projects")) {
                        for item in items where chosen.contains(item.1) {
                            model.createProject(name: model.pendingProjectSuggestions[item.1]?.0 ?? item.1, keys: [(item.0, item.1)])
                        }
                        model.pendingProjectSuggestions = [:]
                    }
                    .buttonStyle(.primaryPill).disabled(chosen.isEmpty)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.brandSoft.opacity(0.6)))
            .onAppear { chosen = Set(items.map(\.1)) }
        }
    }
}

extension AppModel {
    /// Jira keys of tasks you used that no project rule covers yet: (instance, key).
    func unmappedKeys() -> [(UUID, String)] {
        var out: [String: (UUID, String)] = [:]
        for e in data.entries {
            guard let i = issue(for: e) else { continue }
            if !data.rules.contains(where: { $0.instanceId == i.instanceId && $0.value == i.projectKey }) {
                out["\(i.instanceId)|\(i.projectKey)"] = (i.instanceId, i.projectKey)
            }
        }
        for (k, v) in pendingProjectSuggestions where !data.rules.contains(where: { $0.instanceId == v.1 && $0.value == k }) {
            out["\(v.1)|\(k)"] = (v.1, k)
        }
        return out.values.sorted { $0.1 < $1.1 }
    }
}

/// Custom project colours are contrast-checked and darkened if needed (§11.8).
enum ContrastCheck {
    static func safeHex(_ c: Color) -> String {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        var r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        func lum(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
            func ch(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
        }
        // Need ≥ 3:1 against white (dots and edges are non-text UI).
        var i = 0
        while (1.05 / (lum(r, g, b) + 0.05)) < 3 && i < 20 { r *= 0.9; g *= 0.9; b *= 0.9; i += 1 }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

/// Merge a project into another (design "Main · Projects · merge"): pick the target, see what happens, confirm.
struct MergeProjectSheet: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let done: () -> Void
    @State private var targetId: UUID?

    private var targets: [Project] { model.data.projects.filter { $0.id != project.id && !$0.archived }.sorted { $0.name < $1.name } }

    var body: some View {
        let target = targets.first { $0.id == targetId } ?? targets.first
        let keys = model.data.rules.filter { $0.projectId == project.id }.map(\.value).sorted()
        let entries = model.data.entries.filter { $0.projectId == project.id }
        let tasks = Set(entries.compactMap { e in e.issueId.map { "\(e.instanceId?.uuidString ?? "")|\($0)" } }).count
        let seconds = entries.reduce(0) { $0 + $1.duration(now: model.now) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "Merge \(project.name) into another project")).font(DS.F.screenTitle)
                Menu {
                    ForEach(targets) { t in
                        Button { targetId = t.id } label: { Text(t.name) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(String(localized: "Into")).font(DS.F.body).foregroundStyle(DS.C.text2)
                        if let target {
                            Circle().fill(DS.project(target.color)).frame(width: 8, height: 8)
                            Text(target.name).font(DS.F.bodySemibold).foregroundStyle(DS.C.text).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.C.text2)
                    }
                    .padding(.horizontal, 12).frame(height: DS.H.field + 4)
                    .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
                    .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(DS.C.brand, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityIdentifier("merge.target")
                if let target {
                    VStack(alignment: .leading, spacing: 8) {
                        if !keys.isEmpty {
                            impact("key", String(localized: "Keys \(ListFormatter.localizedString(byJoining: keys)) move to \(target.name)"))
                        }
                        impact("list.bullet", String(localized: "\(tasks) tasks and \(DurationFormat.short(seconds)) are re-filed"))
                        impact("paintpalette", String(localized: "\(target.name)'s colour and billable setting (\(target.billable ? String(localized: "billable") : String(localized: "non-billable"))) apply"))
                        impact("archivebox", String(localized: "\(project.name) disappears from the list"))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface2))
                }
                Text(String(localized: "Nothing changes in Jira. You can undo this right after (⌘Z).")).font(DS.F.caption).foregroundStyle(DS.C.text3)
            }
            .padding(20)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { done() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button {
                    if let target { model.mergeProject(project, into: target) }
                    done()
                } label: {
                    Label(String(localized: "Merge into \(target?.name ?? "")"), systemImage: "arrow.triangle.merge").lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction).disabled(target == nil)
                .accessibilityIdentifier("merge.confirm")
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 440)
        .presentationBackground(DS.C.surface)
    }

    private func impact(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DS.C.text2).frame(width: 16)
            Text(text).font(DS.F.body).foregroundStyle(DS.C.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
