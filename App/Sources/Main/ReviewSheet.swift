import SwiftUI
import JiraKit
import SyncEngine
import TikjotDomain
import TikjotPersistence

/// Review & send (§9.8, design 2026-10-02): "Send <day> to Jira" · Needs you (only blockers) ·
/// Goes to Jira (task × day, rounded, comment + Edit, one quiet note) · "Also:" · one button. Results stay in the sheet.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ReviewRequest

    enum Phase: Equatable { case review, sending, done }
    @State private var phase: Phase = .review
    @State private var retry: Set<UUID> = []
    @State private var progress: [UUID: SendOutcome.Result?] = [:]
    @State private var frozen: [ReviewPlan.Item] = []
    @State private var report: SendReport?
    @State private var editingComment: UUID?
    @State private var hoveredRow: UUID?
    @State private var commentText = ""
    @State private var showAlso = false
    @State private var pickingFor: TimeEntry?
    @State private var includeAlso: [LocalDate] = []
    /// Requests in flight (storyboard C: only the active row spins).
    @State private var active: Set<UUID> = []
    /// Paper plane 0 → 1 along its path; then the list fades & collapses upwards.
    @State private var planeProgress: CGFloat = 0
    @State private var listGone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var plan: ReviewPlan {
        var scope = request.scope
        if case .days(let ds) = scope, !includeAlso.isEmpty { scope = .days(ds + includeAlso) }
        return model.plan(scope, retry: retry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .review: reviewBody.transition(.opacity)
            case .sending: sendingBody.transition(.opacity)
            case .done: resultBody.transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(width: 560)
        .frame(minHeight: 300, maxHeight: 680)
        .background(DS.C.bg)
        .task {
            // Debug aid (demo only): `-autoSend` presses Send to check the send motion (storyboard C) with -captureSeries.
            guard model.demo, LaunchFlags.args.contains("-autoSend") else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if phase == .review, !plan.items.isEmpty { send(plan) }
        }
    }

    // MARK: Review

    private var reviewBody: some View {
        let p = plan
        let instanceName = model.activeInstances.first?.name ?? "Jira"
        let tasks = Set(p.items.filter { $0.action != .delete }.map(\.issue)).count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title).font(DS.F.screenTitle).accessibilityIdentifier("review.title")
                Text(String(localized: "\(tasks) tasks ready") + " · \(DurationFormat.hm(p.total))" + (needsYouText(p).map { " · " + $0 } ?? "") + " · \(instanceName)")
                    .font(DS.F.caption).foregroundStyle(DS.C.text2)
            }
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !p.needsYou.isEmpty { needsYouCard(p) }
                    if p.runningExcluded {
                        Well { Label(String(localized: "The running entry is left out until you stop it."), systemImage: "timer").font(DS.F.caption) }
                    }
                    if !p.items.filter({ $0.action != .delete }).isEmpty {
                        SectionLabel(String(localized: "Goes to Jira"))
                        VStack(spacing: 0) {
                            let groups = Dictionary(grouping: p.items.filter { $0.action != .delete }, by: \.date)
                            ForEach(groups.keys.sorted(), id: \.self) { d in
                                if groups.count > 1 {
                                    Text(Fmt.short(d)).font(DS.F.captionMedium).foregroundStyle(DS.C.text3)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 8)
                                }
                                ForEach(groups[d]!) { item in itemRow(item) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                        .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
                    } else if p.needsYou.isEmpty {
                        Text(String(localized: "Nothing new to send — everything here is already in Jira.")).foregroundStyle(DS.C.text2)
                    }
                    alsoLine(p)
                }
                .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button(String(localized: "Not now")) { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button { send(p) } label: {
                    Label(p.total > 0 || !p.items.isEmpty ? String(localized: "Send \(DurationFormat.hm(p.total)) to Jira") : String(localized: "Send to Jira"), systemImage: "paperplane")
                }
                .buttonStyle(.primaryPill)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("review.send")
                .disabled(p.items.isEmpty || model.signedOutInstances.count == model.activeInstances.count && !model.activeInstances.isEmpty)
            }
            .padding(20)
        }
    }

    /// "1 entry needs you" — the same words as everywhere else (audit U1).
    private func needsYouText(_ p: ReviewPlan) -> String? {
        var n = NeedsYou()
        for x in p.needsYou { if case .noTask = x.blocker { n.noTask += 1 } else { n.worklogs += 1 } }
        return NeedsYouText.items(n)
    }

    private func needsYouCard(_ p: ReviewPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { NeedsYouDot(); Text(String(localized: "Needs you")).font(DS.F.bodySemibold) }
            ForEach(p.needsYou) { n in
                switch n.blocker {
                case .noTask(let e):
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(localized: "“\(e.description.isEmpty ? String(localized: "No description") : e.description.descriptionFirstLine)” has no task")).font(DS.F.body)
                            Text("\(Fmt.short(n.date)) · \(DurationFormat.short(e.duration(now: model.now)))").font(DS.F.caption).foregroundStyle(DS.C.text3)
                        }
                        Spacer()
                        Button(String(localized: "Pick task")) { pickingFor = e }.buttonStyle(.pill(.secondary, height: DS.H.small))
                    }
                    if pickingFor?.id == e.id {
                        TaskPicker(seed: e.description, preferProject: e.projectId) { i, pid in
                            model.setTask(i, projectId: pid, for: [e]); pickingFor = nil
                        } onCancel: { pickingFor = nil }
                    }
                case .failed(let gid, let err, let line):
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(localized: "\(model.issue(line.issue)?.key ?? "") didn't go: \(err.display)")).font(DS.F.body).lineLimit(2)
                            Text("\(Fmt.short(n.date)) · \(DurationFormat.short(line.value))").font(DS.F.caption).foregroundStyle(DS.C.text3)
                        }
                        Spacer()
                        if line.group?.remoteWorklogId != nil {
                            Button(String(localized: "Take Jira's")) { Task { await model.keepJira(gid) } }
                                .buttonStyle(.pill(.secondary, height: DS.H.small)).help(String(localized: "Leave the worklog as it is in Jira — tikjot follows it"))
                        } else {
                            Button(String(localized: "Pick another task")) { pickingFor = line.entries.first }.buttonStyle(.pill(.secondary, height: DS.H.small))
                        }
                        Button(String(localized: "Retry")) { retry.insert(gid) }.buttonStyle(.pill(.secondary, height: DS.H.small))
                    }
                    if let e = pickingFor, line.entries.contains(where: { $0.id == e.id }) {
                        TaskPicker(preferProject: e.projectId) { i, pid in model.setTask(i, projectId: pid, for: line.entries); pickingFor = nil } onCancel: { pickingFor = nil }
                    }
                case .conflict(let gid, let local, let jira):
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(localized: "\(model.issue(local?.issue)?.key ?? "") changed in Jira and here")).font(DS.F.body)
                            Text(String(localized: "Jira \(DurationFormat.hm(jira?.durationSeconds ?? 0)) · here \(DurationFormat.hm(local?.value ?? 0))")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                        }
                        Spacer()
                        Button(String(localized: "Take Jira's")) { Task { await model.takeJira(gid) } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                        Button(String(localized: "Keep mine")) { Task { await model.keepMine(gid) } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                    }
                case .remoteDeleted(let gid, let line):
                    HStack {
                        Text(String(localized: "\(model.issue(line?.issue)?.key ?? "A worklog") was deleted in Jira")).font(DS.F.body)
                        Spacer()
                        Button(String(localized: "Send again")) { Task { await model.sendAgain(gid) } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                        Button(String(localized: "Remove here")) { Task { await model.removeLocally(gid) } }.buttonStyle(.pill(.secondary, height: DS.H.small))
                    }
                case .taskUnavailable(_, let line):
                    HStack {
                        if model.data.instances.contains(where: { $0.id == line.issue?.instanceId && $0.status == .archived }) {
                            Text(String(localized: "\(model.issue(line.issue)?.key ?? "") is in the old Jira — pick its task in the new one")).font(DS.F.body)
                        } else {
                            Text(String(localized: "\(model.issue(line.issue)?.key ?? "") isn't available in Jira any more")).font(DS.F.body)
                        }
                        Spacer()
                        Button(String(localized: "Pick another task")) { pickingFor = line.entries.first }.buttonStyle(.pill(.secondary, height: DS.H.small))
                    }
                }
            }
            if p.needsYou.filter({ if case .noTask = $0.blocker { return true }; return false }).count > 1 {
                Button(String(localized: "Give all one task…")) { pickingFor = TimeEntry(start: .distantPast, end: nil) }.buttonStyle(LinkButtonStyle()).font(DS.F.caption)
                if pickingFor?.start == .distantPast {
                    TaskPicker { i, pid in
                        let es = p.needsYou.compactMap { if case .noTask(let e) = $0.blocker { return e }; return nil }
                        model.setTask(i, projectId: pid, for: es); pickingFor = nil
                    } onCancel: { pickingFor = nil }
                }
            }
            Text(String(localized: "Everything else will be sent; these wait in Unsent.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.warningSoft.opacity(0.7)))
    }

    private func itemRow(_ item: ReviewPlan.Item) -> some View {
        let color = model.project(item.projectId)?.color ?? "slate"
        let outcome = progress[item.groupId] ?? nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(DS.project(color)).frame(width: 7, height: 7)
                keyLink(item)
                Text(item.issueSummary).font(DS.F.body).lineLimit(1)
                Spacer()
                if phase != .review {
                    // Storyboard C: the active row spins; ✓ pops (0.6 → 1, spring) when Jira answers.
                    ZStack {
                        if outcome == .sent {
                            Image(systemName: "checkmark").foregroundStyle(DS.C.success).font(.system(size: 11, weight: .bold))
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                        } else if case .failed = outcome {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(DS.C.danger)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                        } else if active.contains(item.groupId) {
                            ProgressView().controlSize(.small).transition(.opacity)
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                Text(DurationFormat.hm(item.value)).font(DS.F.monoMedium)
            }
            if editingComment == item.groupId {
                TextEditor(text: $commentText).font(DS.F.body).frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(DS.C.brand))
                HStack {
                    Button(String(localized: "Reset to descriptions")) { saveComment(item, nil) }.buttonStyle(LinkButtonStyle()).font(DS.F.caption)
                    Spacer()
                    Button(String(localized: "Done")) { saveComment(item, commentText) }.buttonStyle(.pill(.primary, height: DS.H.small))
                }
            } else {
                HStack(alignment: .top) {
                    Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(DS.C.text3)
                    // As Jira will show it: one point per line (beta 2026-10-22 — "• a · • b" read badly).
                    Text(item.comment.isEmpty ? String(localized: "No comment") : item.comment)
                        .font(DS.F.caption).foregroundStyle(item.comment.isEmpty ? DS.C.warningText : DS.C.text2).lineLimit(6)
                    Spacer()
                    if phase == .review {
                        Button(String(localized: "Edit")) { commentText = item.comment; editingComment = item.groupId }
                            .buttonStyle(LinkButtonStyle()).font(DS.F.caption)
                    }
                }
            }
            if let note = quietNote(item) { Text(note).font(DS.F.caption).foregroundStyle(DS.C.text3) }
            if case .failed(let e) = outcome { Text(e.display).font(DS.F.caption).foregroundStyle(DS.C.dangerText) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        // Sending: rows wait at 70 %, a sent row tints green.
        .background(phase != .review && outcome == .sent ? DS.C.successSoft.opacity(0.55) : .clear)
        .opacity(phase == .sending && outcome == nil && !active.contains(item.groupId) ? 0.7 : 1)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border).frame(height: 1).padding(.horizontal, 12) }
        .onHover { h in if h { hoveredRow = item.groupId } else if hoveredRow == item.groupId { hoveredRow = nil } }
    }

    /// Beta 2026-10-25: hover a row → its key becomes a link to the task in Jira. The ↗ keeps its room when hidden,
    /// so the summary doesn't jump.
    @ViewBuilder
    private func keyLink(_ item: ReviewPlan.Item) -> some View {
        let hovered = hoveredRow == item.groupId
        if let url = model.jiraURL(item.issue) {
            Link(destination: url) {
                HStack(spacing: 2) {
                    Text(item.issueKey).font(DS.F.key).underline(hovered)
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).opacity(hovered ? 1 : 0)
                }
                .foregroundStyle(hovered ? DS.C.brandText : DS.F.keyColor)
            }
            .help(String(localized: "Open \(item.issueKey) in Jira"))
        } else {
            Text(item.issueKey).font(DS.F.key).foregroundStyle(DS.F.keyColor)
        }
    }

    /// At most one quiet note (§9.8).
    private func quietNote(_ item: ReviewPlan.Item) -> String? {
        for n in item.notes {
            switch n {
            case .commentOverrideStale: return String(localized: "The entries changed after you edited the comment.")
            case .closedIssue(let s): return String(localized: "Task is \(s) in Jira — it may refuse the worklog.")
            case .overEstimate(let spent, let est): return String(localized: "Over the estimate: \(DurationFormat.short(spent)) of \(DurationFormat.short(est)).")
            case .overlaps(let s): return String(localized: "Overlaps another entry by \(DurationFormat.short(s)).")
            // Settings › "Warn when a description is empty" (§ sending: warning only, sending stays allowed).
            case .emptyComment where model.settings.warnEmptyDescription:
                return String(localized: "No description — the worklog goes to Jira without a comment.")
            case .updatesExisting:
                if let prev = item.previous { return String(localized: "Updates the worklog already in Jira (was \(DurationFormat.hm(prev.durationSeconds))).") }
            default: continue
            }
        }
        return nil
    }

    private func alsoLine(_ p: ReviewPlan) -> some View {
        var parts: [String] = []
        if p.unchangedCount > 0 { parts.append(String(localized: "\(p.unchangedCount) unchanged already in Jira")) }
        if !p.deletions.isEmpty { parts.append(String(localized: "\(p.deletions.count) removed from Jira")) }
        if p.roundingDelta != 0 { parts.append(String(localized: "rounding \(DurationFormat.signed(p.roundingDelta))")) }
        if !p.emptyDays.isEmpty { parts.append(String(localized: "nothing tracked on \(p.emptyDays.map { Fmt.short($0) }.joined(separator: ", "))")) }
        // Other unsent days (popover Review & send: "Also not in Jira").
        var otherDays: [LocalDate] = []
        if case .days(let ds) = request.scope, ds.count == 1 {
            otherDays = model.unsentDays().filter { !ds.contains($0) && !includeAlso.contains($0) }
        }
        return VStack(alignment: .leading, spacing: 6) {
            if !parts.isEmpty {
                Button { showAlso.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAlso ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text(String(localized: "Also: ") + parts.joined(separator: " · ")).font(DS.F.caption)
                    }
                    .foregroundStyle(DS.C.text3)
                }
                .buttonStyle(.row)
                if showAlso {
                    ForEach(p.deletions) { d in
                        Text("− \(d.issueKey) · \(Fmt.short(d.date)) · \(DurationFormat.hm(d.previous?.durationSeconds ?? 0))").font(DS.F.caption).foregroundStyle(DS.C.text3)
                    }
                }
            }
            if !otherDays.isEmpty {
                HStack {
                    Image(systemName: "calendar").font(.system(size: 10)).foregroundStyle(DS.C.text3)
                    Text(String(localized: "Also not in Jira: \(otherDays.map { Fmt.short($0) }.joined(separator: ", "))")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                    Spacer()
                    Button(String(localized: "Include")) { includeAlso += otherDays }.buttonStyle(LinkButtonStyle()).font(DS.F.caption)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: DS.R.row).fill(DS.C.surface2))
            }
        }
    }

    private func saveComment(_ item: ReviewPlan.Item, _ text: String?) {
        guard var g = model.data.groups.first(where: { $0.id == item.groupId }) else { return }
        g.commentOverride = text
        g.commentOverrideStale = false
        var c = Changes()
        c.upsertGroups = [g]
        model.perform("Edit comment", c)
        editingComment = nil
    }

    // MARK: Send & results

    private func send(_ p: ReviewPlan) {
        frozen = p.items
        progress = Dictionary(uniqueKeysWithValues: p.items.map { ($0.groupId, nil) })
        active = []
        planeProgress = 0
        listGone = false
        withAnimation(Motion.pick(reduceMotion, Motion.spring)) { phase = .sending }
        Task {
            // The motion follows real progress (storyboard C): one request at a time per Jira site.
            let r = await model.send(p.items) { ev in
                switch ev {
                case .started(let id):
                    withAnimation(Motion.pick(reduceMotion, Motion.easeOut(0.2))) { _ = active.insert(id) }
                case .finished(let id, let res):
                    withAnimation(Motion.pick(reduceMotion, Motion.pressSpring)) {
                        active.remove(id)
                        progress[id] = res
                    }
                }
            }
            report = r
            let allSent = r.stoppedBy == nil && r.failed.isEmpty && r.sentCount > 0
            if allSent && !reduceMotion {
                // last ✓ + 200 ms: the plane flies (600 ms); +800 ms the list fades & collapses; +1 s the hero.
                try? await Task.sleep(nanoseconds: 200_000_000)
                withAnimation(.easeInOut(duration: 0.6)) { planeProgress = 1 }
                try? await Task.sleep(nanoseconds: 600_000_000)
                withAnimation(Motion.easeOut(0.24)) { listGone = true }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            withAnimation(allSent && !reduceMotion ? .spring(response: 0.4, dampingFraction: 0.72) : Motion.crossFade) { phase = .done }
            if r.stoppedBy == nil && r.failed.isEmpty && r.sentCount > 0 {
                // The scope's name comes with the request — no English words cut out of a translated title (U10).
                let head = request.name.map { String(localized: "\($0.capitalizedFirst) is in Jira") } ?? String(localized: "Sent to Jira")
                model.showToast(head + " · " + String(localized: "\(r.sentCount) worklogs"),
                                actionTitle: String(localized: "Undo")) { Task { await model.undoSend(r) } }
            }
        }
    }

    /// Sending (storyboard C): the Send button became a progress pill; rows tick off one by one.
    private var sendingBody: some View {
        let items = frozen.filter { $0.action != .delete }
        let done = items.filter { (progress[$0.groupId] ?? nil) != nil }.count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Sending…")).font(DS.F.screenTitle).accessibilityIdentifier("review.resultTitle")
                Text(String(localized: "You can close this — sending continues in the background.")).font(DS.F.caption).foregroundStyle(DS.C.text2)
            }
            .padding(20)
            ZStack {
                ScrollView {
                    VStack(spacing: 0) { ForEach(items) { itemRow($0) } }
                        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                        .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border))
                        .padding(.horizontal, 20)
                }
                PaperPlaneFlight(progress: planeProgress).padding(.horizontal, 28).padding(.vertical, 4)
            }
            .offset(y: listGone ? -12 : 0)
            .opacity(listGone ? 0 : 1)
            if let secs = model.rateLimitedFor {
                Text(String(localized: "Jira asked us to slow down — waiting \(Int(secs)) s, then continuing by itself.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                    .padding(.horizontal, 20).padding(.top, 8)
            }
            HStack {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Sending \(done) of \(items.count)")).font(DS.F.bodyMedium).rolls("\(done)")
                }
                .padding(.horizontal, 14).frame(height: DS.H.regular)
                .foregroundStyle(DS.C.brandText)
                .background(Capsule().fill(DS.C.brandSoft))
                .accessibilityElement(children: .combine)
                Spacer()
                Button(String(localized: "Close")) { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .opacity(listGone ? 0 : 1)
        }
    }

    private var resultBody: some View {
        let r = report
        let total = frozen.filter { $0.action != .delete }.reduce(0) { $0 + $1.value }
        let failed = r?.failed.count ?? 0
        let sent = r?.sentCount ?? 0
        let (ill, title, sub): (String, String, String) = {
            guard let r else {
                return ("illSentHero", String(localized: "Sending…"), String(localized: "You can close this — sending continues in the background."))
            }
            if (r.stoppedBy?.isUnreachable == true || r.stoppedBy?.isSignInPage == true) && sent == 0 {
                return ("illOffline", String(localized: "Jira can't be reached"), String(localized: "Nothing was sent and your work is safe. tikjot tries again in 1 minute, then every 5 minutes. On VPN? Check it's connected."))
            }
            if r.stoppedBy == .unauthorized {
                return ("illSignedOut", String(localized: "Jira signed you out"), String(localized: "Your token expired or was revoked. Renew it and send again — nothing is lost."))
            }
            if failed > 0 {
                return ("illSentPartly", String(localized: "\(sent) of \(sent + failed) sent"), String(localized: "The rest stays in Unsent with Jira's reason."))
            }
            return ("illSentHero", request.name.map { String(localized: "\($0.capitalizedFirst) is in Jira") } ?? String(localized: "Sent to Jira"),
                    String(localized: "Sent \(DurationFormat.hm(total)) to \(model.activeInstances.first?.name ?? "Jira")") + " · " + String(localized: "\(sent) worklogs"))
        }()
        return VStack(spacing: 14) {
            Illustration(name: ill, width: 220, loops: 1).padding(.top, 20)
                .background {
                    // All of it in Jira: a short burst of confetti from the plane, out past the sheet's edges.
                    if phase == .done, failed == 0, r?.stoppedBy == nil, sent > 0 {
                        ScreenCentre { ConfettiOverlay.burst(at: $0) }
                    }
                }
            Text(title).font(DS.F.screenTitle).accessibilityIdentifier("review.resultTitle")
            Text(sub).font(DS.F.body).foregroundStyle(DS.C.text2).multilineTextAlignment(.center).padding(.horizontal, 30)
            if let secs = model.rateLimitedFor, phase == .sending {
                Text(String(localized: "Jira asked us to slow down — waiting \(Int(secs)) s, then continuing by itself.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
            }
            // All sent: the list already flew off with the plane — only the hero stays.
            if !(failed == 0 && r?.stoppedBy == nil && sent > 0) {
                ScrollView {
                    VStack(spacing: 0) { ForEach(frozen.filter { $0.action != .delete }) { itemRow($0) } }
                        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                }
                .frame(maxHeight: 220)
                .padding(.horizontal, 20)
            }
            let noTask = plan.needsYou.filter { if case .noTask = $0.blocker { return true }; return false }.count
            if noTask > 0 && phase == .done {
                Text(String(localized: "\(noTask) entries without a task stay in tikjot.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
            }
            HStack {
                if r?.stoppedBy == .unauthorized {
                    Button(String(localized: "Renew token")) { dismiss(); AppDelegate.shared?.windows.showSettings(model, tab: .jira) }.buttonStyle(.primaryPill)
                }
                if failed > 0 && r?.stoppedBy == nil {
                    Button(String(localized: "Fix in Unsent")) { dismiss(); model.mainSelection = .unsent; model.unsentFilterNeedsYou = true }.buttonStyle(.pill)
                }
                Spacer()
                Button(phase == .sending ? String(localized: "Close") : String(localized: "Done")) { dismiss() }
                    .buttonStyle(phase == .done ? .primaryPill : .pill).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("review.done")
            }
            .padding(20)
        }
    }
}


/// Storyboard C · 4: the paper plane flies bottom-left → top-right over the list on a slight arc,
/// leaving a dashed trail. Invisible at 0; animate `progress` 0 → 1.
struct PaperPlaneFlight: View, Animatable {
    var progress: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { g in
            let arc = PlaneArc(g.size)
            let t = min(1, progress)
            if t > 0.001 {
                arc.trail(to: t)
                    .stroke(DS.C.brand.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5]))
                // The symbol points up-right (−45°); turn it along the path's tangent.
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DS.C.brand)
                    .rotationEffect(arc.angle(t) + .degrees(45))
                    .position(arc.point(t))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The plane's slight arc: a quadratic Bézier in a w × h box.
private struct PlaneArc {
    let p0: CGPoint
    let c: CGPoint
    let p1: CGPoint

    init(_ s: CGSize) {
        p0 = CGPoint(x: s.width * 0.04, y: s.height * 0.92)
        c = CGPoint(x: s.width * 0.38, y: s.height * 0.12)
        p1 = CGPoint(x: s.width * 0.96, y: s.height * 0.1)
    }

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u, b = 2 * u * t, d = t * t
        return CGPoint(x: a * p0.x + b * c.x + d * p1.x, y: a * p0.y + b * c.y + d * p1.y)
    }

    func angle(_ t: CGFloat) -> Angle {
        let u = 1 - t
        let dx: CGFloat = 2 * u * (c.x - p0.x) + 2 * t * (p1.x - c.x)
        let dy: CGFloat = 2 * u * (c.y - p0.y) + 2 * t * (p1.y - c.y)
        return .radians(Double(atan2(dy, dx)))
    }

    func trail(to t: CGFloat) -> Path {
        var p = Path()
        p.move(to: p0)
        for i in 1...40 { p.addLine(to: point(t * CGFloat(i) / 40)) }
        return p
    }
}
