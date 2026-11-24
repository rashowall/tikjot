import SwiftUI
import TikjotDomain
import TikjotPersistence

/// Last 7 days as soft cards (§11.1); rows edit in place, one entry at a time.
struct DayList: View {
    @Environment(AppModel.self) private var model
    @Binding var scrolled: Bool
    @Environment(\.popoverMaxHeight) private var popoverMaxHeight

    private var days: [LocalDate] {
        let t = model.today
        return (0..<7).map { t.adding(days: -$0) }.filter { d in
            d == t || !model.ledger.entries(on: d).isEmpty || !model.absences(on: d).isEmpty
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                ForEach(days, id: \.self) { d in
                    DayCard(day: d)
                }
                VStack(spacing: 8) {
                    Rectangle().fill(DS.C.border).frame(width: 40, height: 1)
                    Text(String(localized: "That's the last 7 days")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                    Button {
                        MenuBarController.shared?.closePopover()
                        AppDelegate.shared?.windows.showMain(model)
                    } label: { Label(String(localized: "Older days in the main window"), systemImage: "chevron.right").labelStyle(.titleOnly) }
                    .buttonStyle(.pill(.secondary, height: DS.H.small))
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            // Measured on the whole stack, not a first row: the lazy stack drops a row scrolled out of view, its
            // preference falls back to 0 and the header thought the list was at the top (beta 2026-10-21).
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: ScrollOffsetKey.self, value: g.frame(in: .named("daylist")).minY)
                }
            }
        }
        .coordinateSpace(name: "daylist")
        .onPreferenceChange(ScrollOffsetKey.self) { y in
            // Compact header past 40 pt, the full one back only near the top: the header's own height change
            // shifts the list, and one threshold would flip it back and forth (beta 2026-10-14, layout loop).
            let s = scrolled ? y < -8 : y < -40
            if s != scrolled { withAnimation(.easeOut(duration: 0.15)) { scrolled = s } }
        }
        // While something is edited above (task step, start time…) the faded list may give up all its room, so the
        // header and footer stay in a popover at its height cap (owner 2026-10-22).
        .frame(minHeight: model.popoverEditing == nil ? 120 : 0, idealHeight: idealHeight, maxHeight: maxHeight)
    }

    /// The popover's cap minus its header, capsule and bottom line (460 at the old 640).
    private var maxHeight: CGFloat { max(120, popoverMaxHeight - PopoverHeight.chrome) }

    private var idealHeight: CGFloat {
        let rows = days.reduce(0) { $0 + max(1, model.ledger.entries(on: $1).count + model.absences(on: $1).count) }
        return min(maxHeight, CGFloat(60 + rows * 46 + days.count * 40))
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct DayCard: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate

    var body: some View {
        let l = model.ledger
        let entries = l.entries(on: day).reversed()
        let status = l.dayStatus(day, lock: model.lock, jiraConnected: model.jiraConnected)
        let isEditingHere = { () -> Bool in
            if case .entry(let id) = model.popoverEditing { return entries.contains { $0.id == id } }
            if case .picker(.entry(let id)) = model.popoverEditing { return entries.contains { $0.id == id } }
            return false
        }()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(day == model.today ? String(localized: "Today") : (day == model.today.adding(days: -1) ? String(localized: "Yesterday") : Fmt.short(day)))
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.C.text2)   // design popover/day-head IBdR3
                Spacer()
                // One "needs you" (audit U1): blockers only, with their unit — the same number as the header.
                let need = NeedsYouText.items(model.needsYou(on: day))
                if let need, day < model.today || Moment.current(model).title == String(localized: "Nearly done") {
                    HStack(spacing: 4) { NeedsYouDot(); Text(need) }
                        .font(DS.F.caption).foregroundStyle(DS.C.text)
                } else if status == .waiting || status == .failed || status == .conflict {
                    HStack(spacing: 5) { Circle().fill(DS.C.borderStrong).frame(width: 6, height: 6); Text(String(localized: "not in Jira")) }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text3)
                } else if status == .allInJira {
                    HStack(spacing: 5) { Circle().fill(DS.C.success).frame(width: 6, height: 6); Text(String(localized: "in Jira")) }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.successText)
                }
                Text(DurationFormat.short(l.worked(day))).font(DS.F.mono).foregroundStyle(DS.C.text2).rolls(DurationFormat.short(l.worked(day)))
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
            .faded(model.popoverEditing != nil && !isEditingHere)

            ForEach(model.absences(on: day)) { a in
                AbsenceRow(absence: a)
                    .faded(model.popoverEditing != nil)
            }
            ForEach(Array(entries)) { e in
                if e.kind == .breakTime {
                    BreakRow(entry: e).faded(model.popoverEditing != nil)
                } else if case .entry(e.id) = model.popoverEditing {
                    PopoverEntryEditor(entry: model.data.entries.first { $0.id == e.id } ?? e, day: day)
                } else if case .picker(.entry(e.id)) = model.popoverEditing {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(String(localized: "Task for “\(e.description)”"))
                        TaskPicker(seed: e.description, preferProject: e.projectId) { issue, pid in
                            model.setTask(issue, projectId: pid, for: [model.data.entries.first { $0.id == e.id } ?? e])
                            model.popoverEditing = nil
                        } onCancel: { model.popoverEditing = nil }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                    .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.brand, lineWidth: 1.5))
                } else {
                    PopoverEntryRow(entry: e, day: day)
                        .faded(model.popoverEditing != nil)
                }
            }
        }
        // Design day card (uLFrG): surface, no outline, padding 8 / 6.
        .padding(.horizontal, 6).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
    }
}

struct PopoverEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    let day: LocalDate
    @State private var hover = false
    @State private var command = false

    var body: some View {
        let color = model.project(entry.projectId)?.color ?? "slate"
        let issue = model.issue(for: entry)
        let jira = model.jiraURL(entry.issueRef) != nil
        let noTask = issue == nil && model.jiraConnected
        let line = model.ledger.lines(on: day).first { $0.entries.contains { $0.id == entry.id } }
        let state = line.map { model.ledger.state(of: $0, lock: model.lock) }
        let locked = model.lock.isLocked(day, today: model.today)
        // Design `popover/entry` (LPpHT): padding 7/8, gap 10; description 13/500 (the running one 700);
        // task line: 5 pt dot, key mono 10/600 and name 11, both text-tertiary.
        HStack(spacing: 10) {
            TimeEdge(color: DS.project(color)).frame(height: 30)
            VStack(alignment: .leading, spacing: 2) {
                DescriptionLabel(text: entry.description.isEmpty ? (issue?.summary ?? String(localized: "No description")) : entry.description,
                                 font: .system(size: 13, weight: entry.isRunning ? .bold : .medium))
                if let issue {
                    HStack(spacing: 5) {
                        Circle().fill(DS.project(color)).frame(width: 5, height: 5)
                        KeyName(key: issue.key, name: issue.summary, nameFont: .system(size: 11), nameColor: DS.C.text3, spacing: 5, minName: 40, stacked: false,
                                link: command && jira)
                    }
                } else if noTask && entry.isRunning == false {
                    HStack(spacing: 5) {
                        NoTaskMark(size: 11)
                        Text(String(localized: "No task · Pick task")).font(DS.F.caption).foregroundStyle(DS.C.text)
                    }
                } else {
                    TaskTag(key: nil, name: model.project(entry.projectId).map { String(localized: "\($0.name) · no task") } ?? String(localized: "No task"), color: color)
                }
            }
            Spacer(minLength: 6)
            if entry.isRunning {
                Text("\(Fmt.time(entry.start))–\(String(localized: "now"))").font(DS.F.mono).foregroundStyle(DS.C.tickText)
            } else if hover && !locked {
                Text(Fmt.range(entry.start, entry.end)).font(DS.F.mono).foregroundStyle(DS.C.text3)
                Button { model.continueEntry(entry, newDescription: NSEvent.modifierFlags.contains(.option)) } label: {
                    Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(DS.C.brand)
                        .frame(width: 22, height: 22).background(Circle().fill(DS.C.brandSoft))
                        .padding(3).contentShape(Rectangle()).padding(-3)   // 28 pt hit target, 22 pt look
                }
                .buttonStyle(.dot)
                .help(String(localized: "Continue · ⌥-click: same task, new description"))
            } else {
                if state == .synced { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.success) }
                if state == .error { Image(systemName: "exclamationmark.circle").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.C.danger) }
                Text(DurationFormat.short(entry.duration(now: model.now))).font(DS.F.mono).foregroundStyle(DS.C.text2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: DS.R.row).fill(noTask && !entry.isRunning ? DS.C.warningSoft : (hover ? DS.C.surface2 : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onAppear {
            // Debug/captures (promo video): -hoverEntry "description" shows that row as hovered.
            let a = LaunchFlags.args
            if let i = a.firstIndex(of: "-hoverEntry"), a.indices.contains(i + 1), a[i + 1] == entry.description, !entry.isRunning { hover = true }
        }
        .commandHover($command)
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command), jira { openInJira(); return }
            guard !locked else { return }
            if noTask && !entry.isRunning { model.popoverEditing = .picker(.entry(entry.id)) } else { model.popoverEditing = .entry(entry.id) }
        }
        .contextMenu {
            Button { model.continueEntry(entry) } label: { Label(String(localized: "Continue"), systemImage: "play") }
            if let issue, jira {
                Divider()
                Button { openInJira() } label: { Label(String(localized: "Open \(issue.key) in Jira"), systemImage: "arrow.up.forward.square") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: String(localized: "Continue")) { model.continueEntry(entry) }
    }

    private func openInJira() {
        model.openInJira(entry.issueRef)
        MenuBarController.shared?.closePopover()
    }
}

struct AbsenceRow: View {
    @Environment(AppModel.self) private var model
    let absence: Absence

    var body: some View {
        let t = model.absenceType(absence.typeId)
        HStack(spacing: 8) {
            TimeEdge(color: DS.C.brand).frame(height: 30)
            Image(systemName: t?.icon ?? "sun.horizon").font(.system(size: 11)).foregroundStyle(DS.C.brandText)
            VStack(alignment: .leading, spacing: 2) {
                Text(t?.name ?? String(localized: "Absence")).font(DS.F.bodyMedium).foregroundStyle(DS.C.brandText)
                Text(effectText).font(DS.F.caption).foregroundStyle(DS.C.text3)
            }
            Spacer()
            Text(absence.unit == .hours ? DurationFormat.short(absence.amountSeconds) : (absence.unit == .halfDay ? String(localized: "½ day") : String(localized: "whole day")))
                .font(DS.F.mono).foregroundStyle(DS.C.text2)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private var effectText: String {
        let cal = model.dayCalendar
        let base = cal.baseFund(absence.date)
        return String(localized: "Absence · expected \(DurationFormat.short(base)) → \(DurationFormat.short(cal.fund(absence.date)))")
    }
}

struct BreakRow: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cup.and.saucer").font(.system(size: 10)).foregroundStyle(DS.C.text3)
            DescriptionLabel(text: entry.description.isEmpty ? String(localized: "Break") : entry.description, font: DS.F.caption, color: DS.C.text3)
            Text(String(localized: "· doesn't count")).font(DS.F.caption).foregroundStyle(DS.C.text3)
            Spacer()
            Text(Fmt.range(entry.start, entry.end)).font(DS.F.mono).foregroundStyle(DS.C.text3)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
    }
}

/// Entry editor in place: description, task, START / END / LENGTH, overlap choices, Delete / Cancel / Done.
/// Done (or ↩) also applies a time or length still being typed; Cancel / Esc drop it. In a time field ↩ applies what
/// you typed (the length follows), a second ↩ is Done.
struct PopoverEntryEditor: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    let day: LocalDate
    @State private var desc = ""
    @State private var start = Clock.now
    @State private var end = Clock.now
    @State private var length = 0
    @State private var pickingTask = false
    @State private var overlapChoice: OverlapChoices.Choice = .keepBoth
    @State private var loaded = false
    @State private var commits = FieldCommits()
    @State private var suggestion: Int?
    @FocusState private var descFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DescriptionEditField(placeholder: String(localized: "Description"), text: $desc, entry: entry,
                                 focused: $descFocused, highlighted: $suggestion) { s in
                // An earlier entry: its description now (applied on Done) and its task right away, like the task picker.
                model.setTask(model.issue(instanceId: s.instanceId, issueId: s.issueId), projectId: s.projectId, for: [entry])
            }
            if pickingTask {
                TaskPicker(seed: desc.descriptionFirstLine, currentKey: model.issue(for: entry)?.key, preferProject: entry.projectId) { i, p in
                    model.setTask(i, projectId: p, for: [entry])
                    pickingTask = false
                } onCancel: { pickingTask = false }
            } else {
                Button { pickingTask = true } label: {
                    HStack {
                        TimeEdge(color: DS.project(model.project(entry.projectId)?.color ?? "slate")).frame(height: 16)
                        if let i = model.issue(for: entry) {
                            KeyName(key: i.key, name: i.summary, stacked: false)
                        } else {
                            Text(String(localized: "No task")).font(DS.F.body).foregroundStyle(DS.C.text3)
                        }
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.C.text3)
                    }
                    .padding(.horizontal, 10).frame(height: DS.H.field)
                    .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.field)
            }
            HStack(spacing: 8) {
                TimeField(label: String(localized: "Start"), date: $start, day: day, onCommit: { syncLength() }, commits: commits, onReturn: save)
                if entry.isRunning {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "END")).font(DS.F.sectionLabel).foregroundStyle(DS.C.text3)
                        Text(String(localized: "running")).font(DS.F.monoBig).foregroundStyle(DS.C.tickText).frame(height: DS.H.field)
                    }
                } else {
                    TimeField(label: String(localized: "End"), date: $end, day: day, onCommit: { syncLength() }, commits: commits, onReturn: save)
                    LengthField(label: String(localized: "Length"), seconds: $length, onCommit: { end = start.addingTimeInterval(TimeInterval(length)) },
                                commits: commits, onReturn: save)
                        .frame(width: 96)
                }
            }
            if let o = overlap {
                OverlapChoices(other: o.0, otherTitle: o.0.description.isEmpty ? model.taskLabel(for: o.0) : o.0.description,
                               overlap: o.1, thisEnd: end, choice: $overlapChoice)
            }
            HStack {
                Button(role: .destructive) {
                    model.delete([entry])
                    model.popoverEditing = nil
                } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                .buttonStyle(LinkButtonStyle(color: DS.C.dangerText)).font(DS.F.caption)
                Spacer()
                Button(String(localized: "Cancel")) { model.popoverEditing = nil }.buttonStyle(.pill)
                Button(String(localized: "Done"), action: save).buttonStyle(.primaryPill)
                    // ↩ on a highlighted earlier entry picks it; otherwise ↩ is Done.
                    .keyboardShortcut(suggestion == nil ? KeyboardShortcut(.return, modifiers: []) : nil)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.brand, lineWidth: 1.5))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            desc = entry.description
            start = entry.start
            end = entry.end ?? model.now
            length = Int(end.timeIntervalSince(start))
        }
    }

    private var overlap: (TimeEntry, Seconds)? {
        let e = entry.end == nil ? model.now : end
        for o in model.ledger.workEntries(on: day) where o.id != entry.id {
            let s = max(start, o.start), t = min(e, o.effectiveEnd(now: model.now))
            if t > s { return (o, Int(t.timeIntervalSince(s))) }
        }
        return nil
    }

    private func syncLength() {
        if end < start { end = start.addingTimeInterval(60) }
        length = Int(end.timeIntervalSince(start))
    }

    private func save() {
        // A time or length typed without ↩ counts; text that isn't one keeps the card open (the field is marked).
        guard commits.commitAll() else { return }
        var x = entry
        x.description = desc.trimmingCharacters(in: .newlines)
        x.start = start
        if !entry.isRunning { x.end = max(end, start.addingTimeInterval(60)) }
        var c = Changes()
        if let (o, _) = overlap {
            switch overlapChoice {
            case .keepBoth: break
            case .trimThis: x.end = o.start > x.start ? o.start : x.end
            case .moveOther:
                if let xe = x.end {
                    let ch = EntryOps.move(o, after: x, now: model.now)
                    c.upsertEntries += ch.updated
                    _ = xe
                }
            }
        }
        c.upsertEntries.insert(x, at: 0)
        model.perform("Edit entry", c)
        model.popoverEditing = nil
    }
}
