import SwiftUI
import JiraKit
import SyncEngine
import TikjotDomain
import TikjotPersistence

// MARK: Jira

/// Design "Settings · Jira": the list of sites (status + one action each), "Connect another Jira…",
/// then one box of settings per active site. Connect / edit / remove / import / succession open as dialogs.
struct JiraSettings: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var editing: JiraInstance?
    @State private var removing: JiraInstance?
    @State private var renewing: UUID?

    var body: some View {
        let sites = model.data.instances.filter { $0.deletedAt == nil }
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSection(title: String(localized: "Connected Jira sites")) {
                    if sites.isEmpty {
                        SettingsRow(label: String(localized: "No Jira connected yet"),
                                    hint: String(localized: "tikjot works without one — connect a Jira when you want to send worklogs."))
                    }
                    ForEach(sites) { inst in
                        SiteRow(instance: inst, edit: { editing = inst }, renew: { renewing = renewing == inst.id ? nil : inst.id })
                        if renewing == inst.id {
                            ConnectJiraForm(existing: inst, done: { renewing = nil }, style: .renew)
                        }
                    }
                }
                Button { connecting = true } label: {
                    Label(sites.isEmpty ? String(localized: "Connect a Jira…") : String(localized: "Connect another Jira…"), systemImage: "plus")
                }
                .buttonStyle(.pill)
            }
            ForEach(sites.filter { $0.status != .archived }) { inst in
                SiteSettings(instance: inst)
            }
        }
        .surfaceSheet(isPresented: $connecting) {
            ConnectJiraForm(existing: nil, done: { connecting = false }, style: .dialog).environment(model)
        }
        .surfaceSheet(item: $editing) { inst in
            ConnectJiraForm(existing: inst, done: { editing = nil }, style: .dialog,
                            onRemove: { editing = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { removing = inst } })
                .environment(model)
        }
        .surfaceSheet(item: $removing) { inst in RemoveJiraDialog(instance: inst) { removing = nil }.environment(model) }
        .onChange(of: model.renewTokenRequest) { takeRenewRequest() }
        .onAppear {
            if let first = model.signedOutInstances.first { renewing = first.id }
            takeRenewRequest()
            switch SettingsDebug.sheet {
            case "connect": connecting = true
            case "edit": editing = model.activeInstances.first
            case "remove": removing = model.activeInstances.first
            case "renew": renewing = model.activeInstances.first?.id
            default: break
            }
        }
    }
}

extension JiraSettings {
    /// Renew in the signed-out notification: open the new-token band under that site.
    private func takeRenewRequest() {
        guard let id = model.renewTokenRequest else { return }
        model.renewTokenRequest = nil
        renewing = id
    }
}

/// One site in "Connected Jira sites": name, host · login, status badge, one action.
private struct SiteRow: View {
    @Environment(AppModel.self) private var model
    let instance: JiraInstance
    let edit: () -> Void
    let renew: () -> Void

    var body: some View {
        SettingsRow(label: instance.name, hint: subtitle) {
            HStack(spacing: 12) {
                switch instance.status {
                case .active:
                    StatusBadge(text: synced, icon: "checkmark.circle")
                    Button(String(localized: "Edit"), action: edit).buttonStyle(.pill)
                case .authError:
                    StatusBadge(text: String(localized: "Token expired"), icon: "key", iconColor: DS.C.warning, fill: DS.C.warningSoft)
                    Button(String(localized: "Renew token"), action: renew).buttonStyle(.pill)
                case .archived:
                    StatusBadge(text: String(localized: "Archived · read-only"), icon: "archivebox", iconColor: DS.C.text2, fill: DS.C.surface2)
                    if let undo = try? model.db.value(SyncEngine.SuccessionUndo.self, forKey: "succession-\(instance.id.uuidString)") {
                        Button(String(localized: "Undo link")) {
                            Task {
                                try? await model.engine.undoSuccession(undo)
                                try? model.db.setValue(Optional<Int>.none, forKey: "succession-\(instance.id.uuidString)")
                                model.showToast(String(localized: "Link undone — the older Jira is active again"))
                            }
                        }
                        .buttonStyle(.pill)
                    } else {
                        Button(String(localized: "Edit"), action: edit).buttonStyle(.pill)
                    }
                }
            }
        }
    }

    private var host: String { instance.baseURL.host() ?? instance.baseURL.absoluteString }

    private var subtitle: String {
        if instance.status == .archived, let succ = model.data.instances.first(where: { $0.successorOf == instance.id && $0.deletedAt == nil }) {
            let on = succ.successionDate.map { Fmt.dayMonthYear($0) } ?? ""
            return String(localized: "\(host) · replaced by \(succ.name) on \(on)")
        }
        let who = instance.authMethod == .pat ? "PAT" : (instance.displayName ?? instance.login)
        return "\(host) · \(instance.kind == .cloud ? instance.login : who)"
    }

    private var synced: String {
        guard let last = instance.lastSyncAt else { return String(localized: "Connected") }
        let f = RelativeDateTimeFormatter()
        f.locale = Fmt.locale
        f.unitsStyle = .short
        let rel = model.now.timeIntervalSince(last) < 60 ? String(localized: "just now") : f.localizedString(for: last, relativeTo: model.now)
        return String(localized: "Connected · synced \(rel)")
    }
}

/// Per-site box: import history, saved filters, succession.
private struct SiteSettings: View {
    @Environment(AppModel.self) private var model
    let instance: JiraInstance
    @State private var importing = false
    @State private var showImport = false
    @State private var importError: String?
    /// The day the running import starts from: the instance saves it only once the import task has begun.
    @State private var importFrom: LocalDate?
    @State private var showFilters = false
    @State private var succession: UUID?

    var body: some View {
        let others = model.data.instances.filter { $0.id != instance.id && $0.deletedAt == nil }
        let filters = model.data.suggestionSources.filter { $0.instanceId == instance.id }
        SettingsSection(title: instance.name) {
            SettingsRow(label: String(localized: "Import history from"), hint: String(localized: "Worklogs before this date stay in Jira only")) {
                DateFieldButton(date: Binding(get: { instance.historyStartDate ?? model.today.firstOfMonth }, set: { runImport(from: $0) }),
                                range: Date.distantPast...Clock.now)
            }
            SettingsLinkRow(label: String(localized: "Saved filters for suggestions"), hint: String(localized: "Tasks from these filters rank higher in search"),
                            value: String(localized: "\(filters.count) filters")) { showFilters = true }
            // Only with 2+ sites connected — with one there is nothing it could replace (simplicity pass 2026-10-06).
            if !others.isEmpty {
                SettingsRow(label: String(localized: "Replaces an older Jira"),
                            hint: String(localized: "Only when your company moved from on-prem to Cloud — matches old worklogs so nothing counts twice")) {
                    SettingsPopup(selection: Binding(get: { instance.successorOf }, set: { v in
                        if let v, v != instance.successorOf { succession = v }
                    }), options: [(nil, String(localized: "None"))] + others.map { o in
                        (Optional(o.id), o.id == instance.successorOf && instance.successionDate != nil
                            ? "\(o.name) · \(Fmt.dayMonthYear(instance.successionDate!))" : o.name)
                    })
                }
            }
        }
        .surfaceSheet(isPresented: $showImport) {
            let from = importFrom ?? instance.historyStartDate ?? model.today.firstOfMonth
            ImportProgressDialog(instance: instance, from: from, importing: importing, error: importError, retry: { runImport(from: from) }) {
                showImport = false
            }
            .environment(model)
        }
        .surfaceSheet(isPresented: $showFilters) { SavedFiltersDialog(instance: instance) { showFilters = false }.environment(model) }
        .surfaceSheet(item: Binding(get: { succession.map { IdBox(id: $0) } }, set: { succession = $0?.id })) { b in
            SuccessionDialog(successor: instance, older: b.id) { succession = nil }.environment(model)
        }
        .onAppear {
            guard instance.id == model.activeInstances.first?.id else { return }
            switch SettingsDebug.sheet {
            case "filters": showFilters = true
            case "importing": importing = true; showImport = true
            default: break
            }
        }
    }

    private func runImport(from: LocalDate) {
        guard !importing else { showImport = true; return }
        importFrom = from
        importing = true
        importError = nil
        showImport = true
        Task {
            var inst = instance
            if (inst.historyStartDate ?? model.today) > from || inst.syncCursor == nil {
                inst.historyStartDate = from
                inst.syncCursor = nil
                var c = Changes(); c.upsertInstances = [inst]; model.applySilently(c)
            }
            do {
                // Keys without a project wait as suggestions (the card at the top of Projects).
                _ = try await model.importHistory(instanceId: inst.id)
                model.showToast(String(localized: "History imported"))
                showImport = false
            } catch let e as JiraError {
                model.refreshing = nil
                importError = e.display
            } catch {
                model.refreshing = nil
                importError = error.localizedDescription
            }
            importing = false
        }
    }
}

private struct IdBox: Identifiable { let id: UUID }

/// "Importing your history" — progress; can be hidden while it runs.
private struct ImportProgressDialog: View {
    @Environment(AppModel.self) private var model
    let instance: JiraInstance
    let from: LocalDate
    let importing: Bool
    let error: String?
    let retry: () -> Void
    let hide: () -> Void

    var body: some View {
        SettingsDialog(title: String(localized: "Importing your history"),
                       message: String(localized: "Your own worklogs from \(instance.baseURL.host() ?? "") since \(Fmt.dayMonthYear(from)). You can close this and keep working.")) {
            let p = model.refreshing
            let share = Double(p?.done ?? 0) / Double(max(p?.total ?? 1, 1))
            GeometryReader { g in
                Capsule().fill(DS.C.surface2)
                    .overlay(alignment: .leading) { Capsule().fill(DS.C.brand).frame(width: max(8, g.size.width * share)) }
            }
            .frame(height: 8)
            .accessibilityElement().accessibilityValue("\(Int(share * 100)) %")
            if let p {
                let ofTotal = String(localized: "of \(p.total) tasks")   // its own plural string ("of 1 task")
                Text(String(localized: "\(p.done) \(ofTotal) · you can keep working")).font(DS.F.body).foregroundStyle(DS.C.text2)
            }
            if let error {
                BannerView(kind: .danger, icon: "exclamationmark.triangle", text: String(localized: "Import stopped: \(error). What came in is kept."),
                           action: String(localized: "Try again"), perform: retry)
            }
        } footer: {
            Button(String(localized: "Hide"), action: hide).buttonStyle(.pill).keyboardShortcut(.cancelAction)
            Button(action: hide) {
                Label(importing ? String(localized: "Importing…") : String(localized: "Done"), systemImage: importing ? "arrow.triangle.2.circlepath" : "checkmark")
            }
            .buttonStyle(.primaryPill).disabled(importing)
        }
    }
}

/// Saved filters / JQL whose tasks rank higher in search.
private struct SavedFiltersDialog: View {
    @Environment(AppModel.self) private var model
    let instance: JiraInstance
    let done: () -> Void
    @State private var value = ""

    var body: some View {
        SettingsDialog(title: String(localized: "Saved filters for suggestions"),
                       message: String(localized: "Tasks from a Jira filter (id) or JQL are boosted in search")) {
            let sources = model.data.suggestionSources.filter { $0.instanceId == instance.id }
            if !sources.isEmpty {
                SettingsBox {
                    ForEach(sources) { s in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 13)).foregroundStyle(DS.C.brand)
                            Text(s.name).font(DS.F.body).foregroundStyle(DS.C.text).lineLimit(1)
                            Spacer()
                            Button { var c = Changes(); c.deleteSuggestionSources = [s.id]; model.applySilently(c) } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2).frame(width: 20, height: 20).contentShape(Rectangle())
                            }
                            .buttonStyle(.icon)
                            .accessibilityLabel(String(localized: "Remove \(s.name)"))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
            }
            HStack(spacing: 8) {
                SettingsTextField(placeholder: String(localized: "Filter id or JQL"), text: $value, mono: true)
                Button(String(localized: "Add"), action: add).buttonStyle(.pill).disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            Button(String(localized: "Done"), action: done).buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
        }
    }

    private func add() {
        let v = value.trimmingCharacters(in: .whitespaces)
        let isId = v.allSatisfy(\.isNumber)
        let s = SuggestionSource(instanceId: instance.id, kind: isId ? .jiraFilterId : .jql, value: v, name: isId ? String(localized: "Filter \(v)") : v)
        var c = Changes(); c.upsertSuggestionSources = [s]
        model.applySilently(c)
        value = ""
        Task { try? await model.engine.refreshSource(s) }
    }
}

/// "Remove <site>?" — disconnect (history stays, can reconnect) or delete this site's data from tikjot.
private struct RemoveJiraDialog: View {
    @Environment(AppModel.self) private var model
    let instance: JiraInstance
    let done: () -> Void

    var body: some View {
        let unsent = model.data.groups.filter { $0.instanceId == instance.id && $0.deletedAt == nil && ($0.syncState == .unsent || $0.syncState == .modified) }.count
        SettingsDialog(title: String(localized: "Remove \(instance.name)?"),
                       message: String(localized: "Disconnecting keeps every entry and statistic; sync stops and you can reconnect later. Deleting removes this site's entries from tikjot (not from Jira)."), width: 600) {
            if unsent > 0 {
                DialogWarning(text: String(localized: "\(unsent) worklogs for this Jira aren't sent yet. Send them first if you want them in Jira."))
            }
        } footer: {
            Button(String(localized: "Cancel"), action: done).buttonStyle(.pill).keyboardShortcut(.cancelAction)
            Button { Task { await model.deleteAllData(of: instance) }; done() } label: {
                Label(String(localized: "Delete all data of this site"), systemImage: "trash")
            }
            .buttonStyle(.dangerPill)
            if instance.status != .archived {
                Button(String(localized: "Disconnect, keep history")) { Task { await model.disconnect(instance) }; done() }
                    .buttonStyle(.primaryPill)
            }
        }
    }
}

/// "<site> replaces an older Jira" — preview, then link (§9.11).
struct SuccessionDialog: View {
    @Environment(AppModel.self) private var model
    let successor: JiraInstance
    let done: () -> Void
    @State private var older: UUID?
    @State private var date = Clock.now
    @State private var preview: SyncEngine.SuccessionPreview?
    @State private var working = false
    @State private var error: String?

    init(successor: JiraInstance, older: UUID, done: @escaping () -> Void) {
        self.successor = successor
        self.done = done
        _older = State(initialValue: older)
    }

    var body: some View {
        let others = model.data.instances.filter { $0.id != successor.id && $0.deletedAt == nil }
        SettingsDialog(title: String(localized: "\(successor.name) replaces an older Jira"),
                       message: String(localized: "When your company moved to Cloud, the old worklogs were copied too. Tell tikjot where they came from, so nothing counts twice.")) {
            HStack { Spacer(); Illustration(name: "illMigration", width: 200); Spacer() }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text(String(localized: "Older Jira")).font(DS.F.body).foregroundStyle(DS.C.text2)
                    SettingsPopup(selection: $older, options: others.map { (Optional($0.id), "\($0.name) · \($0.baseURL.host() ?? "")") })
                }
                GridRow {
                    Text(String(localized: "Moved on")).font(DS.F.body).foregroundStyle(DS.C.text2)
                    DateFieldButton(date: Binding(get: { LocalDate(date, calendar: .current) }, set: { date = Fmt.date($0) }), width: 150)
                }
            }
            if let p = preview {
                FactsWell(rows: [
                    (String(localized: "Matched with yours"), String(localized: "\(p.matched.count) · linked, not doubled")),
                    (String(localized: "Only in the old Jira"), String(localized: "\(p.unmatchedOld) · kept there, counted once")),
                ] + (p.unsent.isEmpty ? [] : [
                    (String(localized: "Not sent yet"), String(localized: "\(p.unsent.count) · move here, send them from here")),
                ]) + (p.unsentStuck == 0 ? [] : [
                    (String(localized: "Task not here"), String(localized: "\(p.unsentStuck) · not sent — pick another task")),
                ]) + [
                    (String(localized: "Old Jira afterwards"), String(localized: "archived · read-only")),
                ])
            } else if working {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(String(localized: "Checking…")).font(DS.F.body).foregroundStyle(DS.C.text2) }
            }
            if let error { Text(error).font(DS.F.caption).foregroundStyle(DS.C.dangerText) }
        } footer: {
            Button(String(localized: "Cancel"), action: done).buttonStyle(.pill).keyboardShortcut(.cancelAction)
            Button {
                guard let older, let p = preview else { return }
                Task {
                    if let undo = try? await model.engine.applySuccession(p, successor: successor.id, predecessor: older, date: LocalDate(date, calendar: .current)) {
                        try? model.db.setValue(undo, forKey: "succession-\(older.uuidString)")
                    }
                    model.showToast(String(localized: "Linked — the older Jira is archived"))
                    done()
                }
            } label: {
                Label(String(localized: "Link \(preview?.matched.count ?? 0) worklogs"), systemImage: "checkmark")
            }
            .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            .disabled(preview == nil || working)
        }
        .task(id: "\(older?.uuidString ?? "")|\(LocalDate(date, calendar: .current))") { await runPreview() }
        .onAppear { date = Fmt.date(successor.successionDate ?? model.today) }
    }

    private func runPreview() async {
        guard let older else { return }
        working = true
        preview = nil
        error = nil
        do { preview = try await model.engine.previewSuccession(successor: successor.id, predecessor: older, from: LocalDate(date, calendar: .current)) }
        catch { self.error = (error as? JiraError)?.display ?? error.localizedDescription }
        working = false
    }
}

/// Connect / renew (§9.1): Cloud = email + API token; Data Center = PAT (or username + password).
/// `.inline` (onboarding), `.dialog` (Settings › Connect a Jira / Edit) and `.renew` (the warm band under an expired site).
struct ConnectJiraForm: View {
    enum Style { case inline, dialog, renew }
    @Environment(AppModel.self) private var model
    let existing: JiraInstance?
    let done: () -> Void
    var compact = false
    var style: Style = .inline
    var onConnected: ((JiraInstance) -> Void)?
    /// Edit dialog: "Remove…" in the footer.
    var onRemove: (() -> Void)?

    @State private var kind: JiraKind = .cloud
    @State private var site = ""
    @State private var login = ""
    @State private var secret = ""
    @State private var usePassword = false
    @State private var historyFrom = Clock.now
    @State private var state: Phase = .idle
    /// Jira refused the details → the token help opens by itself (that's when people need it).
    @State private var rejected = false
    /// Connect another Jira (design jaSPm): the new connection, while its history imports and step 2 shows its projects.
    @State private var connectedNew: JiraInstance?
    @State private var importingHistory = false
    @State private var importFailed: String?
    @State private var showProjects = false
    @State private var proposals: [(UUID, String)] = []
    @State private var choices = ProjectProposalChoices()
    /// What tikjot found at the address (beta 2026-10-18): the type it set, or that it couldn't ask.
    @State private var detected: Detected?
    enum Phase: Equatable { case idle, connecting, connected(String), failed(String) }
    enum Detected: Equatable { case found(JiraKind, host: String), unreachable(host: String) }

    var body: some View {
        Group {
            switch style {
            case .inline: inlineBody
            case .dialog: dialogBody
            case .renew: renewBody
            }
        }
        .onAppear {
            historyFrom = Fmt.date(model.today.firstOfMonth)
            if let e = existing {
                kind = e.kind; site = e.baseURL.absoluteString; login = e.login; usePassword = e.authMethod == .basic
            }
        }
        .task(id: site) { await detect() }
    }

    /// A moment after you stop typing a new address, ask it what it is and set the switch (the fields follow).
    private func detect() async {
        guard existing == nil, let url = baseURL, let host = url.host(), Self.looksComplete(host) else { detected = nil; return }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !Task.isCancelled else { return }
        let found = await model.connections.detectJiraKind(url)
        guard !Task.isCancelled, baseURL == url else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            if let found {
                detected = .found(found, host: host)
                kind = found
            } else {
                detected = .unreachable(host: host)
            }
        }
    }

    /// "jira.acme.com" yes; "jira", "jira.acme.c" (still typing) no.
    static func looksComplete(_ host: String) -> Bool {
        guard let tld = host.split(separator: ".").last, host.contains(".") else { return false }
        return tld.count >= 2
    }

    // MARK: Inline (onboarding)

    @ViewBuilder
    private var inlineBody: some View {
        if compact { onboardingBody } else { inlineFullBody }
    }

    /// Onboarding step 4 (design jLOKW): icon fields like Settings, email + token side by side; the Connect
    /// button lives in the onboarding footer (`.onboardingConnect`).
    private var onboardingBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            PillSegmented(selection: $kind, options: [(.cloud, String(localized: "Jira Cloud")), (.dataCenter, String(localized: "Data Center / Server"))], compact: true)
            LabeledField(label: String(localized: "Site")) {
                SettingsTextField(placeholder: kind == .cloud ? "company.atlassian.net" : "https://jira.company.com", text: $site, icon: "globe")
            }
            kindHint
            HStack(alignment: .top, spacing: 10) {
                if kind == .cloud || usePassword {
                    LabeledField(label: kind == .cloud ? String(localized: "Email") : String(localized: "Username")) {
                        SettingsTextField(placeholder: kind == .cloud ? "you@company.com" : "username", text: $login, icon: kind == .cloud ? "at" : "person")
                    }
                }
                LabeledField(label: secretLabel) {
                    SettingsTextField(placeholder: String(localized: "Paste token"), text: $secret, icon: "key", secure: true, error: isFailed)
                }
            }
            if kind == .dataCenter {
                Toggle(String(localized: "My Jira doesn't have personal access tokens — use username and password"), isOn: $usePassword).toggleStyle(.checkbox).font(DS.F.caption)
            }
            Text(String(localized: "The token is stored only in your Mac's Keychain.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
            TokenHelp(kind: kind, usePassword: usePassword, siteURL: baseURL, expanded: rejected)
                .id("\(kind.rawValue)-\(usePassword)-\(rejected)")
            stateBanner
        }
        .onReceive(NotificationCenter.default.publisher(for: .onboardingConnect)) { _ in
            if valid && state != .connecting { connect() }
        }
    }

    private var inlineFullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if existing == nil {
                PillSegmented(selection: $kind, options: [(.cloud, String(localized: "Jira Cloud")), (.dataCenter, String(localized: "Data Center / Server"))])
            }
            field(String(localized: "Site"), kind == .cloud ? "company.atlassian.net" : "https://jira.company.com", $site).disabled(existing != nil)
            kindHint
            if kind == .cloud || usePassword {
                field(kind == .cloud ? String(localized: "Email") : String(localized: "Username"), kind == .cloud ? "you@company.com" : "username", $login)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(secretLabel).font(DS.F.captionMedium).foregroundStyle(DS.C.text2)
                    SecureField("", text: $secret).textFieldStyle(.plain).fieldStyle()
                }
                Button(kind == .cloud ? String(localized: "Create a token ↗") : String(localized: "Open your profile ↗")) {
                    if let u = tokenURL { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(LinkButtonStyle()).font(DS.F.caption).padding(.bottom, 8)
            }
            TokenHelp(kind: kind, usePassword: usePassword, siteURL: baseURL, expanded: rejected)
                .id("\(kind.rawValue)-\(usePassword)-\(rejected)")
            if kind == .dataCenter {
                Toggle(String(localized: "My Jira doesn't have personal access tokens — use username and password"), isOn: $usePassword).toggleStyle(.checkbox).font(DS.F.caption)
            }
            if existing == nil && !compact {
                HStack {
                    Text(String(localized: "Import my worklogs from")).font(DS.F.body)
                    DateFieldButton(date: Binding(get: { LocalDate(historyFrom, calendar: .current) }, set: { historyFrom = Fmt.date($0) }), range: Date.distantPast...Clock.now)
                }
            }
            stateBanner
            HStack {
                Text(String(localized: "The token is stored only in your Mac's Keychain.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                Spacer()
                if existing != nil || !compact { Button(String(localized: "Cancel"), action: done).buttonStyle(.pill) }
                Button(state == .connecting ? String(localized: "Connecting…") : (existing == nil ? String(localized: "Test & connect") : String(localized: "Save token"))) { connect() }
                    .buttonStyle(.primaryPill).disabled(state == .connecting || !valid).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Dialog (Settings)

    @ViewBuilder private var dialogBody: some View {
        if showProjects, let inst = connectedNew {
            ConnectProjectsStep(instance: inst, from: LocalDate(historyFrom, calendar: .current), items: proposals, choices: $choices,
                                back: { withAnimation(.easeOut(duration: 0.15)) { showProjects = false } },
                                add: { model.createProposedProjects(proposals, choices: choices); done() })
        } else {
            connectDialog
        }
    }

    private var connectDialog: some View {
        SettingsDialog(title: existing.map { String(localized: "Edit \($0.name)") } ?? String(localized: "Connect a Jira")) {
            if existing == nil {
                HStack(spacing: 10) {
                    Text(String(localized: "Where does your Jira live?")).font(.system(size: 12)).foregroundStyle(DS.C.text2)
                    Spacer(minLength: 0)
                    PillSegmented(selection: $kind, options: [(.cloud, String(localized: "Jira Cloud")), (.dataCenter, String(localized: "Data Center / Server"))], compact: true)
                }
            }
            LabeledField(label: String(localized: "Site")) {
                SettingsTextField(placeholder: kind == .cloud ? "company.atlassian.net" : "https://jira.company.com", text: $site, icon: "globe")
                    .disabled(existing != nil).opacity(existing != nil ? 0.7 : 1)
            }
            kindHint
            if kind == .cloud || usePassword {
                LabeledField(label: kind == .cloud ? String(localized: "Email") : String(localized: "Username")) {
                    SettingsTextField(placeholder: kind == .cloud ? "you@company.com" : "username", text: $login, icon: kind == .cloud ? "at" : "person")
                }
            }
            LabeledField(label: secretLabel) {
                SettingsTextField(placeholder: "", text: $secret, icon: "key", secure: true, error: isFailed)
            }
            TokenHelp(kind: kind, usePassword: usePassword, siteURL: baseURL, expanded: rejected)
                .id("\(kind.rawValue)-\(usePassword)-\(rejected)")
            if kind == .dataCenter {
                Toggle(String(localized: "My Jira doesn't have personal access tokens — use username and password"), isOn: $usePassword).toggleStyle(.checkbox).font(DS.F.caption)
            }
            if existing == nil {
                HStack {
                    Text(String(localized: "Import my worklogs from")).font(DS.F.body).foregroundStyle(DS.C.text)
                    Spacer()
                    DateFieldButton(date: Binding(get: { LocalDate(historyFrom, calendar: .current) }, set: { historyFrom = Fmt.date($0) }), range: Date.distantPast...Clock.now)
                }
            }
            stateBanner
        } footer: {
            if let onRemove {
                Button(action: onRemove) { Label(String(localized: "Remove…"), systemImage: "trash") }.buttonStyle(.dangerPill)
                Spacer()
            } else {
                Text(String(localized: "The token is stored in your Keychain only.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(String(localized: "Cancel"), action: done).buttonStyle(.pill).keyboardShortcut(.cancelAction)
            if importingHistory {
                Button {} label: { Label(String(localized: "Importing…"), systemImage: "arrow.down.circle") }
                    .buttonStyle(.primaryPill).disabled(true)
            } else if importFailed != nil {
                Button(String(localized: "Close"), action: done).buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            } else if connectedNew != nil {
                // Back from step 2: the connection is made — go on to its projects.
                Button { withAnimation(.easeOut(duration: 0.15)) { showProjects = true } } label: {
                    HStack(spacing: 6) { Text(String(localized: "Continue")); Image(systemName: "arrow.right") }
                }
                .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            } else {
                Button { connect() } label: {
                    Label(state == .connecting ? String(localized: "Connecting…") : (existing == nil ? String(localized: "Connect") : String(localized: "Save token")),
                          systemImage: "powerplug")
                }
                .buttonStyle(.primaryPill).disabled(state == .connecting || !valid).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Renew band (expired token)

    private var renewBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind == .cloud ? String(localized: "New API token") : (usePassword ? String(localized: "New password") : String(localized: "New personal access token")))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
            SettingsTextField(placeholder: String(localized: "Paste the token from \(baseURL?.host() ?? "")"), text: $secret, icon: "key", secure: true, error: isFailed)
            Text(kind == .cloud
                 ? String(localized: "id.atlassian.com › Security › API tokens › Create. tikjot only needs permission to read issues and log work.")
                 : String(localized: "Profile › Personal Access Tokens › Create. tikjot only needs permission to read issues and log work."))
                .font(DS.F.caption).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
            stateBanner
            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "Cancel"), action: done).buttonStyle(.pill)
                Button { connect() } label: {
                    Label(state == .connecting ? String(localized: "Connecting…") : String(localized: "Save & reconnect"), systemImage: "powerplug")
                }
                .buttonStyle(.primaryPill).disabled(state == .connecting || !valid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.warningSoft)
    }

    // MARK: Shared

    @ViewBuilder private var stateBanner: some View {
        switch state {
        case .failed(let m):
            BannerView(kind: .danger, icon: "exclamationmark.triangle", text: m)
        case .connected(let who):
            BannerView(kind: .info, icon: "checkmark.circle", text: String(localized: "Connected as \(who)."))
        default: EmptyView()
        }
        if importingHistory {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Importing your worklogs…")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                ProgressView(value: Double(model.refreshing?.done ?? 0), total: Double(max(model.refreshing?.total ?? 1, 1)))
                    .progressViewStyle(.linear).tint(DS.C.brand)
            }
        }
        if let importFailed {
            BannerView(kind: .danger, icon: "exclamationmark.triangle", text: importFailed)
        }
    }

    /// Under the address: what tikjot found there (beta 2026-10-18), or — when it couldn't ask — the old guess from
    /// the address's shape (Cloud picked for a Data Center address or the other way round) with one button.
    @ViewBuilder private var kindHint: some View {
        if existing == nil, case .found(let k, let host) = detected, k == kind {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(DS.C.successText)
                Text(k == .cloud ? String(localized: "Jira Cloud · \(host)") : String(localized: "Jira Data Center · \(host)"))
                    .font(DS.F.caption).foregroundStyle(DS.C.successText).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("connect.detected")
        } else if existing == nil, let other = JiraSite.kindHint(for: site, chosen: kind) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(DS.C.brand)
                Text(other == .dataCenter ? String(localized: "This looks like a Data Center address — switch?") : String(localized: "This looks like Jira Cloud — switch?"))
                    .font(DS.F.caption).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(String(localized: "Switch")) { withAnimation(.easeOut(duration: 0.15)) { kind = other } }
                    .buttonStyle(.pill(.secondary, height: DS.H.small))
            }
        } else if existing == nil, case .unreachable(let host) = detected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash").font(.system(size: 11)).foregroundStyle(DS.C.warningText)
                Text(String(localized: "Can't reach \(host) right now (VPN?) — choose the type yourself."))
                    .font(DS.F.caption).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var isFailed: Bool { if case .failed = state { return true } else { return false } }

    private var secretLabel: String {
        kind == .cloud ? String(localized: "API token") : (usePassword ? String(localized: "Password") : String(localized: "Personal access token"))
    }

    private var valid: Bool {
        !site.trimmingCharacters(in: .whitespaces).isEmpty && !secret.isEmpty && (kind == .dataCenter && !usePassword || !login.isEmpty)
    }

    /// https only, host required; user/password, query and fragment dropped; a context path ("/jira") kept.
    private var baseURL: URL? { try? JiraSite.normalizedBaseURL(site) }

    private var tokenURL: URL? {
        if kind == .cloud { return URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens") }
        return baseURL?.appendingPathComponent("secure/ViewProfile.jspa")
    }

    private func field(_ label: String, _ placeholder: String, _ b: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(DS.F.captionMedium).foregroundStyle(DS.C.text2)
            TextField(placeholder, text: b).textFieldStyle(.plain).fieldStyle()
        }
    }

    private func connect() {
        let url: URL
        do {
            url = try JiraSite.normalizedBaseURL(site)
        } catch {
            state = .failed((error as? JiraError)?.display ?? JiraError.badURL.display)
            return
        }
        state = .connecting
        let method: JiraAuthMethod = kind == .cloud ? .cloudApiToken : (usePassword ? .basic : .pat)
        let name = existing?.name ?? (kind == .cloud ? (url.host()?.components(separatedBy: ".").first?.capitalized ?? "Jira") + " Cloud" : "Jira " + (url.host() ?? ""))
        Task {
            do {
                let r = try await model.connect(name: name, kind: kind, baseURL: url, method: method, login: login, secret: secret,
                                                historyStart: LocalDate(historyFrom, calendar: .current),
                                                replacing: existing)
                state = .connected(r.user.displayName)
                onConnected?(r.instance)
                if style == .dialog && existing == nil {
                    await importThenPropose(r.instance)
                    return
                }
                Task { await model.refreshAll(reason: "connected") }
                try? await Task.sleep(nanoseconds: 800_000_000)
                if existing != nil || !compact { done() }
            } catch let p as JiraSignInProblem {
                // Refused details, said by cause (Cloud needs a token, PAT mismatch, company SSO); the token help opens.
                // The other kind of Jira at this address (it couldn't be asked before): say it and switch.
                if let other = await wrongKind(url) { state = .failed(other); return }
                state = .failed(p.display)
                withAnimation(.easeOut(duration: 0.15)) { rejected = true }
            } catch let e as JiraError {
                if e == .unauthorized || e == .notFound, let other = await wrongKind(url) { state = .failed(other); return }
                state = .failed(e == .unauthorized ? JiraSignInProblem.wrongPassword.display : e.display)
                if e == .unauthorized { withAnimation(.easeOut(duration: 0.15)) { rejected = true } }
                if case .forbidden = e { withAnimation(.easeOut(duration: 0.15)) { rejected = true } }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Connecting failed and the address turns out to be the other kind of Jira: switch to it and say what to paste.
    private func wrongKind(_ url: URL) async -> String? {
        guard existing == nil, let found = await model.connections.detectJiraKind(url), found != kind else { return nil }
        withAnimation(.easeOut(duration: 0.15)) {
            kind = found
            detected = .found(found, host: url.host() ?? "")
            rejected = true
        }
        return found == .dataCenter
            ? String(localized: "This is Jira Data Center — tikjot switched to it. Paste a personal access token.")
            : String(localized: "This is Jira Cloud — tikjot switched to it. Use your email and an API token.")
    }

    /// Connect another Jira: import its history in the dialog, then step 2 "Projects from <host>" with the projects
    /// found (the onboarding list). Nothing found → closes as before. Closing early keeps them waiting (Projects card).
    private func importThenPropose(_ inst: JiraInstance) async {
        connectedNew = inst
        importingHistory = true
        importFailed = nil
        do {
            _ = try await model.importHistory(instanceId: inst.id)
        } catch {
            importingHistory = false
            let why = (error as? JiraError)?.display ?? error.localizedDescription
            importFailed = String(localized: "Import stopped — what came in is kept. \(why)")
            return
        }
        importingHistory = false
        // Assigned tasks, statuses, suggestion sources — the rest of a normal refresh.
        Task { await model.refreshAll(reason: "connected") }
        let items = model.proposalItems(instanceId: inst.id)
        guard !items.isEmpty else {
            try? await Task.sleep(nanoseconds: 800_000_000)
            done()
            return
        }
        proposals = items
        choices = ProjectProposalChoices(items: items, model: model)
        withAnimation(.easeOut(duration: 0.15)) { showProjects = true }
    }
}

/// Connect another Jira, step 2 (design jaSPm): the projects found in that Jira's worklogs — the same list as in
/// onboarding — and what happens to the ones you leave out.
private struct ConnectProjectsStep: View {
    let instance: JiraInstance
    let from: LocalDate
    let items: [(UUID, String)]
    @Binding var choices: ProjectProposalChoices
    let back: () -> Void
    let add: () -> Void

    var body: some View {
        let n = choices.included(items)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                steps
                Text(String(localized: "Projects from \(instance.baseURL.host() ?? instance.name)")).font(DS.F.dialogTitle).foregroundStyle(DS.C.text)
                Text(String(localized: "Found in your worklogs since \(Fmt.dayMonth(from)): \(items.count) Jira projects. Name them the way you know them."))
                    .font(DS.F.body).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
                if items.count > 5 {
                    ScrollView { ProjectProposalList(items: items, choices: $choices) }.frame(height: 330)
                } else {
                    ProjectProposalList(items: items, choices: $choices)
                }
                Text(String(localized: "Projects you leave out: their entries keep their task and still go to Jira, just without a project. Starting a timer on such a task creates the project later."))
                    .font(DS.F.caption).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button(String(localized: "Back"), action: back).buttonStyle(.pill)
                Spacer()
                Button(action: add) {
                    if n > 0 { Label(String(localized: "Add \(n) projects"), systemImage: "plus") } else { Text(String(localized: "Done")) }
                }
                .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(DS.C.surface2)
            .overlay(alignment: .top) { Rectangle().fill(DS.C.border).frame(height: 1) }
        }
        .frame(width: 540)
        .background(DS.C.surface)
    }

    /// "✓ Connect — 2 Projects".
    private var steps: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(DS.C.text3)
            Text(String(localized: "Connect")).font(DS.F.caption).foregroundStyle(DS.C.text3)
            Rectangle().fill(DS.C.border).frame(width: 28, height: 1)
            Text(verbatim: "2").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Circle().fill(DS.C.brand))
            Text(String(localized: "Projects")).font(DS.F.captionMedium).foregroundStyle(DS.C.text)
        }
    }
}

// MARK: Backup

/// Design "Settings · Backup": automatic snapshots, encrypted backup file (export / import dialogs), your data.
struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var snapshots: [SnapshotManager.Info] = []
    @State private var showSnapshots = false
    @State private var showExport = false
    @State private var importURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let err = model.snapshotError {
                SettingsNotice(kind: .danger, icon: "externaldrive.badge.exclamationmark", title: String(localized: "Today's snapshot couldn't be saved"),
                               text: String(localized: "\(err). Your data is untouched."), action: String(localized: "Try again"), actionIcon: "arrow.clockwise") {
                    AppDelegate.shared?.services?.takeSnapshot(); refresh()
                }
            }
            SettingsSection(title: String(localized: "Automatic snapshots")) {
                SettingsRow(label: String(localized: "Daily snapshot"), hint: String(localized: "At the first launch each day · kept for \(model.settings.snapshotsKeep) days")) {
                    SettingsSwitch(label: String(localized: "Daily snapshot"), isOn: Binding(get: { model.settings.snapshotsEnabled }, set: { v in model.updateSettings { $0.snapshotsEnabled = v } }))
                }
                SettingsRow(label: String(localized: "Last snapshot"), hint: lastSnapshot, hintColor: model.snapshotError != nil ? DS.C.dangerText : DS.C.text3) {
                    Button(String(localized: "Show in Finder")) {
                        if let s = snapshots.first { NSWorkspace.shared.activateFileViewerSelecting([s.url]) } else { NSWorkspace.shared.open(Paths.snapshots) }
                    }
                    .buttonStyle(.pill)
                    .disabled(snapshots.isEmpty)
                }
                SettingsLinkRow(label: String(localized: "Restore a snapshot…"), hint: String(localized: "Go back to how tikjot was on an earlier day"),
                                value: String(localized: "\(snapshots.count) snapshots")) { showSnapshots = true }
            }
            SettingsSection(title: String(localized: "Encrypted backup file")) {
                SettingsRow(label: String(localized: "Export backup…"), hint: String(localized: "All data in one .tikjotbackup file, locked with a password. Use it to move to a new Mac.")) {
                    Button { showExport = true } label: { Label(String(localized: "Export…"), systemImage: "lock") }.buttonStyle(.pill)
                }
                // Say when the file was made — passive, no reminder (owner, 2026-10-06).
                SettingsRow(label: String(localized: "Last exported")) {
                    Text(model.lastBackupExport.map { Fmt.dayMonthYear(LocalDate($0, calendar: .current)) } ?? String(localized: "Never"))
                        .font(DS.F.body).foregroundStyle(model.lastBackupExport == nil ? DS.C.text3 : DS.C.text2)
                }
                SettingsRow(label: String(localized: "Import backup…"), hint: String(localized: "Replaces all data on this Mac")) {
                    Button {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [.init(filenameExtension: "tikjotbackup") ?? .data]
                        if p.runModal() == .OK { importURL = p.url }
                    } label: { Label(String(localized: "Import…"), systemImage: "square.and.arrow.down") }
                    .buttonStyle(.pill)
                }
            }
            SettingsSection(title: String(localized: "Your data")) {
                SettingsRow(label: String(localized: "Stored on this Mac only"), hint: String(localized: "\(Self.abbreviated(Paths.support)) · encrypted, key in your Keychain")) {
                    Button(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([Paths.database]) }.buttonStyle(.pill)
                }
                SettingsRow(label: String(localized: "Jira tokens"), hint: String(localized: "Kept in the Keychain — never in backups")) {
                    StatusBadge(text: String(localized: "Keychain"), icon: "checkmark.shield")
                }
                SettingsRow(label: String(localized: "Delete all data…"), hint: String(localized: "Removes everything tikjot stores on this Mac. Jira is not touched."), labelColor: DS.C.dangerText) {
                    Button { confirmDelete = true } label: { Label(String(localized: "Delete…"), systemImage: "trash") }.buttonStyle(.dangerPill)
                }
            }
        }
        .onAppear {
            refresh()
            switch SettingsDebug.sheet {
            case "snapshots": showSnapshots = true
            case "export": showExport = true
            default: break
            }
        }
        .surfaceSheet(isPresented: $showSnapshots) { SnapshotsDialog(snapshots: snapshots) { showSnapshots = false }.environment(model) }
        .surfaceSheet(isPresented: $showExport) { ExportBackupDialog { showExport = false }.environment(model) }
        .surfaceSheet(item: Binding(get: { importURL.map { URLBox(url: $0) } }, set: { importURL = $0?.url })) { b in
            ImportBackupDialog(url: b.url) { importURL = nil }.environment(model)
        }
        .confirmationDialog(String(localized: "Delete all tikjot data on this Mac?"), isPresented: $confirmDelete) {
            Button(String(localized: "Delete everything"), role: .destructive) { Task { await Restore.deleteAll(model) } }
        } message: { Text(String(localized: "Entries, projects, settings and snapshots are removed. This can't be undone. Jira is not touched.")) }
    }

    private var lastSnapshot: String {
        guard let last = snapshots.first else { return model.snapshotError != nil ? String(localized: "failed") : String(localized: "None yet") }
        let d = LocalDate(last.date, calendar: .current)
        let s = "\(Fmt.dayName(d, today: model.today)) \(Fmt.time(last.date)) · \(ByteCountFormatter.string(fromByteCount: last.size, countStyle: .file))"
        return model.snapshotError != nil ? String(localized: "\(s) · today's failed") : s
    }

    static func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = url.path
        // Sandboxed: ~/Library/Containers/<id>/Data/… is the user's view of the same place.
        if let r = p.range(of: "/Library/Containers/") , let d = p.range(of: "/Data/", range: r.upperBound..<p.endIndex) { p = home + "/" + p[d.upperBound...] }
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private func refresh() { snapshots = SnapshotManager(directory: Paths.snapshots).list() }
}

private struct URLBox: Identifiable { let url: URL; var id: URL { url } }

/// Daily snapshots to go back to.
private struct SnapshotsDialog: View {
    @Environment(AppModel.self) private var model
    let snapshots: [SnapshotManager.Info]
    let done: () -> Void

    var body: some View {
        SettingsDialog(title: String(localized: "Restore a snapshot"),
                       message: String(localized: "tikjot goes back to how it was that day. Newer entries are set aside first, nothing is lost.")) {
            if snapshots.isEmpty {
                Text(String(localized: "No snapshots yet — the first one is made at the next launch.")).font(DS.F.body).foregroundStyle(DS.C.text3)
            } else {
                ScrollView {
                    SettingsBox {
                        ForEach(snapshots, id: \.url) { s in
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath").font(.system(size: 13)).foregroundStyle(DS.C.brand)
                                Text("\(Fmt.short(LocalDate(s.date, calendar: .current))) \(Fmt.time(s.date))").font(DS.F.mono).foregroundStyle(DS.C.text)
                                Text(ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file)).font(DS.F.caption).foregroundStyle(DS.C.text3)
                                Spacer()
                                Button(String(localized: "Restore…")) { done(); DispatchQueue.main.async { Restore.snapshot(s.url, model: model) } }
                                    .buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: snapshots.count < 7)
            }
        } footer: {
            Button(String(localized: "Done"), action: done).buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
        }
    }
}

/// "Protect the backup with a password" — strength meter, repeat, then the save panel.
private struct ExportBackupDialog: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var password = ""
    @State private var again = ""

    var body: some View {
        let score = Self.strength(password)
        SettingsDialog(title: String(localized: "Protect the backup with a password"),
                       message: String(localized: "You'll need it to open the file on another Mac. tikjot can't recover a forgotten password.")) {
            LabeledField(label: String(localized: "Password")) {
                SettingsTextField(placeholder: "", text: $password, icon: "lock", secure: true)
            }
            // Design strength meter (p6vIvH): four 4 pt segments, radius 2, gap 4, under the field from the start;
            // the word appears once something is typed.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(i < score ? meterColor(score) : DS.C.surface2).frame(height: 4)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: score)
                .accessibilityHidden(true)
                if !password.isEmpty {
                    Text(strengthLabel(score)).font(.system(size: 11, weight: .semibold)).foregroundStyle(score >= 3 ? DS.C.successText : (score == 2 ? DS.C.warningText : DS.C.dangerText))
                }
            }
            LabeledField(label: String(localized: "Repeat password")) {
                SettingsTextField(placeholder: "", text: $again, icon: "lock", secure: true, error: !again.isEmpty && again != password && again.count >= password.count)
            }
            Text(String(localized: "Contains all entries, projects and settings — not your Jira tokens.")).font(DS.F.caption).foregroundStyle(DS.C.text3)
        } footer: {
            Button(String(localized: "Cancel"), action: done).buttonStyle(.pill).keyboardShortcut(.cancelAction)
            Button(action: export) { Label(String(localized: "Export…"), systemImage: "lock") }
                .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                .disabled(password.count < 8 || password != again)
        }
    }

    static func strength(_ p: String) -> Int {
        guard p.count >= 8 else { return p.isEmpty ? 0 : 1 }
        var classes = 0
        if p.contains(where: \.isLowercase) { classes += 1 }
        if p.contains(where: \.isUppercase) { classes += 1 }
        if p.contains(where: \.isNumber) { classes += 1 }
        if p.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        if p.count >= 14 || (p.count >= 10 && classes >= 3) { return p.count >= 16 && classes >= 3 ? 4 : 3 }
        return classes >= 2 ? 2 : 1
    }

    private func meterColor(_ s: Int) -> Color { s >= 3 ? DS.C.success : (s == 2 ? DS.C.warning : DS.C.danger) }

    private func strengthLabel(_ s: Int) -> String {
        if password.count < 8 { return String(localized: "At least 8 characters") }
        switch s {
        case 4: return String(localized: "Very strong")
        case 3: return String(localized: "Strong")
        case 2: return String(localized: "Okay")
        default: return String(localized: "Weak")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tikjot-\(model.today).tikjotbackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            try BackupCodec.export(model.data, password: password, appVersion: v).write(to: url)
            model.lastBackupExport = Clock.now
            model.showToast(String(localized: "Backup saved"))
            done()
        } catch { model.showToast(String(localized: "Backup failed — \(error.localizedDescription)")) }
    }
}

/// "Replace all data with this backup?" — the file, what would be lost, the password.
private struct ImportBackupDialog: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let done: () -> Void
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        let unsent = model.data.groups.filter { $0.deletedAt == nil && ($0.syncState == .unsent || $0.syncState == .modified) }.count
        let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        SettingsDialog(title: String(localized: "Replace all data with this backup?")) {
            HStack(spacing: 12) {
                Image(systemName: "lock.doc").font(.system(size: 18)).foregroundStyle(DS.C.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(DS.C.text).lineLimit(1).truncationMode(.middle)
                    if let d = attrs?.contentModificationDate {
                        Text(String(localized: "made \(Fmt.dayMonthYear(LocalDate(d, calendar: .current))) · \(ByteCountFormatter.string(fromByteCount: Int64(attrs?.fileSize ?? 0), countStyle: .file))"))
                            .font(DS.F.caption).foregroundStyle(DS.C.text3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface2))
            if unsent > 0 {
                DialogWarning(text: String(localized: "This Mac has \(unsent) worklogs not in Jira yet. Send them first, or they'll be lost."))
            }
            LabeledField(label: String(localized: "Backup password")) {
                SettingsTextField(placeholder: "", text: $password, icon: "lock", secure: true, error: error != nil)
            }
            if let error { Text(error).font(DS.F.caption).foregroundStyle(DS.C.dangerText) }
        } footer: {
            Button(String(localized: "Cancel"), action: done).buttonStyle(.pill).keyboardShortcut(.cancelAction)
            Button(String(localized: "Replace data"), action: importBackup).buttonStyle(.dangerPill).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
        }
    }

    private func importBackup() {
        guard let data = try? Data(contentsOf: url) else { error = String(localized: "This file isn't a tikjot backup or is damaged."); return }
        Task { await importBackup(data) }
    }

    private func importBackup(_ data: Data) async {
        do {
            let payload = try BackupCodec.import(data, password: password)
            // Not while a send or refresh is writing: it would put back what the restore just replaced.
            await model.engine.pauseWrites()
            do {
                let before = Set(model.data.instances.map(\.id))
                try model.db.replaceAll(with: payload.data)
                // As the toast says: every connection needs its token again — none stays active from before.
                model.forgetJiraTokens(before.union(payload.data.instances.map(\.id)))
                Restore.reload(model)
                await model.engine.resumeWrites()
            } catch {
                await model.engine.resumeWrites()
                throw error
            }
            model.showToast(String(localized: "Restored — re-enter your Jira tokens in Settings › Jira"))
            done()
        } catch PersistenceError.backupWrongPassword {
            error = String(localized: "That password doesn't open this backup. Try again — capitals count.")
        } catch PersistenceError.backupOutOfRange {
            error = Restore.outOfRangeMessage
        } catch {
            self.error = String(localized: "This file isn't a tikjot backup or is damaged.")
        }
    }
}
