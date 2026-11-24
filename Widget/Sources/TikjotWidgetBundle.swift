import AppIntents
import SwiftUI
import WidgetKit

/// Widgets (§11.5) are built from the popover parts: capsule/mini, popover/entry, ring rules, small illustrations.
/// They never open the database — the app writes a snapshot to the App Group; buttons signal the app.
@main
struct TikjotWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "today", provider: Provider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(for: .widget) { Color("surface") }
                .widgetURL(URL(string: "tikjot://day"))
        }
        .configurationDisplayName("tikjot")
        .description(String(localized: "Today against your day, what's running, one tap to stop or continue."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SnapEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SnapEntry { SnapEntry(date: Date(), snap: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (SnapEntry) -> Void) {
        completion(SnapEntry(date: Date(), snap: context.isPreview ? .placeholder : (WidgetBridge.read() ?? .placeholder)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapEntry>) -> Void) {
        let s = WidgetBridge.read() ?? .placeholder
        // Refresh every 5 minutes so "worked today" moves while a timer runs.
        let entries = (0..<12).map { i in SnapEntry(date: Date().addingTimeInterval(Double(i) * 300), snap: s) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: Intents (run in the widget, signal the app)

struct StopTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop timer"
    // Widget button only — not offered to Shortcuts / Spotlight / Siri.
    static var isDiscoverable: Bool { false }
    func perform() async throws -> some IntentResult {
        WidgetBridge.send("stop")
        return .result()
    }
}

struct ContinueTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue last task"
    static var isDiscoverable: Bool { false }
    func perform() async throws -> some IntentResult {
        WidgetBridge.send("continue")
        return .result()
    }
}

// MARK: Views

struct WidgetView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.widgetRenderingMode) var renderingMode
    let entry: SnapEntry

    var s: WidgetSnapshot { entry.snap }

    /// Worked today including the running timer up to now.
    var worked: Int {
        guard s.running != nil else { return s.worked }
        return s.worked + max(0, Int(entry.date.timeIntervalSince(s.generatedAt)))
    }

    var body: some View {
        if s.signedOut && s.running == nil && family == .systemSmall {
            signedOut
        } else if let off = s.dayOff, off != "weekend", s.running == nil, s.worked == 0 || off == "doctor" {
            dayOff(off)
        } else {
            switch family {
            case .systemMedium: medium
            case .systemLarge: large
            default: small
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TODAY").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color("text-tertiary"))
                Spacer()
                Text(s.dayTitle.prefix(3)).font(.system(size: 10)).foregroundStyle(Color("text-tertiary"))
            }
            HStack { Spacer(); ring(size: 74); Spacer() }
            if let r = s.running {
                HStack(spacing: 4) {
                    Circle().fill(projectColor(r.color)).frame(width: 6, height: 6)
                    Text(r.key ?? r.taskName).font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 2)
                    Button(intent: StopTimerIntent()) {
                        HStack(spacing: 4) {
                            Text(r.start, style: .timer).font(.system(size: 10, weight: .semibold, design: .monospaced)).monospacedDigit()
                                .frame(maxWidth: 38)
                            Image(systemName: "stop.fill").font(.system(size: 7))
                        }
                        .padding(.horizontal, 7).frame(height: 20)
                        .foregroundStyle(renderingMode == .fullColor ? Color("on-tick-strong") : .white)
                        .background(Capsule().fill(renderingMode == .fullColor ? Color("tick-strong") : .white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Stop \(r.key ?? r.taskName)"))
                }
            } else if let last = s.lastTask, s.worked > 0 {
                Button(intent: ContinueTimerIntent()) {
                    Label(last.key ?? last.taskName, systemImage: "play.fill").font(.system(size: 10, weight: .semibold))
                        .lineLimit(1).frame(maxWidth: .infinity).frame(height: 22)
                        .foregroundStyle(Color("on-brand")).background(Capsule().fill(Color("brand")))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Continue \(last.key ?? last.taskName)"))
            } else {
                Text("Yesterday \(hm(s.yesterdayWorked))").font(.system(size: 10)).foregroundStyle(Color("text-secondary"))
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            ring(size: 92)
            VStack(alignment: .leading, spacing: 6) {
                if let r = s.running {
                    Text("RUNNING").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color("text-tertiary"))
                    Text(r.description.isEmpty ? r.taskName : r.description).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    taskLine(r.key, r.taskName, r.color)
                    HStack(spacing: 8) {
                        Button(intent: StopTimerIntent()) {
                            HStack(spacing: 6) {
                                Text(r.start, style: .timer).font(.system(size: 15, weight: .bold, design: .monospaced)).monospacedDigit()
                                Image(systemName: "stop.fill").font(.system(size: 9))
                            }
                            .padding(.horizontal, 12).frame(height: 32)
                            .foregroundStyle(renderingMode == .fullColor ? Color("on-tick-strong") : .white)
                            .background(Capsule().fill(renderingMode == .fullColor ? Color("tick-strong") : .white.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Stop \(r.key ?? r.taskName)"))
                        Link(destination: URL(string: "tikjot://switch")!) {
                            Label("Switch", systemImage: "arrow.left.arrow.right").font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10).frame(height: 26).background(Capsule().fill(Color("surface-2")))
                        }
                    }
                } else {
                    Text(s.dayTitle).font(.system(size: 14, weight: .bold))
                    Text("\(hm(s.worked)) of \(hm(s.fund))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color("text-secondary"))
                    if let last = s.lastTask {
                        Button(intent: ContinueTimerIntent()) {
                            Label("Continue \(last.key ?? last.taskName)", systemImage: "play.fill").font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).padding(.horizontal, 12).frame(height: 28)
                                .foregroundStyle(Color("on-brand")).background(Capsule().fill(Color("brand")))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.dayTitle).font(.system(size: 14, weight: .bold))
                Spacer()
                Text("\(clock(worked)) / \(hm(s.fund))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color("text-secondary"))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color("surface-2"))
                    Capsule().fill(Color("brand")).frame(width: g.size.width * min(1, CGFloat(worked) / CGFloat(max(1, s.fund))))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            if let r = s.running {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.description.isEmpty ? r.taskName : r.description).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        taskLine(r.key, r.taskName, r.color)
                    }
                    Spacer()
                    Button(intent: StopTimerIntent()) {
                        HStack(spacing: 4) {
                            Text(r.start, style: .timer).font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit().frame(maxWidth: 52)
                            Image(systemName: "stop.fill").font(.system(size: 8))
                        }
                        .padding(.horizontal, 9).frame(height: 24).foregroundStyle(Color("on-tick-strong")).background(Capsule().fill(Color("tick-strong")))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Stop \(r.key ?? r.taskName)"))
                }
                .padding(8).background(Capsule().fill(Color("tick-soft")))
            }
            ForEach(Array(s.rows.reversed().prefix(5).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Capsule().fill(projectColor(row.color)).frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.description.isEmpty ? row.taskName : row.description).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        taskLine(row.key, row.taskName, row.color)
                    }
                    Spacer()
                    if row.end == nil {
                        Text("\(time(row.start))–now").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color("tick-text"))
                    } else {
                        Text(hm(row.seconds)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color("text-secondary"))
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            HStack {
                if s.unsentDays > 0 {
                    Text("\(s.unsentDays) days not in Jira").font(.system(size: 11, weight: .medium)).foregroundStyle(Color("tick-text"))
                }
                Spacer()
                Link("Review & send", destination: URL(string: "tikjot://review")!).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color("brand-text"))
            }
        }
    }

    private func ring(size: CGFloat) -> some View {
        let w = worked
        let frac = s.fund > 0 ? Double(w) / Double(s.fund) : 0
        return ZStack {
            Circle().stroke(Color("brand-soft"), lineWidth: size * 0.085)
            if s.allInJira {
                Circle().stroke(Color("success"), lineWidth: size * 0.085)
                LogoTick(size: size * 0.5, color: Color("success"))
            } else {
                Circle().trim(from: 0, to: min(1, frac)).stroke(Color("brand"), style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round)).rotationEffect(.degrees(-90))
                if frac > 1 {
                    Circle().trim(from: 0, to: min(1, frac - 1)).stroke(Color("ring-overtime"), style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(clock(w)).font(.system(size: size * 0.22, weight: .semibold, design: .monospaced))
                    if w > s.fund && s.fund > 0 {
                        Text("+\(clock(w - s.fund))").font(.system(size: size * 0.13, weight: .semibold, design: .monospaced)).foregroundStyle(Color("success-text"))
                    } else {
                        Text("of \(hm(s.fund))").font(.system(size: size * 0.12)).foregroundStyle(Color("text-tertiary"))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        // The ring as words (§14): its colours and the tick aren't the only way to "done" or "overtime".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.allInJira ? Text("Worked \(hm(w)) of \(hm(s.fund)), all in Jira") : Text("Worked \(hm(w)) of \(hm(s.fund))"))
    }

    private func dayOff(_ kind: String) -> some View {
        let ill: String
        switch kind {
        case "sickLeave": ill = "illSickDaySmall"
        case "childCare": ill = "illChildCareSmall"
        case "holiday": ill = "illHolidaySmall"
        case "weekend": ill = "illWeekendSmall"
        case "doctor": ill = "illDoctorSmall"
        default: ill = "illVacationSmall"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Image(ill).resizable().scaledToFit().frame(height: 64).accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(kind == "doctor" ? "At the doctor" : (s.dayOffText ?? "Day off")).font(.system(size: 13, weight: .bold)).lineLimit(1)
            if kind == "doctor", let t = s.dayOffText { Text(t).font(.system(size: 10)).foregroundStyle(Color("text-secondary")) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "key").font(.system(size: 22)).foregroundStyle(Color("tick-text")).accessibilityHidden(true)
            Spacer()
            Text("Sign in to Jira").font(.system(size: 13, weight: .bold))
            Text("Tracking still works").font(.system(size: 10)).foregroundStyle(Color("text-secondary"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "tikjot://settings"))
    }

    private func taskLine(_ key: String?, _ name: String, _ color: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(projectColor(color)).frame(width: 5, height: 5)
            if let key { Text(key).font(.system(size: 9, weight: .medium, design: .monospaced)) }
            Text(name).font(.system(size: 10)).foregroundStyle(Color("text-tertiary")).lineLimit(1)
        }
    }

    private func projectColor(_ name: String) -> Color {
        if name.hasPrefix("#") { return Color(hexString: name) }
        return Color("project-\(name)")
    }

    // Same rules as DurationFormat.short: "42m", "1h 5m", "8h" — never "0h 42m".
    private func hm(_ s: Int) -> String { let m = abs(s) / 60; return m < 60 ? "\(m)m" : (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m") }
    private func clock(_ s: Int) -> String { String(format: "%d:%02d", max(0, s) / 3600, (max(0, s) % 3600) / 60) }
    private func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

extension Color {
    init(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
