import SwiftUI
import TikjotDomain
import TikjotPersistence
import TikjotSuggestions

/// The timer capsule and the panels it brings forward: task picker and start-time panel (§11.1).
struct CapsuleArea: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var editingDescription = false
    @State private var commandOverTask = false
    /// Edit buffer for the running entry's description — separate from `draft` (the idle "What are you working on?").
    @State private var editDraft = ""
    /// Highlighted row in the description suggestions (nil = none: ↩ starts what you typed as a new entry).
    @State private var suggestionIndex: Int?
    /// The idle suggestions stay up for a moment after the field loses focus, so a click on a row lands.
    @State private var idlePanel = false
    /// Start / ⌥⌘T with nothing typed: the list shows even when there's no earlier work yet (then just its hint line).
    @State private var startRequested = false
    @FocusState private var descFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Storyboard A: the Start pill morphs into the coral time pill (frame + violet → coral cross-fade).
    @Namespace private var morph

    private var editing: PopoverEditing? { model.popoverEditing }
    /// Idle and running capsules share one height (design: 64 pt), so start/stop never resizes the popover.
    static let height: CGFloat = 64

    var body: some View {
        VStack(spacing: 8) {
            // ZStack, not Group: during the cross-fade both capsules exist and must overlap, not stack (that doubled the height).
            ZStack {
                if let r = model.runningEntry {
                    runningCapsule(r).transition(.opacity)
                } else {
                    idleCapsule.transition(.opacity)
                }
            }
            // Storyboards A/B: 100 → 260 ms morph; Reduce Motion → cross-fade. Taller only for a multi-line description.
            .frame(minHeight: Self.height)
            .animation(Motion.pick(reduceMotion, Motion.easeOut(0.26)), value: model.runningEntry?.id)
            .onChange(of: model.runningEntry?.id) { _, _ in editingDescription = false; editDraft = "" }
            .onAppear {
                // Debug/captures: -popoverEditDesc "text" opens the running description for editing.
                let a = LaunchFlags.args
                if model.runningEntry != nil, let i = a.firstIndex(of: "-popoverEditDesc"), a.indices.contains(i + 1) {
                    editDraft = a[i + 1]; editingDescription = true; DispatchQueue.main.async { descFocused = true }
                }
            }
            .faded(editing != nil && editing != .picker(.timer) && editing != .startTime)
            // ⌥⌘T / "Start a timer" while idle: type first — the description field with your recent work.
            .onChange(of: model.descriptionFocusRequest) { _, _ in if model.runningEntry == nil { focusDescription() } }

            // A second line makes it your own text: the suggestions step aside (owner 2026-10-22).
            if let r = model.runningEntry, editingDescription, editing == nil, !editDraft.contains(where: \.isNewline) {
                // Same suggestions while running: a pick changes this entry (description + task), the start stays.
                let items = model.descriptionSuggestions(editDraft, limit: editDraft.isEmpty ? 4 : 5)
                    .filter { !($0.description == r.description && $0.issueId == r.issueId) }
                panel { DescriptionSuggestionList(query: editDraft, items: items, highlighted: suggestionIndex,
                                                  newTitle: { String(localized: "Keep “\($0)”") }, newHint: String(localized: "only the description changes"),
                                                  footer: String(localized: "↑↓ choose · ↩ use · Tab task"),
                                                  pick: { applySuggestion($0, to: r) }, startNew: { saveDescription(r) }) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if model.runningEntry == nil && editing == nil && idlePanel && !draft.contains(where: \.isNewline)
                        && (!draftSuggestions.isEmpty || !draft.isEmpty || startRequested) {
                panel { DescriptionSuggestionList(query: draft, items: draftSuggestions, highlighted: suggestionIndex,
                                                  newHint: String(localized: "↩ pick its task"),
                                                  footer: String(localized: "↑↓ choose · ↩ pick a task · ⌘↩ start without a task"),
                                                  pick: { startSuggestion($0) }, startNew: { pickTaskForNew() }) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if editing == .picker(.timer) {
                // Idle: step 2 of starting — the picker starts the timer with `draft` as the description.
                panel {
                    TaskPicker(seed: model.runningEntry == nil ? "" : draft, currentKey: model.runningEntry.flatMap { model.issue(for: $0)?.key }, preferProject: model.runningEntry?.projectId,
                               contextDescription: model.runningEntry == nil && !draft.isEmpty ? draft.descriptionFirstLine : nil) { issue, pid in
                        // One transaction: the panel folds away while the capsule morphs (no jump in the popover height).
                        Motion.animate(Motion.easeOut(0.26)) {
                            if let r = model.runningEntry {
                                // Change the running entry's task.
                                model.setTask(issue, projectId: pid, for: [r])
                            } else {
                                model.start(issue: issue, projectId: pid, description: draft.trimmingCharacters(in: .whitespacesAndNewlines))
                                draft = ""
                            }
                            model.popoverEditing = nil
                        }
                    } onCancel: {
                        // Esc: back to the description field and its suggestions (idle).
                        Motion.animate(Motion.easeOut(0.2)) { model.popoverEditing = nil }
                        if model.runningEntry == nil { focusDescription() }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if editing == .startTime, let r = model.runningEntry {
                panel { StartTimePanel(entry: r) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func panel<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(10)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.brand, lineWidth: 1.5))
            .shadow(color: Color(hex: "#17152A2E")!, radius: 13, y: 10)
    }

    // MARK: Idle — "What are you working on?" + Start

    private var idleCapsule: some View {
        let multi = draft.contains(where: \.isNewline)
        return HStack(alignment: multi ? .top : .center, spacing: 8) {
            Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(DS.C.text3)
                .padding(.top, multi ? 3 : 0)
            // Typed text looks exactly like the running description (15 semibold) so nothing changes on Start;
            // only the placeholder is regular. ⇧↩ adds a line (quietly — owner 2026-10-22); the capsule grows.
            TextField(String(localized: "What are you working on?"), text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(draft.isEmpty ? .system(size: 15) : DS.F.title)
                .foregroundStyle(DS.C.text)
                .accessibilityIdentifier("capsule.idleField")
                .focused($descFocused)
                .focusEffectDisabled()   // the capsule outline is the focus indicator (no stray system ring)
                .onSubmit { startTapped() }
                .shiftReturnAddsLine()
                // Tab = the task field (only tasks, then projects); ↑↓ move through your earlier entries.
                .onKeyPress(.tab) { model.popoverEditing = .picker(.timer); return .handled }
                // With several lines the arrows move the caret between them.
                .onKeyPress(.downArrow) { if multi { return .ignored }; moveSuggestion(1); return .handled }
                .onKeyPress(.upArrow) { if multi { return .ignored }; moveSuggestion(-1); return .handled }
                .onKeyPress(.escape) { if suggestionIndex != nil { suggestionIndex = nil; return .handled }; return .ignored }
            taskButton
            Button(action: startTapped) {
                Label(String(localized: "Start"), systemImage: "play").labelStyle(.titleAndIcon)
                    .font(DS.F.bodyMedium).lineLimit(1)
                    .padding(.horizontal, 12).frame(height: 36)
                    .foregroundStyle(DS.C.onBrand)
                    .background(Capsule().fill(DS.C.brand).matchedGeometryEffect(id: "timerPill", in: morph))
                    .contentShape(Capsule())
            }
            // Storyboard A · 2–3: hover lifts, press squishes to 0.92 with a ring flash.
            .buttonStyle(.squish(ring: DS.C.brand))
        }
        // ⌘↩: start what you typed right away, without a task (and without a guessed project).
        .background {
            Button("", action: startWithoutTask).keyboardShortcut(.return, modifiers: .command)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .padding(.vertical, multi ? 10 : 0)
        .frame(minHeight: Self.height)
        .capsuleSurface(DS.C.surface, border: descFocused || editing == .picker(.timer) ? DS.C.focusRingStrong : DS.C.borderStrong,
                        lineWidth: descFocused || editing == .picker(.timer) ? 1.5 : 1, clip: false,   // Start's ring flash reaches past
                        radius: Self.height / 2)
        .onChange(of: draft) { _, _ in suggestionIndex = nil }
        .onChange(of: descFocused) { _, f in
            if f {
                idlePanel = true
                // Back in the description (click or ⇧Tab) while the task list is up: the list follows focus.
                if editing == .picker(.timer) { model.popoverEditing = nil }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if !descFocused { idlePanel = false; startRequested = false } }
            }
        }
        .onAppear {
            // Debug/captures: -popoverDraft "text" types into the field.
            let a = LaunchFlags.args
            if let i = a.firstIndex(of: "-popoverDraft"), a.indices.contains(i + 1) { draft = a[i + 1] }
            DispatchQueue.main.async { idlePanel = descFocused }
        }
    }

    /// K4 (beta 2026-10-08, rows 8 + 13): the task has a visible home in the idle capsule — the same as Tab, and lit
    /// while the task step is open.
    private var taskButton: some View {
        let on = editing == .picker(.timer)
        return Button {
            if on {
                model.popoverEditing = nil
                focusDescription()
            } else {
                suggestionIndex = nil
                model.popoverEditing = .picker(.timer)
            }
        } label: {
            Image(systemName: "tag").font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? DS.C.brand : DS.C.text2)
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? DS.C.brandSoft : DS.C.surface2))
                .overlay(Circle().strokeBorder(on ? DS.C.brand : DS.C.border, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(TapButtonStyle(shape: AnyShape(Circle()), pressScale: 0.9))
        .help(String(localized: "Task (Tab)"))
        .accessibilityLabel(String(localized: "Task"))
        .accessibilityIdentifier("capsule.taskButton")
    }

    private var draftSuggestions: [DescriptionSuggestions.Suggestion] { model.descriptionSuggestions(draft, limit: draft.isEmpty ? 4 : 5) }

    private func moveSuggestion(_ d: Int) {
        let n = draftSuggestions.count + (draft.isEmpty ? 0 : 1)
        guard n > 0 else { return }
        if let i = suggestionIndex { let j = i + d; suggestionIndex = j < 0 ? nil : min(j, n - 1) } else if d > 0 { suggestionIndex = 0 }
    }

    /// ↩ / Start: the highlighted earlier entry (with its task, at once), otherwise what you typed as a new entry —
    /// which goes to the task step first (K4, beta 2026-10-08: nothing is guessed). Nothing typed: the description
    /// field with your recent work (owner 2026-10-07: type first; the task field is Tab away).
    private func startTapped() {
        let list = draftSuggestions
        if let i = suggestionIndex, list.indices.contains(i) { startSuggestion(list[i]); return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusDescription()
            return
        }
        pickTaskForNew()
    }

    /// A new description: the task picker opens (the description stays); a pick there starts the timer. Without Jira
    /// and without any project there's nothing to pick — it starts right away.
    private func pickTaskForNew() {
        guard model.jiraConnected || model.data.projects.contains(where: { !$0.archived }) else { startNew(); return }
        suggestionIndex = nil
        model.popoverEditing = .picker(.timer)
    }

    /// ⌘↩: what you typed starts now, without a task. Nothing typed: the description field, as Start.
    private func startWithoutTask() {
        guard model.runningEntry == nil else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { focusDescription(); return }
        if editing == .picker(.timer) { model.popoverEditing = nil }
        startNew()
    }

    private func focusDescription() {
        startRequested = true
        idlePanel = true
        DispatchQueue.main.async { descFocused = true }
    }

    private func moveRunningSuggestion(_ d: Int, _ r: TimeEntry) {
        let n = model.descriptionSuggestions(editDraft, limit: editDraft.isEmpty ? 4 : 5)
            .filter { !($0.description == r.description && $0.issueId == r.issueId) }.count + (editDraft.isEmpty ? 0 : 1)
        guard n > 0 else { return }
        if let i = suggestionIndex { let j = i + d; suggestionIndex = j < 0 ? nil : min(j, n - 1) } else if d > 0 { suggestionIndex = 0 }
    }

    /// While running: take an earlier entry's description and task for this entry (its start stays).
    private func applySuggestion(_ s: DescriptionSuggestions.Suggestion, to r: TimeEntry) {
        editingDescription = false; descFocused = false; editDraft = ""; suggestionIndex = nil
        model.pendingDescription = nil
        guard var x = model.runningEntry, x.id == r.id else { return }
        x.description = s.description
        model.update(x, name: "Edit description")
        if let cur = model.runningEntry {
            model.setTask(model.issue(instanceId: s.instanceId, issueId: s.issueId), projectId: s.projectId, for: [cur])
        }
    }

    private func startSuggestion(_ s: DescriptionSuggestions.Suggestion) {
        // An earlier entry with neither task nor project (Jira connected): its description, then pick the task.
        if s.issueId == nil && s.projectId == nil && model.jiraConnected {
            draft = s.description; suggestionIndex = nil
            model.popoverEditing = .picker(.timer)
            return
        }
        Motion.animate(Motion.easeOut(0.26)) {
            model.start(issue: model.issue(instanceId: s.instanceId, issueId: s.issueId), projectId: s.projectId, description: s.description)
            draft = ""; suggestionIndex = nil
        }
    }

    private func startNew() {
        Motion.animate(Motion.easeOut(0.26)) {
            // No task, no project — unless one is picked (row 13: no silent guess).
            model.start(description: draft.trimmingCharacters(in: .whitespacesAndNewlines))
            draft = ""; suggestionIndex = nil
        }
    }

    // MARK: Running — description + task left, coral time pill right

    private func runningCapsule(_ r: TimeEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if editingDescription {
                    TextField(String(localized: "What are you working on?"), text: $editDraft, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain).font(DS.F.title)
                        .accessibilityIdentifier("capsule.descriptionField")
                        .focused($descFocused)
                        .onSubmit {
                            let items = model.descriptionSuggestions(editDraft, limit: editDraft.isEmpty ? 4 : 5)
                                .filter { !($0.description == r.description && $0.issueId == r.issueId) }
                            if let i = suggestionIndex, items.indices.contains(i) { applySuggestion(items[i], to: r) } else { saveDescription(r) }
                        }
                        .shiftReturnAddsLine()
                        .onKeyPress(.downArrow) { if editDraft.contains(where: \.isNewline) { return .ignored }; moveRunningSuggestion(1, r); return .handled }
                        .onKeyPress(.upArrow) { if editDraft.contains(where: \.isNewline) { return .ignored }; moveRunningSuggestion(-1, r); return .handled }
                        .onKeyPress(.tab) { saveDescription(r); model.popoverEditing = .picker(.timer); return .handled }
                        .onKeyPress(.escape) { editingDescription = false; model.pendingDescription = nil; return .handled }
                        .onChange(of: editDraft) { _, v in model.pendingDescription = (r.id, v) }
                        // Losing focus saves — a moment later, so a click on a suggestion lands first.
                        .onChange(of: descFocused) { _, f in
                            if !f { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if editingDescription && !descFocused { saveDescription(r) } } }
                        }
                } else {
                    Button {
                        editDraft = r.description
                        suggestionIndex = nil
                        // The list follows focus: the description's suggestions replace an open task list.
                        if editing == .picker(.timer) { model.popoverEditing = nil }
                        editingDescription = true
                        DispatchQueue.main.async { descFocused = true }
                    } label: {
                        DescriptionLabel(text: r.description.isEmpty ? String(localized: "Add a description") : r.description,
                                         font: DS.F.title, color: r.description.isEmpty ? DS.C.text3 : DS.C.text)
                    }
                    .buttonStyle(.plain)
                }
                let jiraKey = model.jiraURL(r.issueRef) == nil ? nil : model.issue(for: r)?.key
                let link = commandOverTask && jiraKey != nil
                Button {
                    // Beta 2026-10-25: ⌘-click opens the task in Jira; a plain click picks another task.
                    if NSEvent.modifierFlags.contains(.command), jiraKey != nil { openInJira(r); return }
                    model.popoverEditing = model.popoverEditing == .picker(.timer) ? nil : .picker(.timer)
                } label: {
                    HStack(spacing: 3) {
                        taskTag(r, link: link)
                        Image(systemName: link ? "arrow.up.right" : "chevron.down").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(link ? DS.C.brandText : DS.C.text3)
                    }
                }
                .buttonStyle(.plain)
                .commandHover($commandOverTask)
                .help(jiraKey.map { String(localized: "Change task · ⌘-click opens \($0) in Jira") } ?? "")
                .contextMenu {
                    if let jiraKey {
                        Button { openInJira(r) } label: { Label(String(localized: "Open \(jiraKey) in Jira"), systemImage: "arrow.up.forward.square") }
                    }
                }
            }
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                TimePill(elapsed: Int(Clock.now.timeIntervalSince(r.start)),
                         timeAction: { model.popoverEditing = model.popoverEditing == .startTime ? nil : .startTime },
                         justStarted: Clock.now.timeIntervalSince(r.start) < 1.5,
                         stop: {
                             // A description typed without ↩ still belongs to this entry.
                             saveDescription(r)
                             Motion.animate(Motion.easeOut(0.26)) { model.stop() }
                         })
                    .help(String(localized: "Started \(Fmt.time(r.start)) · click to change"))
            }
            .matchedGeometryEffect(id: "timerPill", in: morph)
            .clipShape(Capsule())
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .padding(.vertical, editingDescription && editDraft.contains(where: \.isNewline) ? 10 : 0)
        .frame(minHeight: Self.height)
        .capsuleSurface(DS.C.tickSoft, border: editing == .startTime ? DS.C.tick : .clear, lineWidth: 1.5, clip: false, radius: Self.height / 2)
    }

    private func openInJira(_ r: TimeEntry) {
        model.openInJira(r.issueRef)
        MenuBarController.shared?.closePopover()
    }

    @ViewBuilder
    private func taskTag(_ e: TimeEntry, link: Bool = false) -> some View {
        if let i = model.issue(for: e) {
            TaskTag(key: i.key, name: i.summary, color: model.project(e.projectId)?.color ?? "slate", link: link)
        } else if let p = model.project(e.projectId) {
            // K4 · running, project only: the project's tag (beta 2026-10-08).
            HStack(spacing: 4) {
                Circle().fill(DS.project(p.color)).frame(width: 7, height: 7)
                Image(systemName: "tag").font(.system(size: 9)).foregroundStyle(DS.C.text3)
                Text(p.name).font(DS.F.caption).foregroundStyle(DS.C.text2).lineLimit(1)
            }
            .help(String(localized: "\(p.name) · no task"))
        } else {
            // K4 · running, no task and no project: quiet — Review & send asks for the task before Jira.
            HStack(spacing: 4) {
                Image(systemName: "tag").font(.system(size: 9)).foregroundStyle(DS.C.text3)
                Text(String(localized: "No task yet")).font(DS.F.caption).foregroundStyle(DS.C.text3)
            }
        }
    }

    private func saveDescription(_ r: TimeEntry) {
        guard editingDescription else { return }
        editingDescription = false
        descFocused = false
        model.pendingDescription = nil
        defer { editDraft = "" }
        let text = editDraft.trimmingCharacters(in: .newlines)
        guard var x = model.runningEntry, x.id == r.id, x.description != text else { return }
        x.description = text
        model.update(x, name: "Edit description")
    }
}

/// Start-time panel: smart picks + typed time (§11.1).
struct StartTimePanel: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    @State private var typed = ""
    @State private var choice: Date?

    private var picks: [(String, Date)] {
        var out: [(String, Date)] = []
        let today = model.ledger.workEntries(on: model.today).filter { $0.id != entry.id && $0.end != nil && $0.end! <= entry.start.addingTimeInterval(3600 * 4) }
        if let prev = today.last, let end = prev.end {
            out.append((String(localized: "When “\(prev.description.isEmpty ? model.taskLabel(for: prev) : prev.description)” ended"), end))
        }
        out.append((String(localized: "15 min earlier"), entry.start.addingTimeInterval(-15 * 60)))
        out.append((String(localized: "5 min earlier"), entry.start.addingTimeInterval(-5 * 60)))
        if let woke = model.lastWake, woke < entry.start, LocalDate(woke, calendar: .current) == model.today {
            out.append((String(localized: "When your Mac woke"), woke))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Started at \(Fmt.time(entry.start))")).font(DS.F.bodySemibold)
            ForEach(Array(picks.enumerated()), id: \.offset) { _, p in
                Button { model.setRunningStart(p.1); model.popoverEditing = nil } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(DS.C.text3)
                        Text(p.0).font(DS.F.body).lineLimit(1)
                        Spacer()
                        Text(Fmt.time(p.1)).font(DS.F.monoMedium)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.row)
            }
            SectionLabel(String(localized: "Or type a time")).padding(.top, 4)
            HStack {
                // Pre-filled with the current start, ready to edit.
                TextField(Fmt.time(entry.start), text: $typed).textFieldStyle(.plain).font(DS.F.monoBig).fieldStyle()
                    .onSubmit(set)
                    .onAppear { if typed.isEmpty { typed = Fmt.time(entry.start) } }
                Button(String(localized: "Set"), action: set).buttonStyle(.pill(.tick))
                    .disabled(TimeOfDayParser.parse(typed) == nil || typed == Fmt.time(entry.start))
            }
            if let m = TimeOfDayParser.parse(typed), typed != Fmt.time(entry.start) {
                let d = model.today.at(minutes: m, in: .current)
                let overlapping = model.ledger.workEntries(on: model.today).first { $0.id != entry.id && ($0.end ?? model.now) > d && $0.start < entry.start }
                Text(overlapping.map { String(localized: "Elapsed becomes \(DurationFormat.clock(Int(model.now.timeIntervalSince(d)), seconds: true)). Overlaps “\($0.description.descriptionFirstLine)” — earlier entries are never cut; the overlap is named in the Day.") }
                     ?? String(localized: "Elapsed becomes \(DurationFormat.clock(max(0, Int(model.now.timeIntervalSince(d))), seconds: true))."))
                    .font(DS.F.caption).foregroundStyle(DS.C.text3)
            }
        }
        .onAppear { typed = "" }
    }

    private func set() {
        guard let m = TimeOfDayParser.parse(typed) else { return }
        model.setRunningStart(model.today.at(minutes: m, in: .current))
        model.popoverEditing = nil
    }
}


/// The list under "What are you working on?": your earlier entries (description + task), then "Start … as new".
struct DescriptionSuggestionList: View {
    @Environment(AppModel.self) private var model
    let query: String
    let items: [DescriptionSuggestions.Suggestion]
    let highlighted: Int?
    var newTitle: (String) -> String = { String(localized: "Start “\($0)” as new") }
    var newHint = String(localized: "Tab — pick a task for it")
    var footer = String(localized: "↑↓ choose · ↩ start · Tab task")
    /// Editing a finished entry: no "as new" row — what you type simply stays the description.
    var showNew = true
    let pick: (DescriptionSuggestions.Suggestion) -> Void
    let startNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !items.isEmpty {
                SectionLabel(query.isEmpty ? String(localized: "Recent") : String(localized: "From your entries · \(items.count)"))
                    .padding(.horizontal, 6).padding(.top, 4)
                ForEach(Array(items.enumerated()), id: \.element.id) { i, s in row(s, on: highlighted == i) }
            }
            if showNew && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: startNew) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.brandText).frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(newTitle(query)).font(DS.F.body).foregroundStyle(DS.C.text).lineLimit(1)
                            Text(newHint).font(DS.F.caption).foregroundStyle(highlighted == items.count ? DS.C.text2 : DS.C.text3)
                        }
                        Spacer(minLength: 4)
                        if highlighted == items.count || (highlighted == nil) {
                            Image(systemName: "return").font(.system(size: 10)).foregroundStyle(highlighted == items.count ? DS.C.text2 : DS.C.text3)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.R.row).fill(highlighted == items.count ? DS.C.brandSoft.opacity(0.7) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.rowPress)
                .accessibilityIdentifier("suggestions.startNew")
            }
            Text(footer).font(DS.F.caption).foregroundStyle(DS.C.text3).padding(.horizontal, 6).padding(.top, 2)
        }
    }

    private func row(_ s: DescriptionSuggestions.Suggestion, on: Bool) -> some View {
        let issue = model.issue(instanceId: s.instanceId, issueId: s.issueId)
        let project = model.project(s.projectId ?? issue.flatMap { model.projectId(for: $0) })
        // Tertiary text on the highlighted (brand-soft) row reads as secondary — text3 on brand-soft is under 4.5:1.
        let t3 = on ? DS.C.text2 : DS.C.text3
        return Button { pick(s) } label: {
            HStack(spacing: 8) {
                TimeEdge(color: DS.project(project?.color ?? "slate")).frame(height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    DescriptionLabel(text: s.description, font: DS.F.bodySemibold)
                    HStack(spacing: 4) {
                        if let issue {
                            TaskTag(key: issue.key, name: issue.summary, color: project?.color ?? "slate", selected: on)
                        } else {
                            Text(project?.name ?? String(localized: "No task")).font(DS.F.caption).foregroundStyle(t3).lineLimit(1)
                        }
                        Text("· " + when(s)).font(DS.F.caption).foregroundStyle(t3).lineLimit(1).fixedSize()
                    }
                }
                Spacer(minLength: 4)
                if on { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(t3) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(on ? DS.C.brandSoft.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
        .accessibilityIdentifier("suggestion.row")
    }

    private func when(_ s: DescriptionSuggestions.Suggestion) -> String {
        if s.count >= 3 { return String(localized: "\(s.count) times") }  // not a cryptic "11×" (audit copy)
        return Fmt.dayName(LocalDate(s.lastUsed, calendar: .current), today: model.today)
    }
}
