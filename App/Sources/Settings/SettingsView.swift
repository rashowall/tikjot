import ServiceManagement
import SwiftUI
import TikjotDomain
import TikjotHolidays
import TikjotPersistence
import UserNotifications

/// Settings window (§15, design "Settings · …"): macOS-style toolbar (title + icon tabs) over grouped boxes.
/// General · Jira · Work time · Tracking · Backup. The window grows to fit each tab (scrolls only on small screens).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ViewThatFits(in: .vertical) {
                pane
                ScrollView { pane }
            }
            .frame(maxHeight: Self.maxPaneHeight)
        }
        .frame(width: 720)
        .background(DS.C.bg)
        .background(WindowTitle(title: model.settingsTab.title))
    }

    /// Leaves room for the toolbar and the Dock on the current screen.
    static var maxPaneHeight: CGFloat {
        min(820, max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 140))
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            Text(model.settingsTab.title).font(.system(size: 13, weight: .bold)).foregroundStyle(DS.C.text)
                .frame(maxWidth: .infinity).frame(height: 16)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { t in tab(t) }
            }
        }
        .padding(.top, 7).padding(.bottom, 10).padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(DS.C.surface2)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border).frame(height: 1) }
    }

    private func tab(_ t: SettingsTab) -> some View {
        let on = model.settingsTab == t
        return Button { model.settingsTab = t } label: {
            VStack(spacing: 3) {
                Image(systemName: t.icon).font(.system(size: 15, weight: .regular)).frame(height: 18)
                    .foregroundStyle(on ? DS.C.brand : DS.C.text2)
                Text(t.title).font(.system(size: 11, weight: on ? .bold : .medium)).lineLimit(1).fixedSize()
                    .foregroundStyle(on ? DS.C.text : DS.C.text2)
            }
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? DS.C.text.opacity(0.08) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.row)
        .accessibilityIdentifier("settings.tab.\(t.rawValue)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var pane: some View {
        Group {
            switch model.settingsTab {
            case .general: GeneralSettings()
            case .jira: JiraSettings()
            case .workTime: WorkTimeSettings()
            case .tracking: TrackingSettings()
            case .backup: BackupSettings()
            }
        }
        .padding(.top, 22).padding(.horizontal, 28).padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.content.\(model.settingsTab.rawValue)")
    }
}

/// Debug / captures: `-settingsSheet <name>` opens one of the Settings dialogs right away.
enum SettingsDebug {
    static let sheet: String? = {
        let a = LaunchFlags.args
        guard let i = a.firstIndex(of: "-settingsSheet"), a.indices.contains(i + 1) else { return nil }
        return a[i + 1]
    }()
}

/// Label-left / control-right row used by onboarding (Settings use `SettingsRow`).
struct SettingRow<C: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let control: C
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(DS.F.body)
                if let hint { Text(hint).font(DS.F.caption).foregroundStyle(DS.C.text3).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(width: 260, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
    }
}

// MARK: General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var notificationsOn: Bool?
    @State private var showLicences = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: String(localized: "Startup")) {
                SettingsRow(label: String(localized: "Open tikjot at login")) {
                    SettingsSwitch(label: String(localized: "Open tikjot at login"), isOn: bind(\.launchAtLogin))
                        .onChange(of: model.settings.launchAtLogin) { _, _ in AppDelegate.shared?.services?.applyLaunchAtLogin() }
                }
                // One row: what it shows; "Move to the right" only when the full menu bar hides tikjot.
                SettingsRow(label: String(localized: "Menu bar"),
                            hint: model.menuBarHidden
                                ? String(localized: "Hidden right now — the menu bar is full. Move tikjot to the right end and another icon makes room.")
                                : String(localized: "What the menu bar shows while a timer runs"),
                            hintColor: model.menuBarHidden ? DS.C.warningText : DS.C.text3) {
                    HStack(spacing: 8) {
                        if model.menuBarHidden {
                            Button(String(localized: "Move to the right")) { MenuBarController.shared?.moveToRightEnd() }
                                .buttonStyle(.pill(.secondary, height: DS.H.small))
                        }
                        PillSegmented(selection: bind(\.menuBarShowsTime), options: [(true, String(localized: "Icon + time")), (false, String(localized: "Icon only"))], compact: true)
                    }
                }
            }
            SettingsSection(title: String(localized: "Look & language")) {
                SettingsRow(label: String(localized: "Appearance")) {
                    PillSegmented(selection: bind(\.appearance), options: [("system", String(localized: "System")), ("light", String(localized: "Light")), ("dark", String(localized: "Dark"))], compact: true)
                }
                SettingsRow(label: String(localized: "Language"), hint: String(localized: "tikjot restarts to switch — a running timer keeps running")) {
                    SettingsPopup(selection: Binding(get: { model.settings.language }, set: { v in
                        guard v != model.settings.language else { return }
                        model.updateSettings { $0.language = v }
                        if v == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") } else { UserDefaults.standard.set([v], forKey: "AppleLanguages") }
                        DispatchQueue.main.async { AppRestart.offer() }
                    }), options: [("system", String(localized: "System · \(Locale.preferredLanguages.first?.hasPrefix("sk") == true ? "Slovenčina" : "English")")),
                                  ("en", "English"), ("sk", "Slovenčina")])
                }
            }
            SettingsSection(title: String(localized: "Notifications")) {
                SettingsRow(label: String(localized: "Notifications"),
                            // Blocked in macOS → no reminders at all (no in-app fallback since the simplicity pass).
                            hint: notificationsOn == false ? String(localized: "Reminders need notifications — allow tikjot in System Settings") : String(localized: "Reminders and send failures"),
                            hintColor: notificationsOn == false ? DS.C.warningText : DS.C.text3,
                            link: (String(localized: "Choose reminders…"), { model.settingsTab = .tracking })) {
                    HStack(spacing: 12) {
                        if notificationsOn == false {
                            StatusBadge(text: String(localized: "Off in macOS"), icon: "bell.slash", iconColor: DS.C.warning, fill: DS.C.warningSoft)
                        } else {
                            StatusBadge(text: String(localized: "Allowed"), icon: "checkmark.circle")
                        }
                        Button(String(localized: "System Settings…"), action: openNotificationSettings).buttonStyle(.pill)
                    }
                }
                SettingsRow(label: String(localized: "Sounds"), hint: String(localized: "Tick on start/stop, chime when all is sent")) {
                    SettingsSwitch(label: String(localized: "Sounds"), isOn: bind(\.soundsEnabled))
                }
            }
            SettingsSection(title: String(localized: "About")) {
                SettingsRow(label: "tikjot \(Self.version)", hint: String(localized: "No telemetry, no analytics.")) {
                    // As in the design: a manual check next to the version (Sparkle also checks once a day).
                    Button(String(localized: "Check for updates")) { Updates.checkNow() }
                        .buttonStyle(.pill).disabled(!Updates.available)
                        .help(Updates.available ? "" : String(localized: "Updates are checked in the released app"))
                }
                SettingsRow(label: String(localized: "Help & feedback"), hint: String(localized: "Diagnostics never include descriptions or tokens.")) {
                    HStack(spacing: 14) {
                        Button(String(localized: "Report an issue ↗")) { Diagnostics.reportIssue() }
                        Button(String(localized: "Export diagnostics…")) { Diagnostics.export(model) }
                        Button(String(localized: "Licences")) { showLicences = true }
                    }
                    .buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium).fixedSize()
                }
            }
            .surfaceSheet(isPresented: $showLicences) { LicencesSheet { showLicences = false } }
            // Trademark notice — same wording as the website footer and the README.
            Text(String(localized: "Jira and Atlassian are trademarks of Atlassian. Mac and macOS are trademarks of Apple Inc. tikjot is an independent project, not affiliated with or endorsed by Atlassian or Apple."))
                .font(DS.F.caption).foregroundStyle(DS.C.text3).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            notificationsOn = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        }
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return b.isEmpty || b == v ? v : "\(v) (\(b))"
    }

    private func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    private func bind<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: kp] }, set: { v in model.updateSettings { $0[keyPath: kp] = v } })
    }
}

// MARK: Work time

/// A contract change waiting for "from when?" (design "Settings · Work time · change hours").
struct ContractChange: Identifiable {
    let id = UUID()
    let oldHours: Double
    let newHours: Double
    let oldWorkdays: Set<Int>
    let newWorkdays: Set<Int>
}

struct WorkTimeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var hours = 8.0
    @State private var workdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var start = Clock.now
    @State private var end = Clock.now
    @State private var change: ContractChange?
    @State private var contractTask: Task<Void, Never>?
    @State private var hoursTask: Task<Void, Never>?
    @State private var openingText = ""
    @State private var openingDateOpen = false
    @State private var showDaysOff = false
    @State private var showAbsenceTypes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: String(localized: "Your contract")) {
                SettingsRow(label: String(localized: "Hours per day")) {
                    LengthField(label: "", seconds: Binding(get: { Int(hours * 3600) }, set: { hours = Double($0) / 3600 }), step: 1800, range: 3600...12 * 3600,
                                font: DS.F.monoField) { askContractChange() }
                        .frame(width: 84)
                }
                SettingsRow(label: String(localized: "Workdays")) {
                    HStack(spacing: 4) {
                        ForEach(LocalDate.weekdayOrder, id: \.self) { d in workday(d) }
                    }
                }
                SettingsRow(label: String(localized: "Working hours"), hint: String(localized: "Used for reminders and for placing entries typed into the week grid")) {
                    HStack(spacing: 6) {
                        TimeField(label: "", date: $start, day: model.today, font: DS.F.monoField) { saveWorkingHours() }.frame(width: 84)
                        Text("–").font(DS.F.body).foregroundStyle(DS.C.text3)
                        TimeField(label: "", date: $end, day: model.today, font: DS.F.monoField) { saveWorkingHours() }.frame(width: 84)
                    }
                }
            }
            SettingsSection(title: String(localized: "Calendar")) {
                SettingsRow(label: String(localized: "Public holidays"), hint: upcomingHolidays) {
                    SettingsPopup(selection: Binding(get: { model.settings.holidayCountry }, set: { v in model.updateSettings { $0.holidayCountry = v } }),
                                  options: HolidayEngine.countries(sortedFor: model.language).map { ($0, HolidayEngine.countryName($0, language: model.language)) },
                                  extra: [("NONE", String(localized: "None"))])
                }
                SettingsLinkRow(label: String(localized: "Company days off"), hint: String(localized: "e.g. 24 Dec afternoon, team day"),
                                value: String(localized: "\(model.data.customDays.count) days")) { showDaysOff = true }
                let types = model.data.absenceTypes.filter { !$0.archived }
                SettingsLinkRow(label: String(localized: "Absence types"), hint: types.map(\.name).joined(separator: ", "),
                                value: String(localized: "\(types.count) types")) { showAbsenceTypes = true }
            }
            SettingsSection(title: String(localized: "Balance")) {
                SettingsRow(label: String(localized: "Show balance per")) {
                    PillSegmented(selection: Binding(get: { model.settings.balancePeriod }, set: { v in model.updateSettings { $0.balancePeriod = v } }),
                                  options: [(.week, String(localized: "Week")), (.month, String(localized: "Month")), (.quarter, String(localized: "Quarter"))], compact: true)
                }
                SettingsRow(label: String(localized: "Running balance since"), hint: balanceStartHint.text, hintColor: balanceStartHint.color) {
                    DateFieldButton(date: Binding(get: { model.settings.cumulativeStart ?? model.today.firstOfYear },
                                                  set: { d in model.updateSettings { $0.cumulativeStart = d } }))
                }
                SettingsRow(label: String(localized: "Opening balance"), hint: String(localized: "Carried over from before tikjot"),
                            link: (String(localized: "as of \(Fmt.dayMonthYear(openingDate))"), { openingDateOpen = true })) {
                    TextField("+0h 00m", text: $openingText)
                        .textFieldStyle(.plain).font(DS.F.monoField)
                        .onSubmit(saveOpening)
                        .fieldStyle()
                        .frame(width: 100)
                        .onDisappear(perform: saveOpening)
                }
                .surfacePopover(isPresented: $openingDateOpen, arrowEdge: .bottom) {
                    DateCalendar(selected: openingDate) { d in
                        let secs = model.settings.openingBalance?.seconds ?? 0
                        model.updateSettings { $0.openingBalance = OpeningBalance(date: d, seconds: secs) }
                        openingDateOpen = false
                    }
                }
                SettingsRow(label: String(localized: "Utilization target")) {
                    NumberField(value: Binding(get: { Int((model.settings.utilizationTarget * 100).rounded()) },
                                               set: { v in model.updateSettings { $0.utilizationTarget = Double(v) / 100 } }),
                                range: 10...150, step: 5, unit: "%", width: 84)
                }
            }
        }
        .surfaceSheet(item: $change) { c in
            ContractChangeDialog(change: c) { applied in
                if !applied { hours = model.schedule.current.dailyHours; workdays = model.schedule.current.workdays }
                change = nil
            }
            .environment(model)
        }
        .surfaceSheet(isPresented: $showDaysOff) { CompanyDaysDialog { showDaysOff = false }.environment(model) }
        .surfaceSheet(isPresented: $showAbsenceTypes) { AbsenceTypesDialog { showAbsenceTypes = false }.environment(model) }
        .onAppear {
            let cur = model.schedule.current
            hours = cur.dailyHours
            workdays = cur.workdays
            start = model.today.at(minutes: cur.workdayStart, in: .current)
            end = model.today.at(minutes: cur.workdayEnd, in: .current)
            openingText = model.settings.openingBalance.map { DurationFormat.signed($0.seconds) } ?? ""
            switch SettingsDebug.sheet {
            case "contract": change = ContractChange(oldHours: cur.dailyHours, newHours: 6, oldWorkdays: cur.workdays, newWorkdays: cur.workdays)
            case "daysOff": showDaysOff = true
            case "absenceTypes": showAbsenceTypes = true
            default: break
            }
        }
    }

    private var openingDate: LocalDate { model.settings.openingBalance?.date ?? model.cumulativeStart }

    /// The start that really counts (audit U2): "Counting from 1 Aug — your first data"; amber when the Jira history
    /// starts after the date you chose, so the days in between have nothing to count.
    private var balanceStartHint: (text: String?, color: Color) {
        let configured = model.settings.cumulativeStart
        let history = model.data.instances.filter { $0.deletedAt == nil }.compactMap(\.historyStartDate).min()
        guard BalanceStart.differs(configured: configured, dataStart: model.dataStart, today: model.today) else { return (nil, DS.C.text3) }
        if BalanceStart.importStartsLate(historyStart: history, configured: configured, today: model.today), let h = history {
            return (String(localized: "Counting from \(Fmt.dayMonthYear(model.cumulativeStart)) — your Jira history starts \(Fmt.dayMonthYear(h)). Import earlier history in Settings › Jira, or set an opening balance."), DS.C.warningText)
        }
        return (String(localized: "Counting from \(Fmt.dayMonthYear(model.cumulativeStart)) — your first data"), DS.C.text3)
    }

    private var upcomingHolidays: String? {
        let next = model.holidays.filter { $0.date >= model.today }.prefix(2)
        guard !next.isEmpty else { return nil }
        return String(localized: "Next: \(next.map { "\(Fmt.dayMonth($0.date)) \($0.name)" }.joined(separator: ", "))")
    }

    private func workday(_ d: Int) -> some View {
        let on = workdays.contains(d)
        let date = LocalDate(year: 2026, month: 9, day: 27 + d)
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let letter = Fmt.locale.identifier.hasPrefix("sk") ? String(Fmt.weekdayShort(date).prefix(2)) : symbols[(d % 7)]
        return Button {
            if on { workdays.remove(d) } else { workdays.insert(d) }
            askContractChange()
        } label: {
            Text(letter).font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .foregroundStyle(on ? DS.C.onBrand : DS.C.text3)
                .background(Circle().fill(on ? DS.C.brand : DS.C.surface2))
                .contentShape(Circle())
        }
        .buttonStyle(.dot)
        .accessibilityLabel(Fmt.weekday(date))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Waits a moment (stepper clicks, several weekdays) and then asks from when the new contract counts.
    private func askContractChange() {
        contractTask?.cancel()
        contractTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            let cur = model.schedule.current
            guard hours != cur.dailyHours || workdays != cur.workdays, change == nil else { return }
            change = ContractChange(oldHours: cur.dailyHours, newHours: hours, oldWorkdays: cur.workdays, newWorkdays: workdays)
        }
    }

    private func saveWorkingHours() {
        hoursTask?.cancel()
        hoursTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            let sm = Calendar.current.component(.hour, from: start) * 60 + Calendar.current.component(.minute, from: start)
            let em = Calendar.current.component(.hour, from: end) * 60 + Calendar.current.component(.minute, from: end)
            let cur = model.schedule.current
            guard sm != cur.workdayStart || em != cur.workdayEnd, em > sm else { return }
            var s = model.schedule
            s.change(from: model.today) { $0.workdayStart = sm; $0.workdayEnd = em }
            var c = Changes(); c.upsertSchedule = s.periods
            model.perform("Working hours", c)
        }
    }

    private func saveOpening() {
        let t = openingText.trimmingCharacters(in: .whitespaces)
        let negative = t.hasPrefix("-") || t.hasPrefix("−")
        let body = t.trimmingCharacters(in: CharacterSet(charactersIn: "+-− "))
        let secs = (DurationFormat.parse(body) ?? 0) * (negative ? -1 : 1)
        let date = openingDate
        if secs != (model.settings.openingBalance?.seconds ?? 0) {
            model.updateSettings { $0.openingBalance = secs == 0 ? nil : OpeningBalance(date: date, seconds: secs) }
        }
        openingText = secs == 0 ? "" : DurationFormat.signed(secs)
    }
}

/// "From when should the new hours count?" — next month (usual), today, or a date.
struct ContractChangeDialog: View {
    @Environment(AppModel.self) private var model
    let change: ContractChange
    let done: (Bool) -> Void
    enum When: Hashable { case nextMonth, today, date }
    @State private var when: When = .nextMonth
    @State private var date = LocalDate(Clock.now, calendar: .current)

    var body: some View {
        let hoursChanged = change.newHours != change.oldHours
        let newH = DurationFormat.short(Int(change.newHours * 3600)), oldH = DurationFormat.short(Int(change.oldHours * 3600))
        SettingsDialog(title: hoursChanged ? String(localized: "Hours per day: \(oldH) → \(newH)") : String(localized: "New workdays"),
                       message: hoursChanged ? String(localized: "From when should the new hours count? Earlier days keep \(oldH), so past balances stay right.")
                                             : String(localized: "From when should the new workdays count? Earlier days keep the old ones, so past balances stay right.")) {
            VStack(spacing: 10) {
                option(.nextMonth, String(localized: "From \(Fmt.dayMonthYearLong(model.today.firstOfMonth.adding(months: 1)))"), String(localized: "the start of next month — the usual case"))
                option(.today, String(localized: "From today, \(Fmt.long(model.today))"),
                       hoursChanged ? String(localized: "today's expected hours become \(newH)") : String(localized: "today counts with the new workdays"))
                option(.date, String(localized: "From a date…"), String(localized: "e.g. when a new contract started"))
                if when == .date {
                    HStack { DateFieldButton(date: $date); Spacer() }
                }
            }
        } footer: {
            Button(String(localized: "Cancel")) { done(false) }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
            Button(hoursChanged ? String(localized: "Change to \(newH)") : String(localized: "Change workdays")) { apply() }
                .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
        }
        .onAppear { date = model.today }
    }

    private func option(_ w: When, _ title: String, _ sub: String) -> some View {
        let on = when == w
        return Button { when = w } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 15))
                    .foregroundStyle(on ? DS.C.brand : DS.C.borderStrong)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(on ? DS.F.bodySemibold : DS.F.body).foregroundStyle(DS.C.text)
                    Text(sub).font(DS.F.caption).foregroundStyle(on ? DS.C.text2 : DS.C.text3)   // text3 on brand-soft < 4.5:1
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: DS.R.row).fill(on ? DS.C.brandSoft : DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.row).strokeBorder(on ? DS.C.focusRingStrong : DS.C.border, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func apply() {
        let from: LocalDate
        switch when {
        case .nextMonth: from = model.today.firstOfMonth.adding(months: 1)
        case .today: from = model.today
        case .date: from = date
        }
        var s = model.schedule
        s.change(from: from) { $0.dailyHours = change.newHours; $0.workdays = change.newWorkdays }
        var c = Changes(); c.upsertSchedule = s.periods
        model.perform("Change contract", c, toast: String(localized: "Contract changed"))
        done(true)
    }
}

/// Company days off (design "Settings · Work time · company days off").
struct CompanyDaysDialog: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var adding = false
    @State private var name = ""
    @State private var date = LocalDate(Clock.now, calendar: .current)
    @State private var hours = 0.0

    var body: some View {
        SettingsDialog(title: String(localized: "Company days off"),
                       message: String(localized: "Days your company gives on top of public holidays. They lower the expected hours for everyone in tikjot on this Mac.")) {
            let days = model.data.customDays.sorted { $0.date < $1.date }
            if !days.isEmpty {
                SettingsBox {
                    ForEach(days) { d in
                        // Design row (VVMob): padding 9/12, gap 10; brand calendar 13, name 13 medium, mono 11 date.
                        HStack(spacing: 10) {
                            Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(DS.C.brand)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(DS.F.bodyMedium).foregroundStyle(DS.C.text)
                                Text("\(Fmt.weekdayShort(d.date)) \(Fmt.dayMonthYear(d.date))").font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.C.text3)
                            }
                            Spacer()
                            Text(dayKind(d)).font(.system(size: 12)).foregroundStyle(DS.C.text2)
                            Button { var c = Changes(); c.deleteCustomDays = [d.id]; model.perform("Remove company day", c) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(DS.C.text3).frame(width: 20, height: 20).contentShape(Rectangle())
                            }
                            .buttonStyle(.icon)
                            .accessibilityLabel(String(localized: "Remove \(d.name)"))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                }
            }
            if adding {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        CompanyDayDateField(date: $date)
                        SettingsTextField(placeholder: String(localized: "Name, e.g. Company day"), text: $name)
                    }
                    HStack(spacing: 8) {
                        Text(String(localized: "Work that day (0 = whole day off)")).font(DS.F.body).foregroundStyle(DS.C.text2)
                        LengthField(label: "", seconds: Binding(get: { Int(hours * 3600) }, set: { hours = Double($0) / 3600 }), step: 1800, range: 0...12 * 3600, font: DS.F.monoField)
                            .frame(width: 90)
                        Spacer()
                        Button(String(localized: "Add")) {
                            var c = Changes(); c.upsertCustomDays = [CustomDay(date: date, name: name.trimmingCharacters(in: .whitespaces), hours: hours)]
                            model.perform("Add company day", c)
                            name = ""; hours = 0; adding = false
                        }
                        .buttonStyle(.primaryPill).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } else {
                Button { adding = true } label: { Label(String(localized: "Add a day"), systemImage: "plus") }.buttonStyle(.pill)
            }
        } footer: {
            Button(String(localized: "Done"), action: done).buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
        }
        // The list and "+ Add a day"; the form only once asked for (design HBSg4).
        .onAppear { date = model.today }
    }

    private func dayKind(_ d: CustomDay) -> String {
        if d.hours == 0 { return String(localized: "whole day") }
        let h = DurationFormat.short(Int(d.hours * 3600))
        return d.hours * 2 == model.schedule.period(on: d.date).dailyHours ? String(localized: "half day · \(h)") : String(localized: "\(h) workday")
    }
}

/// The company day's date as the design draws dates (calendar icon, mono "Thu 24 Dec 2026"); the app's month
/// calendar in a popover picks it.
private struct CompanyDayDateField: View {
    @Environment(AppModel.self) private var model
    @Binding var date: LocalDate
    @State private var open = false
    @State private var shown = LocalDate(Clock.now, calendar: .current)

    var body: some View {
        Button { shown = date; open.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(DS.C.text2)
                Text("\(Fmt.weekdayShort(date)) \(Fmt.dayMonthYear(date))").font(DS.F.mono).foregroundStyle(DS.C.text).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: DS.H.field)
            .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(open ? DS.C.focusRingStrong : DS.C.borderStrong, lineWidth: open ? 2 : 1))
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.field)
        .accessibilityLabel(Fmt.dayMonthYear(date))
        .surfacePopover(isPresented: $open, arrowEdge: .bottom) {
            ZStack(alignment: .top) {
                MonthGrid(month: shown, range: DateRange(date, date)) { date = $0; open = false }
                HStack {
                    Button { shown = shown.adding(months: -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.icon)
                    Spacer()
                    Button { shown = shown.adding(months: 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.icon)
                }
            }
            .padding(12)
            .environment(model)
        }
    }
}

/// Absence types: built-ins plus your own; your own can be archived.
struct AbsenceTypesDialog: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var name = ""
    @State private var unit: AbsenceUnit = .day

    var body: some View {
        SettingsDialog(title: String(localized: "Absence types"),
                       message: String(localized: "What you can put on a day instead of work. Add your own, e.g. blood donation.")) {
            SettingsBox {
                ForEach(model.data.absenceTypes.filter { !$0.archived }) { t in
                    HStack(spacing: 12) {
                        Image(systemName: t.icon).font(.system(size: 13)).foregroundStyle(DS.C.brand).frame(width: 18)
                        Text(t.name).font(DS.F.bodyMedium).foregroundStyle(DS.C.text)
                        Text(t.unit == .hours ? String(localized: "in hours") : String(localized: "in days")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                        Spacer()
                        if t.builtin == nil {
                            Button(String(localized: "Archive")) { var x = t; x.archived = true; var c = Changes(); c.upsertAbsenceTypes = [x]; model.applySilently(c) }
                                .buttonStyle(LinkButtonStyle(color: DS.C.text2)).font(DS.F.captionMedium)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                }
            }
            HStack(spacing: 8) {
                SettingsTextField(placeholder: String(localized: "New type, e.g. Blood donation"), text: $name)
                PillSegmented(selection: $unit, options: [(.day, String(localized: "Days")), (.hours, String(localized: "Hours"))], compact: true)
                Button(String(localized: "Add")) {
                    var c = Changes(); c.upsertAbsenceTypes = [AbsenceType(name: name.trimmingCharacters(in: .whitespaces), unit: unit, icon: "calendar.badge.clock")]
                    model.applySilently(c); name = ""
                }
                .buttonStyle(.pill).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            Button(String(localized: "Done"), action: done).buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: Tracking

struct TrackingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let r = model.settings.rounding
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: String(localized: "Rounding for Jira")) {
                SettingsRow(label: String(localized: "Round each task's day to"), hint: String(localized: "Only unsent worklogs change; what's in Jira stays")) {
                    SettingsPopup(selection: Binding(get: { r.unitMinutes }, set: { v in model.updateSettings { $0.rounding.unitMinutes = v } }),
                                  options: RoundingRule.allowedUnits.map { ($0, $0 == 0 ? String(localized: "Off") : "\($0) min") })
                }
                SettingsRow(label: String(localized: "Direction")) {
                    PillSegmented(selection: Binding(get: { r.mode }, set: { v in model.updateSettings { $0.rounding.mode = v } }),
                                  options: [(.nearest, String(localized: "Nearest")), (.up, String(localized: "Up")), (.down, String(localized: "Down"))], compact: true)
                        .disabled(r.unitMinutes == 0).opacity(r.unitMinutes == 0 ? 0.45 : 1)
                }
                Text(r.unitMinutes == 0
                     ? String(localized: "Off: each day is sent to the minute.")
                     : String(localized: "Example: 1h 52m → \(DurationFormat.short(r.apply(112 * 60))) · 2m → \(DurationFormat.short(r.apply(120))) (never 0)"))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(DS.C.text2)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.C.surface2)
            }
            SettingsSection(title: String(localized: "Sending")) {
                SettingsRow(label: String(localized: "Past months stay editable for"), hint: String(localized: "After that, days are locked")) {
                    NumberField(value: bind(\.graceDays), range: 0...28, unit: String(localized: "days"))
                }
                SettingsRow(label: String(localized: "Warn when a description is empty")) {
                    SettingsSwitch(label: String(localized: "Warn when a description is empty"), isOn: bind(\.warnEmptyDescription))
                }
            }
            SettingsSection(title: String(localized: "Reminders")) {
                SettingsRow(label: String(localized: "Nothing's ticking"), hint: String(localized: "After \(model.settings.idleReminderMinutes) min of activity in working hours")) {
                    SettingsSwitch(label: String(localized: "Nothing's ticking"), isOn: bind(\.idleReminderEnabled))
                }
                // Fixed thresholds (3 h, 15 min — BackgroundServices); only the switches are settings.
                SettingsRow(label: String(localized: "Timer running long"), hint: String(localized: "After 3 hours")) {
                    SettingsSwitch(label: String(localized: "Timer running long"), isOn: bind(\.longTimerReminderEnabled))
                }
                SettingsRow(label: String(localized: "Mac slept with a timer running"), hint: String(localized: "Asks when you're back after 15 min or more")) {
                    SettingsSwitch(label: String(localized: "Mac slept with a timer running"),
                                   isOn: Binding(get: { model.sleepPromptEnabled }, set: { model.sleepPromptEnabled = $0 }))
                }
                SettingsRow(label: String(localized: "Days not sent to Jira"), hint: String(localized: "Morning reminder · says when last month locks")) {
                    SettingsSwitch(label: String(localized: "Days not sent to Jira"), isOn: bind(\.unsentReminderEnabled))
                }
                SettingsRow(label: String(localized: "Friday recap")) {
                    SettingsSwitch(label: String(localized: "Friday recap"), isOn: bind(\.fridayRecapEnabled))
                }
            }
            SettingsSection(title: String(localized: "Shortcuts")) {
                SettingsRow(label: String(localized: "Open tikjot"), hint: String(localized: "with the task switcher")) {
                    HotkeyField(value: Binding(get: { model.settings.hotkeyOpen }, set: { v in model.updateSettings { $0.hotkeyOpen = v }; AppDelegate.shared?.services?.registerHotkeys() }))
                }
                SettingsRow(label: String(localized: "Stop / continue")) {
                    HotkeyField(value: Binding(get: { model.settings.hotkeyStop }, set: { v in model.updateSettings { $0.hotkeyStop = v }; AppDelegate.shared?.services?.registerHotkeys() }))
                }
            }
        }
    }

    private func bind<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: kp] }, set: { v in model.updateSettings { $0[keyPath: kp] = v } })
    }
}

/// Click and press a combination (needs ⌘, ⌥ or ⌃ plus a letter or digit). Looks like a `kbd` key.
struct HotkeyField: View {
    @Binding var value: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            // Click-to-record, said on the control (audit copy): the keys, then "Record" / "Cancel".
            HStack(spacing: 8) {
                Text(recording ? String(localized: "Press keys…") : value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(recording ? DS.C.brandText : DS.C.text2)
                    .padding(.horizontal, 7).frame(minWidth: 30, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DS.C.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? DS.C.focusRingStrong : DS.C.border, lineWidth: recording ? 2 : 1))
                Label(recording ? String(localized: "Cancel") : String(localized: "Record"), systemImage: recording ? "xmark" : "record.circle")
                    .font(DS.F.captionMedium).foregroundStyle(DS.C.brandText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.field)
        .help(String(localized: "Click, then press the new shortcut"))
        .accessibilityLabel(recording ? String(localized: "Press keys…") : value)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            var s = ""
            if e.modifierFlags.contains(.control) { s += "⌃" }
            if e.modifierFlags.contains(.option) { s += "⌥" }
            if e.modifierFlags.contains(.shift) { s += "⇧" }
            if e.modifierFlags.contains(.command) { s += "⌘" }
            if let ch = e.charactersIgnoringModifiers?.uppercased().first, ch.isLetter || ch.isNumber,
               e.modifierFlags.intersection([.command, .option, .control]).isEmpty == false {
                value = s + String(ch)
                stop()
                return nil
            }
            if e.keyCode == 53 { stop(); return nil }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

// MARK: Diagnostics

@MainActor
enum Diagnostics {
    /// Exports logs + counts (no descriptions, no tokens).
    static func export(_ model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tikjot-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = "tikjot diagnostics \(Clock.now)\n"
        text += "version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "") macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        text += "entries \(model.data.entries.count) groups \(model.data.groups.count) issues \(model.data.issues.count) projects \(model.data.projects.count)\n"
        text += "instances: " + model.data.instances.map { "\($0.kind.rawValue) \($0.status.rawValue) lastSync \($0.lastSyncAt.map { "\($0)" } ?? "-")" }.joined(separator: "; ") + "\n"
        text += "sync states: " + Dictionary(grouping: model.data.groups, by: \.syncState).map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: " ") + "\n\n"
        for f in ["tikjot.1.log", "tikjot.log"] {
            if let s = try? String(contentsOf: Paths.logs.appendingPathComponent(f), encoding: .utf8) { text += Log.redact(s) }
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func reportIssue() {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let body = "**What happened**\n\n**What you expected**\n\n**Steps**\n\n---\ntikjot \(v) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        var c = URLComponents(string: "https://github.com/rashowall/tikjot/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }
}

/// Settings › About › Open-source licences: tikjot's own licence (GPLv3), then what ships inside tikjot, each with
/// its full licence text (MIT/BSD/OFL require the notice to travel with the binary). The texts are bundled resources:
/// `App/Resources/Licences/*.txt` and the font's `App/Resources/Fonts/OFL.txt`.
struct LicencesSheet: View {
    let done: () -> Void

    struct Item: Identifiable {
        let name: String
        let licence: String
        let purpose: String
        let file: String
        var id: String { name }
    }

    private let items: [Item] = [
        Item(name: "GRDB.swift", licence: "MIT License · © 2015-2025 Gwendal Roué",
             purpose: String(localized: "SQLite toolkit for the encrypted database."), file: "GRDB-MIT"),
        Item(name: "SQLCipher", licence: "BSD-style License · © 2025 Zetetic LLC",
             purpose: String(localized: "AES-256 encryption of the database. Built on SQLite, which is in the public domain."), file: "SQLCipher-BSD"),
        Item(name: "Sparkle", licence: "MIT License · © 2006-2013 Andy Matuschak and others",
             purpose: String(localized: "Checks for new versions of tikjot."), file: "Sparkle-MIT"),
        Item(name: "Bricolage Grotesque", licence: "SIL Open Font License 1.1 · © 2022 The Bricolage Grotesque Project Authors",
             purpose: String(localized: "The display typeface."), file: "OFL"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Open-source licences")).font(DS.F.screenTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("tikjot").font(DS.F.bodySemibold)
                        Text(String(localized: "tikjot is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License v3.0. It comes with ABSOLUTELY NO WARRANTY."))
                            .font(DS.F.caption).foregroundStyle(DS.C.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        // Plain text for now: the repository is private until launch, then this becomes a live link.
                        Text(String(localized: "Source code: github.com/rashowall/tikjot")).font(DS.F.caption).foregroundStyle(DS.C.text2)
                            .textSelection(.enabled)
                        LicenceText(file: "GPL-3.0", title: "GNU General Public License v3.0").padding(.top, 4)
                    }
                    Divider()
                    ForEach(items) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.name).font(DS.F.bodySemibold)
                            Text(i.licence).font(DS.F.caption).foregroundStyle(DS.C.text2)
                            Text(i.purpose).font(DS.F.caption).foregroundStyle(DS.C.text3).fixedSize(horizontal: false, vertical: true)
                            LicenceText(file: i.file, title: String(localized: "Licence text")).padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            .frame(height: 420)
            HStack { Spacer(); Button(String(localized: "Done"), action: done).buttonStyle(.primaryPill).keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 540)
        .background(DS.C.surface)
    }
}

/// One bundled licence text behind a disclosure; expanded, it scrolls in its own box.
struct LicenceText: View {
    let file: String
    let title: String
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Text(title).font(DS.F.captionMedium).foregroundStyle(DS.C.brandText)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.C.brandText)
                }
            }
            .buttonStyle(LinkButtonStyle())
            if expanded {
                ScrollView {
                    Text(text).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(DS.C.text2)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: DS.R.row).fill(DS.C.surface2))
                .overlay(RoundedRectangle(cornerRadius: DS.R.row).strokeBorder(DS.C.border))
            }
        }
    }

    /// The bundled text (`<file>.txt` in the app's resources).
    var text: String {
        Bundle.main.url(forResource: file, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}
