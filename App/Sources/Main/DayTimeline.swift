import SwiftUI
import TikjotDomain
import TikjotPersistence

/// Calendar-like day: blocks snap to 5 min and to neighbours (magnet), may overlap (side by side, named),
/// gaps are clickable with suggestions (§7.3, §11.11).
struct DayTimeline: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let day: LocalDate
    static let hourHeight: CGFloat = 72
    static let labelWidth: CGFloat = 56
    /// Block drags are measured here, so a block that grows or moves under the pointer doesn't feed back into the drag.
    static let space = "dayTimeline"

    var body: some View {
        let l = model.ledger
        let entries = l.entries(on: day)
        let locked = !model.lock.canEditEntries(on: day, today: model.today)
        let lanes = Self.lanes(entries, now: model.now)
        let layoutKey = Self.layoutKey(entries, lanes)
        let nowMinute = Int(model.now.timeIntervalSince1970 / 60)
        let slide: Animation? = reduceMotion ? nil : Motion.easeOut(0.3)
        let blockMotion = Motion.pick(reduceMotion, .spring(response: 0.2, dampingFraction: 0.82))
        let blockTransition: AnyTransition = .shrinkAway(reduceMotion)
        VStack(spacing: 0) {
            // All-day row: holiday and full/half-day absences (§7.3).
            AllDayRow(day: day)
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo in
                        let width = geo.size.width - Self.labelWidth - 24
                        ZStack(alignment: .topLeading) {
                            // Design Track (at3Se): hour lines start 8 pt left of the blocks and end flush with them.
                            HourGrid()
                                .padding(.trailing, geo.size.width - (Self.labelWidth + width - 4))
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedEntryIds = [] }
                            if !locked {
                                ForEach(gaps(entries), id: \.start) { g in
                                    GapView(gap: g, day: day)
                                        .frame(width: width - 4, height: max(18, h(g.end) - h(g.start) - 4))
                                        .offset(x: Self.labelWidth, y: h(g.start) + 2)
                                }
                            }
                            ForEach(model.absences(on: day).filter { $0.unit == .hours }) { a in
                                let s = day.at(minutes: a.startMinutes ?? model.schedule.period(on: day).workdayStart, in: .current)
                                let e = s.addingTimeInterval(TimeInterval(a.amountSeconds))
                                AbsenceBlock(absence: a)
                                    .frame(width: width - 4, height: max(22, h(e) - h(s) - 2))
                                    .offset(x: Self.labelWidth, y: h(s) + 1)
                            }
                            ForEach(entries) { e in
                                let lane = lanes[e.id] ?? (0, 1)
                                let laneW = width / CGFloat(lane.1)
                                EntryBlock(entry: e, day: day, locked: locked, width: laneW - 4)
                                    .frame(width: laneW - 4)
                                    .offset(x: Self.labelWidth + CGFloat(lane.0) * laneW, y: h(e.start) + 1)
                                    // Storyboard B · 6: a discarded (< 1 min) block shrinks away.
                                    .transition(blockTransition)
                            }
                            if day == model.today {
                                // Storyboard E · 2: moves 1.2 px each minute with a 300 ms slide (Reduce Motion: jumps).
                                NowLine().frame(width: width + 46).offset(x: Self.labelWidth - 50, y: h(model.now) - 6)
                                    .animation(slide, value: nowMinute)
                            }
                        }
                        .coordinateSpace(.named(Self.space))
                        // Storyboard F · 6: past a neighbour both blocks go side by side (200 ms spring); inserts/removals animate.
                        .animation(blockMotion, value: layoutKey)
                    }
                    .frame(height: Self.hourHeight * 24 + 8)
                    .padding(.trailing, 12)
                    .id(day) // another day replaces the timeline without animating every block
                }
                .onAppear {
                    let first = entries.first.map { Calendar.current.component(.hour, from: $0.start) } ?? 24
                    let start = min(first, model.schedule.period(on: day).workdayStart / 60)
                    proxy.scrollTo("h\(max(0, start - 1))", anchor: .top)
                }
                .onChange(of: day) { _, _ in
                    let start = model.schedule.period(on: day).workdayStart / 60
                    proxy.scrollTo("h\(max(0, start - 1))", anchor: .top)
                }
            }
        }
        .surfaceSheet(item: Binding(get: { model.splitRequest.flatMap { id in model.data.entries.first { $0.id == id } } }, set: { model.splitRequest = $0?.id })) { e in
            SplitSheet(entry: e).environment(model)
        }
    }

    /// Position on the 24-hour grid by the clock (on a daylight-saving day elapsed time since midnight is an hour off).
    private func h(_ d: Date) -> CGFloat {
        CGFloat(day.clockSeconds(d, in: .current) / 3600) * Self.hourHeight
    }

    private func gaps(_ entries: [TimeEntry]) -> [Gap] {
        let work = entries.filter { $0.kind == .work || $0.kind == .breakTime }
        guard let first = work.first else { return [] }
        let end = day == model.today ? max(model.now, work.map { $0.effectiveEnd(now: model.now) }.max()!) : work.map { $0.effectiveEnd(now: model.now) }.max()!
        let to = day == model.today ? EntryOps.snap(model.now, calendar: .current) : end
        // Timed absences (a doctor's visit) fill their span like entries, so the gap they cover stops asking.
        let away = model.absences(on: day).filter { $0.unit == .hours }.map { a in
            let s = day.at(minutes: a.startMinutes ?? model.schedule.period(on: day).workdayStart, in: .current)
            return TimeEntry(start: s, end: s.addingTimeInterval(TimeInterval(a.amountSeconds)), kind: .breakTime)
        }
        return EntryOps.gaps(work + away, from: first.start, to: to, now: model.now, minimum: 10 * 60)
    }

    /// Changes when a block is added / removed or changes lane (drives the side-by-side animation).
    static func layoutKey(_ entries: [TimeEntry], _ lanes: [UUID: (Int, Int)]) -> [String] {
        entries.map { e in
            let l = lanes[e.id] ?? (0, 1)
            return "\(e.id)/\(l.0)/\(l.1)"
        }
    }

    /// Lane layout for overlapping entries: (lane, lanes in its cluster).
    static func lanes(_ entries: [TimeEntry], now: Date) -> [UUID: (Int, Int)] {
        var out: [UUID: (Int, Int)] = [:]
        var cluster: [(TimeEntry, Int)] = []
        var clusterEnd = Date.distantPast
        var laneEnds: [Date] = []
        func flush() {
            let n = (cluster.map(\.1).max() ?? 0) + 1
            for (e, lane) in cluster { out[e.id] = (lane, n) }
            cluster = []
            laneEnds = []
        }
        for e in entries.sorted(by: { $0.start < $1.start }) {
            if e.start >= clusterEnd { flush() }
            let lane = laneEnds.firstIndex { $0 <= e.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(e.effectiveEnd(now: now)) } else { laneEnds[lane] = e.effectiveEnd(now: now) }
            cluster.append((e, lane))
            clusterEnd = max(clusterEnd, e.effectiveEnd(now: now))
        }
        flush()
        return out
    }
}

struct HourGrid: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%02d:00", hour)).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.C.text3)
                        .frame(width: DayTimeline.labelWidth - 16, alignment: .trailing)
                        .offset(y: -6)
                    Rectangle().fill(DS.C.border).frame(height: 1)
                }
                .frame(height: DayTimeline.hourHeight, alignment: .top)
                .id("h\(hour)")
            }
        }
        .padding(.top, 4)
    }
}

struct NowLine: View {
    var body: some View {
        HStack(spacing: 4) {
            Text(Fmt.time(Clock.now)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(DS.C.tickText)
                .frame(width: 40, alignment: .trailing).fixedSize()
            // Storyboard E · 2: coral 2 px line with a soft 8 px glow.
            Circle().fill(DS.C.tick).frame(width: 10, height: 10).shadow(color: DS.C.tick.opacity(0.55), radius: 4)
            Rectangle().fill(DS.C.tick).frame(height: 2)
                .shadow(color: DS.C.tick.opacity(0.45), radius: 4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AllDayRow: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    @State private var editing: [Absence]?

    var body: some View {
        let cal = model.dayCalendar
        let bands = model.absences(on: day).filter { $0.unit != .hours }
        if cal.holidays[day] != nil || !bands.isEmpty {
            VStack(spacing: 4) {
                if let h = cal.holidays[day] {
                    // Design holiday band (iwt7s): surface-2, no edge, title 12/600 + "nothing expected today".
                    HStack(spacing: 8) {
                        Image(systemName: "sun.max").font(.system(size: 12)).foregroundStyle(DS.C.text2)
                        Text(String(localized: "Public holiday · \(h.name)")).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.text).lineLimit(1)
                        Text(String(localized: "nothing expected today")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(DS.C.surface2))
                }
                ForEach(bands) { a in
                    let t = model.absenceType(a.typeId)
                    band(icon: t?.icon ?? "sun.horizon",
                         text: "\(t?.name ?? "") · \(a.unit == .halfDay ? String(localized: "half day") : String(localized: "whole day")) — " +
                               String(localized: "expected \(DurationFormat.short(cal.baseFund(day))) → \(DurationFormat.short(cal.fund(day)))"),
                         hatch: true)
                        .onTapGesture {
                            editing = a.rangeId.map { rid in model.data.absences.filter { $0.rangeId == rid } } ?? [a]
                        }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .surfaceSheet(item: Binding(get: { editing.map { AbsenceEdit(list: $0) } }, set: { editing = $0?.list })) { e in
                AbsenceForm(editing: e.list) { editing = nil }.padding(20).frame(width: 460).environment(model)
            }
        }
    }

    private func band(icon: String, text: String, hatch: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(DS.C.brandText)
            Text(text).font(DS.F.bodyMedium).foregroundStyle(DS.C.brandText)
            Spacer()
            Text(String(localized: "not sent to Jira")).font(DS.F.caption).foregroundStyle(DS.C.text2)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: DS.R.row).fill(DS.C.brandSoft))
        .overlay(hatch ? Hatch().clipShape(RoundedRectangle(cornerRadius: DS.R.row)) : nil)
        .overlay(alignment: .leading) { Capsule().fill(DS.C.brand).frame(width: 3).padding(.vertical, 4).padding(.leading, 4) }
    }
}

struct AbsenceEdit: Identifiable {
    let list: [Absence]
    var id: UUID { list.first?.id ?? UUID() }
}

struct AbsenceBlock: View {
    @Environment(AppModel.self) private var model
    let absence: Absence
    @State private var editing = false

    var body: some View {
        let t = model.absenceType(absence.typeId)
        let cal = model.dayCalendar
        HStack(spacing: 6) {
            Image(systemName: t?.icon ?? "stethoscope").foregroundStyle(DS.C.brandText)
            Text("\(t?.name ?? "") · " + String(localized: "absence \(DurationFormat.short(absence.amountSeconds)) — expected \(DurationFormat.short(cal.baseFund(absence.date))) → \(DurationFormat.short(cal.fund(absence.date)))"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.C.brandText).lineLimit(1)
            Text(String(localized: "not sent to Jira")).font(DS.F.caption).foregroundStyle(DS.C.text2)
            Spacer()
        }
        // Design absence block (GHlgD): content centred vertically.
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.R.row).fill(DS.C.brandSoft))
        .overlay(Hatch().clipShape(RoundedRectangle(cornerRadius: DS.R.row)))
        .overlay(alignment: .leading) { Capsule().fill(DS.C.brand).frame(width: 3).padding(.vertical, 5).padding(.leading, 5) }
        .onTapGesture { editing = true }
        .surfaceSheet(isPresented: $editing) {
            AbsenceForm(editing: [absence]) { editing = false }.padding(20).frame(width: 460).environment(model)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One timeline block. Body drag = move; top/bottom handles = resize; snap 5 min (⌥ = 1 min) + magnet.
struct EntryBlock: View {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    let day: LocalDate
    let locked: Bool
    let width: CGFloat
    @State private var dragMode: DragMode?
    @State private var dy: CGFloat = 0
    @State private var hover = false
    /// Storyboard F · 4: a 1-frame guide line flashes across when the edge sticks to a neighbour.
    @State private var guideFlash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum DragMode { case move, top, bottom }

    /// A resized edge stays on its time until the pointer has really moved (3 pt ≈ 2.5 min), then snaps.
    static let deadZone: CGFloat = 3
    /// Blocks shorter than this get their resize handles outside (above / below), so the two handles and the move area
    /// don't share a few points.
    static let shortHeight: CGFloat = 36
    /// One title line of a block (13 semibold + the stack's 2 pt spacing).
    static let titleLineHeight: CGFloat = 18
    /// Outside handle: hit area height / width (the visible capsule is smaller).
    static let outsideHit: CGFloat = 12
    static let outsideWidth: CGFloat = 44
    /// Inside handles reach this far past the block's edge.
    static let insideReach: CGFloat = 6

    private var hh: CGFloat { DayTimeline.hourHeight }

    var body: some View {
        let selected = model.selectedEntryIds.contains(entry.id)
        let end = entry.effectiveEnd(now: model.now)
        // True height (no minimum that would push into the next block): a 10-minute entry is 12 pt. An imported
        // worklog past midnight stays whole on its first day; its block stops at the grid's end.
        let baseHeight = max(4, CGFloat(min(end, day.end(in: .current)).timeIntervalSince(entry.start) / 3600) * hh - 1.5)
        let (previewStart, previewEnd) = preview()
        let height: CGFloat = dragMode == .move || dragMode == nil ? baseHeight : max(4, CGFloat(previewEnd.timeIntervalSince(previewStart) / 3600) * hh - 1.5)
        let yShift: CGFloat = dragMode == .move ? dy : (dragMode == .top ? CGFloat(previewStart.timeIntervalSince(entry.start) / 3600) * hh : 0)
        let isBreak = entry.kind == .breakTime
        let project = model.project(entry.projectId)
        let issue = model.issue(for: entry)
        let noTask = issue == nil && !isBreak
        let color = DS.project(project?.color ?? "slate")
        let fill: Color = isBreak ? DS.C.surface2.opacity(0.6) : (entry.isRunning ? DS.C.tickSoft : (noTask ? DS.C.surface2 : DS.projectTint(project?.color ?? "slate")))
        let canResize = !locked && !isBreak
        // On the committed height, so the handles don't change place in the middle of a drag.
        let outside = baseHeight < Self.shortHeight
        // A short block shows its (outside) handles only once selected: a selected block sits above its neighbours,
        // so its handles win where they reach into the next block; hover-only handles would hide under it.
        let showTop = canResize && (selected || dragMode == .top)
        let showBottom = canResize && !entry.isRunning && (selected || (hover && !outside) || dragMode == .bottom)
        // Short entries: ≥ 36 pt full block · 15–36 pt one compact line "Title · 10m" · < 15 pt a slim bar (details on hover / in the inspector).
        let tier = height >= 36 ? 2 : (height >= 15 ? 1 : 0)
        let fullTitle = isBreak ? (entry.description.isEmpty ? String(localized: "Break") : entry.description)
            : (entry.description.isEmpty ? (issue?.summary ?? String(localized: "No description")) : entry.description)
        // A multi-line description (owner 2026-10-22): its lines are the title, one under another, as many as the
        // block's height leaves after time and task; the last one shown ends with "+N" for the rest.
        let lines = isBreak ? [fullTitle.descriptionFirstLine] : (DescriptionLines.lines(fullTitle).isEmpty ? [fullTitle] : DescriptionLines.lines(fullTitle))
        let title = lines[0]
        let reserved: CGFloat = 7 + (height >= 36 ? 15 : 0) + (height >= 58 && !isBreak ? 18 : 0)
        let shown = tier == 2 ? min(lines.count, max(1, Int((height - reserved) / Self.titleLineHeight))) : 1
        let lengthText = DurationFormat.short(Int(end.timeIntervalSince(entry.start)))

        ZStack(alignment: .topLeading) {
            // Storyboard B · 3: on stop the block cross-fades coral → project tint (100 → 350 ms).
            RoundedRectangle(cornerRadius: DS.R.row).fill(fill)
                .animation(Motion.pick(reduceMotion, Motion.easeOut(0.25)), value: entry.isRunning)
            if !isBreak {
                Capsule().fill(entry.isRunning ? DS.C.tick : color).frame(width: 3).padding(.vertical, tier == 2 ? 5 : (tier == 1 ? 3 : 1)).padding(.leading, 5)
                    .animation(Motion.pick(reduceMotion, Motion.easeOut(0.25)), value: entry.isRunning)
            }
            if tier == 1 {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(isBreak ? DS.C.text3 : DS.C.text).lineLimit(1)
                    if lines.count > 1 { MoreLinesChip(count: lines.count - 1) }
                    Text("· " + lengthText).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.C.text2).lineLimit(1).fixedSize()
                }
                .padding(.leading, 16).padding(.trailing, 26)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            if tier == 2 { VStack(alignment: .leading, spacing: 2) {
                if isBreak {
                    Text(title + " · " + String(localized: "doesn't count")).font(DS.F.caption).foregroundStyle(DS.C.text3).lineLimit(1)
                } else {
                    ForEach(0..<shown, id: \.self) { i in
                        HStack(spacing: 5) {
                            Text(lines[i]).font(DS.F.bodySemibold).foregroundStyle(DS.C.text).lineLimit(1)
                            if i == shown - 1 && shown < lines.count { MoreLinesChip(count: lines.count - shown) }
                        }
                    }
                }
                if height >= 36 {
                    // Storyboard B: "now · 0:42" cross-fades to "16:42 · 42m"; F · 5: the duration rolls on release.
                    let line = timeLine(previewStart, dragMode == nil ? (entry.end == nil ? nil : end) : previewEnd)
                    Text(line)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(entry.isRunning ? DS.C.tickText : DS.C.text2).lineLimit(1)
                        .rolls(line)
                }
                if height >= 58 && !isBreak {
                    if let issue {
                        TaskTag(key: issue.key, name: issue.summary, color: project?.color ?? "slate")
                    } else {
                        Text(String(localized: "No task · \(project?.name ?? "") — Pick task before sending")).font(DS.F.caption).foregroundStyle(DS.C.text2).lineLimit(1)
                    }
                }
                if height >= 76, let o = overlapText { Text(o).font(DS.F.caption).foregroundStyle(DS.C.warningText).lineLimit(1) }
            }
            .padding(.leading, 16).padding(.trailing, 26).padding(.top, 5) }
            if tier >= 1 {
                // One 16 pt slot at the same inset in every block, so the icons share a centre line down the column;
                // a one-line block centres it vertically, a touch smaller.
                stateIcon(noTask: noTask, isBreak: isBreak)
                    .scaleEffect(tier == 1 ? 0.85 : 1)
                    .frame(width: 16, height: 16)
                    .frame(maxWidth: .infinity, maxHeight: tier == 1 ? .infinity : nil, alignment: tier == 1 ? .trailing : .topTrailing)
                    .padding(.trailing, 8).padding(.top, tier == 1 ? 0 : 8)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.row))
        .overlay(RoundedRectangle(cornerRadius: DS.R.row).strokeBorder(selected ? DS.C.brand : .clear, lineWidth: 2))
        .help(tier < 2 ? "\(lines.joined(separator: "\n")) · \(timeLine(entry.start, entry.end))" : (shown < lines.count ? lines.joined(separator: "\n") : ""))
        // A slim bar shows its name on hover, floating just above it.
        .overlay(alignment: .topLeading) {
            if tier == 0 && hover && dragMode == nil {
                Text("\(title) · \(lengthText)").font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .capsuleSurface(DS.C.surface, border: DS.C.border)
                    .compositingGroup().shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                    .offset(x: 14, y: -22).allowsHitTesting(false).transition(.opacity)
            }
        }
        .zIndex(hover || selected ? 5 : 0)
        // Beta 2026-10-08: no spring on the height while resizing — the edge follows the snapped time exactly.
        .overlay(alignment: .top) {
            if showTop {
                handle(outside: outside)
                    .alignmentGuide(.top) { d in outside ? d[.bottom] : d[.top] }
                    .gesture(resize(.top))
            }
        }
        .overlay(alignment: .bottom) {
            // Storyboard F · 1: hovering the block fades the bottom handle in (120 ms).
            if showBottom {
                handle(outside: outside)
                    .alignmentGuide(.bottom) { d in outside ? d[.top] : d[.bottom] }
                    .gesture(resize(.bottom)).transition(.opacity)
            }
        }
        .overlay(alignment: dragMode == .top ? .top : .bottom) {
            // Storyboard F · 2–3: a time tag at the dragged edge ("10:30 → 10:45"), updating live; faint 5-min ticks as snap guides.
            ZStack {
                if dragMode == .top || dragMode == .bottom {
                    edgeTag(dragMode == .top ? previewStart : previewEnd, from: dragMode == .top ? entry.start : end, top: dragMode == .top)
                        .transition(reduceMotion ? .opacity : .offset(y: -4).combined(with: .opacity))
                }
            }
            .animation(Motion.pick(reduceMotion, .spring(response: 0.18, dampingFraction: 0.8)), value: dragMode)
        }
        .overlay(alignment: dragMode == .top ? .top : .bottom) {
            if guideFlash {
                Rectangle().fill(DS.C.brand).frame(height: 1).padding(.horizontal, -8).allowsHitTesting(false)
            }
        }
        .offset(y: yShift)
        // Storyboard F · 2 / 5: grab lifts the block (6 px shadow, 1.01); release settles it back. Scoped to the lift,
        // so grabbing / releasing doesn't animate the height or offset (that bounced the edge on release).
        .animation(Motion.pick(reduceMotion, .spring(response: 0.18, dampingFraction: 0.8))) { content in
            content
                .scaleEffect(dragMode != nil && !reduceMotion ? 1.01 : 1)
                .shadow(color: dragMode != nil ? .black.opacity(0.16) : .clear, radius: 6, y: 3)
        }
        .animation(Motion.easeOut(0.12), value: hover)
        .onChange(of: dragMode == nil ? nil : (dragMode == .top || dragMode == .move ? previewStart : previewEnd)) { old, new in
            guard let new, let old, new != old else { return }
            snapFeedback(new)
        }
        .zIndex(dragMode != nil || selected ? 2 : 1)
        // The block plus its visible handles' reach past the edges (outside handles of a short block live there).
        .contentShape(HandleHitShape(top: showTop ? (outside ? Self.outsideHit : Self.insideReach) : 0,
                                     bottom: showBottom ? (outside ? Self.outsideHit : Self.insideReach) : 0,
                                     width: Self.outsideWidth))
        .onHover { hover = $0 }
        .gesture(locked || isBreak ? nil : moveGesture)
        .simultaneousGesture(TapGesture().onEnded { select() })
        .contextMenu { contextMenu }
        .help(locked ? String(localized: "This day is locked — read-only") : "")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibility(issue: issue, noTask: noTask, isBreak: isBreak))
        .accessibilityAction { model.selectedEntryIds = [entry.id] }
        .modifier(BlockActions(entry: entry, locked: locked, isBreak: isBreak, nudge: nudge))
        .accessibilityIdentifier("day.entry")
    }

    /// Inside: a 24 pt capsule with a hit area reaching 6 pt past it. Outside (short block): a 12 × 44 pt hit area
    /// just beyond the edge, drawn as a small capsule on a soft pill.
    private func handle(outside: Bool) -> some View {
        Group {
            if outside {
                Capsule().fill(DS.C.brand).frame(width: 18, height: 3)
                    .frame(width: 30, height: 8)
                    .background(Capsule().fill(DS.C.brandSoft))
                    .frame(width: Self.outsideWidth, height: Self.outsideHit)
                    .contentShape(Rectangle())
            } else {
                Capsule().fill(DS.C.brand).frame(width: 24, height: 3).padding(4).contentShape(Rectangle().inset(by: -Self.insideReach))
            }
        }
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
    }

    /// The live time tag at the dragged edge ("10:30 → 10:45" once it moved), with faint ticks every 5 min (snap guides).
    private func edgeTag(_ d: Date, from original: Date, top: Bool) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Canvas { ctx, size in
                let step = DayTimeline.hourHeight / 12
                var p = Path()
                var y = size.height / 2 - step * 3
                while y <= size.height / 2 + step * 3 + 0.5 {
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                ctx.stroke(p, with: .color(DS.C.brand.opacity(0.35)), lineWidth: 1)
            }
            .frame(width: 8, height: DayTimeline.hourHeight / 2)
            Text(d == original ? Fmt.time(d) : "\(Fmt.time(original)) → \(Fmt.time(d))").font(DS.F.monoMedium).foregroundStyle(DS.C.onBrand)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(DS.C.brand))
        }
        .padding(.trailing, 6)
        .offset(y: top ? -12 : 12)
        .allowsHitTesting(false)
    }

    /// Snap feedback: a light haptic + a guide flash when the edge sticks to a neighbour's edge (magnet).
    private func snapFeedback(_ d: Date) {
        guard !NSEvent.modifierFlags.contains(.option), edges().contains(d) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        guard !reduceMotion else { return }
        guideFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { guideFlash = false }
    }

    private func timeLine(_ s: Date, _ e: Date?) -> String {
        let len = Int((e ?? model.now).timeIntervalSince(s))
        if entry.isRunning { return "\(Fmt.time(s))–\(String(localized: "now")) · \(DurationFormat.clock(len))" }
        return "\(Fmt.range(s, e)) · \(DurationFormat.short(len))"
    }

    private var overlapText: String? {
        let o = EntryOps.overlaps(model.ledger.workEntries(on: day), now: model.now).filter { $0.a == entry.id || $0.b == entry.id }
        let s = o.reduce(0) { $0 + $1.seconds }
        return s > 0 ? String(localized: "overlaps \(DurationFormat.short(s)) · counts twice") : nil
    }

    @ViewBuilder
    private func stateIcon(noTask: Bool, isBreak: Bool) -> some View {
        if isBreak { EmptyView() }
        else if locked { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(DS.C.text3) }
        else if entry.isRunning {
            Button { model.stop() } label: { Image(systemName: "stop.circle").font(.system(size: 13)).foregroundStyle(DS.C.tickText) }.buttonStyle(.icon)
        } else if noTask {
            NoTaskMark(size: 14).help(String(localized: "No task"))
        } else if let line = model.ledger.lines(on: day).first(where: { $0.entries.contains { $0.id == entry.id } }) {
            switch model.ledger.state(of: line, lock: model.lock) {
            case .synced:
                Image(systemName: "checkmark.circle").font(.system(size: 14)).foregroundStyle(DS.C.success)
                    .help(entry.source == .imported ? String(localized: "From Jira") : String(localized: "In Jira"))
            case .modified: Image(systemName: "circle.dotted").font(.system(size: 14)).foregroundStyle(DS.C.warning).help(String(localized: "Changed since sending"))
            case .unsent: Image(systemName: "circle.dashed").font(.system(size: 14)).foregroundStyle(DS.C.text3).help(String(localized: "Not in Jira yet"))
            case .error: Image(systemName: "exclamationmark.circle").font(.system(size: 14)).foregroundStyle(DS.C.danger).help(String(localized: "Failed"))
            case .conflict: Image(systemName: "arrow.left.arrow.right.circle").font(.system(size: 14)).foregroundStyle(DS.C.danger).help(String(localized: "Changed in Jira and here"))
            case .remoteDeleted: Image(systemName: "trash.circle").font(.system(size: 14)).foregroundStyle(DS.C.warning).help(String(localized: "Deleted in Jira"))
            default: EmptyView()
            }
        }
    }

    /// VoiceOver reads a block as its title, time and length, task, then what colour and icons say (§14).
    private func accessibility(issue: Issue?, noTask: Bool, isBreak: Bool) -> String {
        let end = entry.effectiveEnd(now: model.now)
        var parts = [isBreak ? (entry.description.isEmpty ? String(localized: "Break") : entry.description)
                     : (entry.description.isEmpty ? (issue?.summary ?? String(localized: "No description")) : entry.description)]
        parts.append(entry.isRunning ? String(localized: "running since \(Fmt.time(entry.start))") : Fmt.range(entry.start, entry.end))
        parts.append(DurationFormat.short(Int(end.timeIntervalSince(entry.start))))
        if isBreak { parts.append(String(localized: "doesn't count")) }
        else if let issue { parts.append("\(issue.key) \(issue.summary)") }
        else { parts.append(String(localized: "no task")) }
        if !isBreak, !noTask, let state = stateText { parts.append(state) }
        if let o = overlapText { parts.append(o) }
        if locked { parts.append(String(localized: "locked")) }
        return parts.joined(separator: ", ")
    }

    /// The words for the state icon (stateIcon), so colour and icon aren't the only carriers.
    private var stateText: String? {
        guard !entry.isRunning, let line = model.ledger.lines(on: day).first(where: { $0.entries.contains { $0.id == entry.id } }) else { return nil }
        switch model.ledger.state(of: line, lock: model.lock) {
        case .synced: return entry.source == .imported ? String(localized: "From Jira") : String(localized: "In Jira")
        case .modified: return String(localized: "Changed since sending")
        case .unsent: return String(localized: "Not in Jira yet")
        case .error: return String(localized: "Failed")
        case .conflict: return String(localized: "Changed in Jira and here")
        case .remoteDeleted: return String(localized: "Deleted in Jira")
        default: return nil
        }
    }

    /// VoiceOver's move / resize: shifts the start and / or end by `minutes`, clamped like a drag.
    private func nudge(start: Int, end: Int) {
        let e = entry.effectiveEnd(now: model.now)
        let mode: DragMode = start == end ? .move : (start != 0 ? .top : .bottom)
        let ns = entry.start.addingTimeInterval(TimeInterval(start * 60))
        let ne = e.addingTimeInterval(TimeInterval(end * 60))
        guard ne.timeIntervalSince(ns) >= 60 else { return }
        apply(ns, ne, mode: mode)
    }

    // MARK: Selection

    private func select() {
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if model.selectedEntryIds.contains(entry.id) { model.selectedEntryIds.remove(entry.id) } else { model.selectedEntryIds.insert(entry.id) }
        } else {
            model.selectedEntryIds = [entry.id]
        }
    }

    // MARK: Drag

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DayTimeline.space))
            .onChanged { v in
                if dragMode == nil { dragMode = .move; model.selectedEntryIds = [entry.id] }
                dy = v.translation.height
            }
            .onEnded { _ in commit() }
    }

    private func resize(_ mode: DragMode) -> some Gesture {
        // Measured on the timeline, not in the handle that moves with the edge (that fed back and made the edge jump).
        DragGesture(minimumDistance: 1, coordinateSpace: .named(DayTimeline.space))
            .onChanged { v in dragMode = mode; dy = v.translation.height }
            .onEnded { _ in commit() }
    }

    private func edges() -> [Date] {
        model.ledger.workEntries(on: day).filter { $0.id != entry.id }.flatMap { [$0.start, $0.effectiveEnd(now: model.now)] }
    }

    private func snapped(_ d: Date) -> Date {
        let fine = NSEvent.modifierFlags.contains(.option)
        if fine { return EntryOps.snap(d, minutes: 1, calendar: .current) }
        return EntryOps.snap(d, toEdges: edges(), calendar: .current)
    }

    /// A resized edge: stays put inside the dead zone, then 5 min (⌥ = 1 min) with a 2-min magnet.
    private func resized(_ edge: Date, by delta: TimeInterval) -> Date {
        EntryOps.dragEdge(edge, by: delta, deadZone: TimeInterval(Self.deadZone / DayTimeline.hourHeight * 3600),
                          fine: NSEvent.modifierFlags.contains(.option), edges: edges(), calendar: .current)
    }

    private func preview() -> (Date, Date) {
        let end = entry.effectiveEnd(now: model.now)
        let delta = TimeInterval(dy / DayTimeline.hourHeight * 3600)
        switch dragMode {
        case .move:
            let s = snapped(entry.start.addingTimeInterval(delta))
            return (s, s.addingTimeInterval(end.timeIntervalSince(entry.start)))
        case .top:
            return (min(resized(entry.start, by: delta), end.addingTimeInterval(-60)), end)
        case .bottom:
            return (entry.start, max(resized(end, by: delta), entry.start.addingTimeInterval(60)))
        case nil:
            return (entry.start, end)
        }
    }

    private func commit() {
        let (s, e) = preview()
        let mode = dragMode
        dragMode = nil
        dy = 0
        apply(s, e, mode: mode)
    }

    private func apply(_ s: Date, _ e: Date, mode: DragMode?) {
        guard var x = model.data.entries.first(where: { $0.id == entry.id }) else { return }
        // Clamp to the day and never into the future.
        let dayStart = day.start(in: .current), dayEnd = min(day.end(in: .current), max(model.now, x.start))
        var ns = max(dayStart, s)
        var ne = e
        if mode == .move { let len = e.timeIntervalSince(s); ns = max(dayStart, min(ns, dayEnd.addingTimeInterval(-len))); ne = ns.addingTimeInterval(len) }
        ne = min(ne, max(dayEnd, ns.addingTimeInterval(60)))
        if ns == x.start && (x.end == nil || ne == x.end) { return }
        x.start = ns
        if x.end != nil { x.end = ne }
        model.update(x, name: mode == .move ? "Move entry" : "Resize entry")
    }

    // MARK: Context menu (§7.3)

    // Native menu, grouped like the design (zv5xc): icons, separators and the shortcuts the Day already knows —
    // shown only (KeyCommands handles them), so they don't fire twice.
    @ViewBuilder
    private var contextMenu: some View {
        Button { model.continueEntry(entry) } label: { Label(String(localized: "Continue"), systemImage: "play") }
        if !locked && entry.end != nil {
            Divider()
            Button { model.splitRequest = entry.id } label: { Label(String(localized: "Split…"), systemImage: "scissors") }
                .keyboardShortcut("s", modifiers: [])
            Button { model.selectedEntryIds = [entry.id]; model.mergeSelectionWithPrevious() } label: {
                Label(String(localized: "Merge"), systemImage: "arrow.triangle.merge")
            }
            .keyboardShortcut("m", modifiers: [])
        }
        Divider()
        if !locked && entry.end != nil {
            Button { model.selectedEntryIds = [entry.id]; model.inspectorPickTask = true } label: {
                Label(String(localized: "Change task…"), systemImage: "tag")
            }
        }
        // Also on locked days: reading the ticket changes nothing. No ⌘-click here — that already selects several blocks.
        if let key = model.issue(for: entry)?.key, model.jiraURL(entry.issueRef) != nil {
            Button { model.openInJira(entry.issueRef) } label: { Label(String(localized: "Open \(key) in Jira"), systemImage: "arrow.up.forward.square") }
        }
        Button { model.copyDescription(entry) } label: { Label(String(localized: "Copy description"), systemImage: "doc.on.doc") }
            .keyboardShortcut("c", modifiers: .command)
        if !locked {
            Divider()
            Button(role: .destructive) { model.delete([entry]) } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: [])
        }
    }
}

/// A block's VoiceOver actions (§14): what a drag, the handles and the context menu do, in 5-minute steps.
private struct BlockActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let entry: TimeEntry
    let locked: Bool
    let isBreak: Bool
    let nudge: (_ start: Int, _ end: Int) -> Void

    func body(content: Content) -> some View {
        let editable = !locked && !isBreak
        let ended = entry.end != nil
        content
            .accessibilityActions {
                if ended { Button(String(localized: "Continue")) { model.continueEntry(entry) } }
                if editable {
                    Button(String(localized: "Move 5 minutes earlier")) { nudge(-5, -5) }
                    if ended { Button(String(localized: "Move 5 minutes later")) { nudge(5, 5) } }
                    Button(String(localized: "Start 5 minutes earlier")) { nudge(-5, 0) }
                    Button(String(localized: "Start 5 minutes later")) { nudge(5, 0) }
                    if ended {
                        Button(String(localized: "End 5 minutes earlier")) { nudge(0, -5) }
                        Button(String(localized: "End 5 minutes later")) { nudge(0, 5) }
                    }
                }
                if !locked && ended {
                    Button(String(localized: "Split…")) { model.selectedEntryIds = [entry.id]; model.splitRequest = entry.id }
                    Button(String(localized: "Change task…")) { model.selectedEntryIds = [entry.id]; model.inspectorPickTask = true }
                }
                if let key = model.issue(for: entry)?.key, model.jiraURL(entry.issueRef) != nil {
                    Button(String(localized: "Open \(key) in Jira")) { model.openInJira(entry.issueRef) }
                }
                if !locked { Button(String(localized: "Delete")) { model.delete([entry]) } }
            }
    }
}

/// Free time between entries: thin grey outline, click → suggestions (§11.11).
struct GapView: View {
    @Environment(AppModel.self) private var model
    let gap: Gap
    let day: LocalDate
    @State private var hover = false
    @State private var open = false

    var body: some View {
        RoundedRectangle(cornerRadius: DS.R.row)
            // Design `timeline/gap` (SGX6F): solid 1 pt border-strong, radius 8, plus icon + label in text-tertiary.
            .strokeBorder(hover || open ? DS.C.brand : DS.C.borderStrong, lineWidth: 1)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(hover ? DS.C.surface.opacity(0.6) : .clear))
            .overlay {
                if hover || open || gap.seconds >= 20 * 60 {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text(String(localized: "\(DurationFormat.short(gap.seconds)) free · \(Fmt.range(gap.start, gap.end)) · click to fill"))
                    }
                    .font(DS.F.caption).foregroundStyle(DS.C.text3)
                }
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { open = true }
            .onAppear { if gap.seconds >= 20 * 60 { DebugUI.open("gap") { open = true } } }
            .surfacePopover(isPresented: $open, arrowEdge: .trailing) {
                GapSuggestions(gap: gap, day: day) { open = false }.environment(model).padding(.vertical, 10).padding(.horizontal, 6).frame(width: 380)
            }
            .accessibilityLabel(String(localized: "Free time \(Fmt.range(gap.start, gap.end))"))
            .accessibilityAddTraits(.isButton)
    }
}

struct GapSuggestions: View {
    @Environment(AppModel.self) private var model
    let gap: Gap
    let day: LocalDate
    let close: () -> Void

    var body: some View {
        let es = model.ledger.workEntries(on: day)
        let prev = es.last { $0.effectiveEnd(now: model.now) <= gap.start.addingTimeInterval(1) }
        let next = es.first { $0.start >= gap.end.addingTimeInterval(-1) }
        let lunchish = gap.seconds >= 20 * 60 && Calendar.current.component(.hour, from: gap.start) >= 11 && Calendar.current.component(.hour, from: gap.start) <= 14
        let delta = "+" + DurationFormat.short(gap.seconds)
        let opts = options(prev: prev, next: next, lunchish: lunchish, delta: delta)
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "\(DurationFormat.short(gap.seconds)) free · \(Fmt.range(gap.start, gap.end))"))
                .font(.system(size: 13, weight: .bold)).foregroundStyle(DS.C.text)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
            ForEach(Array(opts.enumerated()), id: \.element.id) { i, o in
                if o.id == .new { Divider().padding(.vertical, 3) }
                optionRow(o, highlighted: i == highlighted).onHover { if $0 { highlighted = i } }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { DispatchQueue.main.async { focused = true } }
        // Design VcnxM: B break · D doctor · ↑ extend the entry before · ↓ start the one after · N new entry · ↩ the highlighted one.
        .onKeyPress { press in
            let key: Option.Kind? = switch press.key {
            case .upArrow: .extend
            case .downArrow: .startEarlier
            case .return: opts.indices.contains(highlighted) ? opts[highlighted].id : nil
            default: switch press.characters.lowercased() { case "b": .breakTime; case "d": .doctor; case "n": .new; default: nil }
            }
            guard let key, let o = opts.first(where: { $0.id == key }) else { return .ignored }
            o.action(); close()
            return .handled
        }
    }

    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Option {
        enum Kind { case breakTime, doctor, extend, startEarlier, new }
        let id: Kind
        let icon: String
        let title: String
        let sub: AnyView
        let key: String
        let action: () -> Void
    }

    private func options(prev: TimeEntry?, next: TimeEntry?, lunchish: Bool, delta: String) -> [Option] {
        let breakOption = Option(id: .breakTime, icon: "cup.and.saucer", title: String(localized: "Mark as a break"),
                                 sub: AnyView(subText(lunchish ? String(localized: "Lunch · doesn't count, the gap stops asking")
                                                               : String(localized: "Doesn't count, the gap stops asking"))),
                                 key: "B") { model.markBreak(from: gap.start, to: gap.end) }
        // Beta feedback 2026-10-08 (row 9, D2): a doctor's visit covering exactly the gap — an hours absence, undoable like the rest.
        let doctor = model.absenceType(AbsenceType.doctor.id) ?? .doctor
        let doctorOption = Option(id: .doctor, icon: doctor.icon, title: AppModel.builtinName(.doctor),
                                  sub: AnyView(subText(String(localized: "Absence · lowers expected hours by \(DurationFormat.short(gap.seconds))"))),
                                  key: "D") {
            let c = Calendar.current.dateComponents([.hour, .minute], from: gap.start)
            model.addAbsence(type: doctor, days: [day], unit: .hours, seconds: gap.seconds,
                             startMinutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
        }
        var out: [Option] = []
        if lunchish { out += [breakOption, doctorOption] }
        if let prev, prev.end != nil {
            out.append(Option(id: .extend, icon: "arrow.down.to.line", title: String(localized: "Extend “\(title(prev))” to \(Fmt.time(gap.end))"),
                              sub: AnyView(taskLine(prev, delta)), key: "↑") {
                var x = prev; x.end = gap.end; model.update(x, name: "Extend entry")
            })
        }
        if let next {
            out.append(Option(id: .startEarlier, icon: "arrow.up.to.line", title: String(localized: "Start “\(title(next))” at \(Fmt.time(gap.start))"),
                              sub: AnyView(taskLine(next, delta)), key: "↓") {
                var x = next; x.start = gap.start; model.update(x, name: "Start entry earlier")
            })
        }
        out.append(Option(id: .new, icon: "plus", title: String(localized: "New entry here…"),
                          sub: AnyView(subText(String(localized: "Pick a task and description"))), key: "N") {
            model.addEntry(on: day, from: gap.start, to: gap.end)
        })
        if !lunchish { out += [breakOption, doctorOption] }
        return out
    }

    private func title(_ e: TimeEntry) -> String { e.description.isEmpty ? model.taskLabel(for: e) : e.description }

    private func subText(_ s: String) -> some View { Text(s).font(DS.F.caption).foregroundStyle(DS.C.text3).lineLimit(1) }

    /// "● ABC-981 Payment gateway retry · +57m" — or "No task · Payments · +57m".
    @ViewBuilder
    private func taskLine(_ e: TimeEntry, _ delta: String) -> some View {
        let project = model.project(e.projectId)
        if let issue = model.issue(for: e) {
            HStack(spacing: 4) {
                Circle().fill(DS.project(project?.color ?? "slate")).frame(width: 6, height: 6)
                Text("\(issue.key) \(issue.summary)").lineLimit(1).truncationMode(.tail)
                Text("· \(delta)").fixedSize()
            }
            .font(DS.F.caption).foregroundStyle(DS.C.text3)
        } else {
            subText(([String(localized: "No task")] + (project.map { [$0.name] } ?? []) + [delta]).joined(separator: " · "))
        }
    }

    private func optionRow(_ o: Option, highlighted: Bool) -> some View {
        Button { o.action(); close() } label: {
            HStack(spacing: 10) {
                Image(systemName: o.icon).font(.system(size: 13)).frame(width: 15).foregroundStyle(highlighted ? DS.C.brand : DS.C.text2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.text).lineLimit(1)
                    o.sub
                }
                Spacer(minLength: 4)
                Text(o.key).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(highlighted ? DS.C.brandText : DS.C.text3)
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(highlighted ? DS.C.brandSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
    }
}

// MARK: Split ("Take out…" was cut in the simplicity pass 2026-10-06 — Split covers it)

struct SplitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: TimeEntry
    @State private var at = Clock.now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Split “\(entry.description.descriptionFirstLine)”")).font(DS.F.title)
            TimeField(label: String(localized: "Split at"), date: $at, day: LocalDate(entry.start, calendar: .current))
            if let end = entry.end, at > entry.start, at < end {
                Text(String(localized: "\(Fmt.range(entry.start, at)) · \(DurationFormat.short(Int(at.timeIntervalSince(entry.start)))) and \(Fmt.range(at, end)) · \(DurationFormat.short(Int(end.timeIntervalSince(at))))"))
                    .font(DS.F.caption).foregroundStyle(DS.C.text2)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button(String(localized: "Split")) {
                    if let ch = try? EntryOps.split(entry, at: at) {
                        model.apply(ch, name: "Split", toast: String(localized: "Split at \(Fmt.time(at))"))
                        model.selectedEntryIds = Set(ch.inserted.map(\.id))
                    }
                    dismiss()
                }
                .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                .disabled(!(entry.end.map { at > entry.start && at < $0 } ?? false))
            }
        }
        .padding(20).frame(width: 380)
        .onAppear {
            let mid = entry.start.addingTimeInterval((entry.effectiveEnd(now: model.now).timeIntervalSince(entry.start)) / 2)
            at = EntryOps.snap(mid, calendar: .current)
        }
    }
}

/// A block's hit area grown past its top / bottom edge by a centred strip `width` wide (where its handles reach).
struct HandleHitShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var width: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path(r)
        let w = min(width, r.width)
        if top > 0 { p.addRect(CGRect(x: r.midX - w / 2, y: r.minY - top, width: w, height: top)) }
        if bottom > 0 { p.addRect(CGRect(x: r.midX - w / 2, y: r.maxY, width: w, height: bottom)) }
        return p
    }
}
