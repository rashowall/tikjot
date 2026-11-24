import AppKit
import SwiftUI
import TikjotDomain

// "One visual language" (SPEC §11.8): edge = time · dot = task · pill = action/state · card = group.

// MARK: Pills (buttons)

enum PillKind { case primary, secondary, danger, quiet, tick }

struct PillButtonStyle: ButtonStyle {
    var kind: PillKind = .secondary
    var height: CGFloat = DS.H.regular
    /// Toolbar pills become glass capsules on macOS 26 (primary = tinted glass); flat elsewhere.
    var glass = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, style: self, enabled: enabled)
    }

    /// Hover: a 6 % state layer in the label colour (+ border-strong on outlined pills); press: 11 % and 0.97.
    private struct PillBody: View {
        let configuration: Configuration
        let style: PillButtonStyle
        let enabled: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed && enabled
            let hover = hovering && enabled
            let amount = pressed ? TapButtonStyle.pressOpacity : (hover ? TapButtonStyle.hoverOpacity : 0)
            let outlined = style.kind == .secondary || style.kind == .danger
            configuration.label
                .font(style.height >= DS.H.hero ? DS.F.title : DS.F.bodyMedium)
                .lineLimit(1)
                .padding(.horizontal, style.height >= DS.H.hero ? 18 : 12)
                .frame(height: style.height)
                .foregroundStyle(style.foreground)
                .modifier(PillSurface(glass: style.glass && LiquidGlass.isAvailable, fill: style.background,
                                      border: outlined && hover ? DS.C.borderStrong : style.border,
                                      tint: style.kind == .primary || style.kind == .tick ? style.background : nil))
                .overlay(Capsule().fill(style.foreground.opacity(amount)).allowsHitTesting(false))
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .contentShape(Capsule())
                .animation(Motion.easeOut(0.12), value: hovering)
                .animation(Motion.easeOut(pressed ? 0.06 : 0.16), value: pressed)
                .onHover { hovering = $0 }
        }
    }

    private struct PillSurface: ViewModifier {
        let glass: Bool
        let fill: Color
        let border: Color
        let tint: Color?
        func body(content: Content) -> some View {
            if glass {
                content.glassSurface(Capsule(), fill: fill, border: border, tint: tint, interactive: true)
            } else {
                content.capsuleSurface(fill, border: border)
            }
        }
    }

    /// The same pill as a glass capsule on macOS 26.
    var glassy: PillButtonStyle {
        var s = self
        s.glass = true
        return s
    }

    fileprivate var foreground: Color {
        switch kind {
        case .primary: return DS.C.onBrand
        case .secondary, .quiet: return DS.C.text
        case .danger: return DS.C.dangerText
        case .tick: return DS.C.onTickStrong
        }
    }

    fileprivate var background: Color {
        switch kind {
        case .primary: return DS.C.brand
        case .secondary: return DS.C.surface
        case .quiet: return DS.C.surface2
        case .danger: return DS.C.surface
        case .tick: return DS.C.tickStrong
        }
    }

    fileprivate var border: Color {
        switch kind {
        // Label identifies the button (WCAG ok); with macOS “Increase contrast” the outline gets 3:1 too.
        case .secondary: return contrast == .increased ? DS.C.borderStrong : DS.C.border
        case .danger: return DS.C.border   // design: Delete is a secondary button with a danger label (VsabB)
        default: return .clear
        }
    }
}

extension View {
    /// A bordered capsule the way the pills draw it: fill + content clipped to the capsule, the border as an inset
    /// stroke on top — no stray vertical edges at the round ends (`strokeBorder` over a separate fill can leave some).
    /// `clip: false` keeps effects that reach past the edge (the Start / Stop ring flash) and only draws the surface.
    /// `radius`: a capsule that may grow taller (a multi-line description) keeps this corner instead of turning
    /// into a stadium; at its normal height (2 × radius) it is the same capsule.
    @ViewBuilder
    func capsuleSurface(_ fill: Color, border: Color, lineWidth: CGFloat = 1, clip: Bool = true, radius: CGFloat? = nil) -> some View {
        if let radius {
            let shape = RoundedRectangle(cornerRadius: radius, style: .circular)   // continuous corners at half the height draw stray straight bits at the sides (#61)
            let stroke = shape.inset(by: lineWidth / 2).stroke(border, lineWidth: lineWidth)
            if clip {
                background(shape.fill(fill)).clipShape(shape).overlay(stroke)
            } else {
                background(shape.fill(fill)).overlay(stroke)
            }
        } else {
            let stroke = Capsule().inset(by: lineWidth / 2).stroke(border, lineWidth: lineWidth)
            if clip {
                background(Capsule().fill(fill)).clipShape(Capsule()).overlay(stroke)
            } else {
                background(Capsule().fill(fill)).overlay(stroke)
            }
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var primaryPill: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var quietPill: PillButtonStyle { PillButtonStyle(kind: .quiet) }
    static var dangerPill: PillButtonStyle { PillButtonStyle(kind: .danger) }
    static func pill(_ kind: PillKind, height: CGFloat = DS.H.regular) -> PillButtonStyle { PillButtonStyle(kind: kind, height: height) }
}

/// Plain text button that looks like a link.
/// Hover underlines it, press dims it.
struct LinkButtonStyle: ButtonStyle {
    var color: Color = DS.C.brandText
    func makeBody(configuration: Configuration) -> some View { LinkBody(configuration: configuration, color: color) }

    private struct LinkBody: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .underline(hovering && enabled)
                .foregroundStyle(color)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .animation(Motion.easeOut(0.1), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: Card

struct Card<Content: View>: View {
    var padding: CGFloat = DS.S.s3
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border, lineWidth: 1))
    }
}

/// Grey info well (radius 14).
struct Well<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(DS.S.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface2))
    }
}

// MARK: Task tag — always `● KEY Name`, never a bare key (§11.8)

struct TaskTag: View {
    let key: String?
    let name: String
    let color: String
    var font: Font = DS.F.caption
    var muted = false
    /// On a selected (brand-soft) row the name is secondary text — tertiary is under 4.5:1 there.
    var selected = false
    /// ⌘ held over it: key and name read as a link to Jira (beta 2026-10-25).
    var link = false

    var body: some View {
        // Key + name while at least a bit of the name fits; otherwise the key alone (a very long key shortens in
        // the middle) — never a one-letter sliver of the name, never pushing the time pill out (e.g. PAY_PLATFORM-5).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                dot
                if let key { keyText(key).fixedSize() }
                Text(name).font(font).foregroundStyle(nameColor).underline(link).lineLimit(1).truncationMode(.tail)
                    // idealWidth keeps ViewThatFits from demanding the whole name; the name still fills what's left.
                    .frame(minWidth: key == nil ? 0 : 44, idealWidth: 44, maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 5) {
                dot
                if let key { keyText(key).lineLimit(1).truncationMode(.middle) }
                else { Text(name).font(font).foregroundStyle(nameColor).lineLimit(1).truncationMode(.tail) }
            }
        }
        .help(key.map { "\($0) \(name)" } ?? name)
        .accessibilityElement(children: .combine)
    }

    private var nameColor: Color { link ? DS.C.brandText : selected ? DS.C.text2 : DS.C.text3 }
    private var dot: some View { Circle().fill(DS.project(color)).frame(width: 7, height: 7) }

    private func keyText(_ key: String) -> Text {
        Text(key).font(DS.F.key).foregroundColor(link ? DS.C.brandText : muted ? nameColor : DS.F.keyColor).underline(link)
    }
}

/// Jira key + task name on one line. The key never wraps; the name shortens first. When even a short name
/// doesn't fit next to the key, the name moves under it (`stacked`) or — where the height is fixed — the key
/// stands alone and shortens in the middle (e.g. PAY_PLATFORM-5, OPS_INFRA_UPGRADE-880).
struct KeyName: View {
    let key: String
    let name: String
    // One key style everywhere (DS.F.key: mono 11/600 text-secondary); name 12/500.
    var keyFont: Font = DS.F.key
    var keyColor: Color = DS.F.keyColor
    var nameFont: Font = .system(size: 12, weight: .medium)
    var nameColor: Color = DS.C.text
    var spacing: CGFloat = 6
    /// The narrowest the name may get beside the key.
    var minName: CGFloat = 80
    var stacked = true
    /// ⌘ held over it: key and name read as a link to Jira (beta 2026-10-25).
    var link = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                keyText.fixedSize()
                nameText.frame(minWidth: minName, idealWidth: minName, maxWidth: .infinity, alignment: .leading)
            }
            if stacked {
                VStack(alignment: .leading, spacing: 1) {
                    keyText.lineLimit(1).truncationMode(.middle)
                    nameText
                }
            } else {
                keyText.lineLimit(1).truncationMode(.middle)
            }
        }
        .help("\(key) \(name)")
    }

    private var keyText: some View { Text(key).font(keyFont).foregroundStyle(link ? DS.C.brandText : keyColor).underline(link) }
    private var nameText: some View {
        Text(name).font(nameFont).foregroundStyle(link ? DS.C.brandText : nameColor).underline(link).lineLimit(1).truncationMode(.tail)
    }
}

/// The design's checkbox (`checkbox` dfqMS): 16 pt, radius 4, surface + border-strong; on = brand with a white tick.
struct BrandCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(configuration.isOn ? DS.C.brand : DS.C.surface)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(configuration.isOn ? DS.C.brand : DS.C.borderStrong, lineWidth: 1))
                .overlay { if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.C.onBrand) } }
                .frame(width: 16, height: 16)
                // 24 pt hit target around the 16 pt box without changing the layout.
                .padding(4).contentShape(Rectangle()).padding(-4)
        }
        .buttonStyle(.dot)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == BrandCheckboxStyle {
    static var brandCheckbox: BrandCheckboxStyle { BrandCheckboxStyle() }
}

/// "No task yet" mark — the design's lucide link-2-off (a link with a slash), in the warning colour.
struct NoTaskMark: View {
    var size: CGFloat = 12
    var color: Color = DS.C.warning
    var body: some View {
        Image(systemName: "link").font(.system(size: size * 0.85, weight: .semibold)).foregroundStyle(color)
            .overlay {
                Path { p in p.move(to: CGPoint(x: size * 0.1, y: size * 0.1)); p.addLine(to: CGPoint(x: size * 0.9, y: size * 0.9)) }
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    .frame(width: size, height: size)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(String(localized: "No task"))
    }
}

/// `balance/pill` (i4ZFqj): trend icon + signed balance on a soft amber / green capsule.
struct BalancePill: View {
    let text: String
    let negative: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: negative ? "arrow.down.right" : "arrow.up.right").font(.system(size: 10, weight: .bold))
                .foregroundStyle(negative ? DS.C.warning : DS.C.success)
            Text(text).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(DS.C.text).rolls(text)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 10).fill(negative ? DS.C.warningSoft : DS.C.successSoft))
        .signFlip(negative)
        .fixedSize()
    }
}

/// Thin project-colour edge (edge = time): 3 pt, round ends.
struct TimeEdge: View {
    let color: Color
    var body: some View {
        Capsule().fill(color).frame(width: 3)
    }
}

// MARK: Section label

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(DS.F.sectionLabel).foregroundStyle(DS.C.text3).kerning(0.6)
    }
}

// MARK: Chips & states

/// Text on a tint is always ink; a signal colour goes on the icon (`iconColor`) — "ink + signal".
struct Chip: View {
    let text: String
    var color: Color = DS.C.text2
    var fill: Color = DS.C.surface2
    var icon: String?
    var iconColor: Color?
    /// Leads with the one no-task mark instead of an SF Symbol.
    var noTask = false
    var body: some View {
        HStack(spacing: 4) {
            if noTask { NoTaskMark(size: 10) }
            else if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(iconColor ?? color) }
            Text(text).font(DS.F.captionMedium).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: DS.H.small - 2)
        .foregroundStyle(color)
        .background(Capsule().fill(fill))
    }
}

/// The Unsent badge (board "Unsent badge · colour exploration", variant V1 "brand solid", decided 2026-10-06): the
/// days not in Jira yet as a calm grey count; a solid brand pill with an on-brand number — the same number — when
/// something needs you. Nothing at 0 days. Sidebar only — the popover stays without a count (2026-10-06).
struct UnsentCountBadge: View {
    let badge: UnsentBadge
    /// The calm pill's fill (it has to stand out from what it sits on).
    var calmFill: Color = DS.C.surface2

    var body: some View {
        if !badge.isHidden {
            HStack(spacing: 3) {
                Text("\(badge.count)").font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(numberColor)
            }
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16, maxHeight: 16)
            .background(Capsule().fill(pillFill))
            .help(Self.text(badge))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.text(badge))
        }
    }

    private var numberColor: Color {
        guard badge.needsYou else { return DS.C.text2 }
        return DS.C.onBrand
    }

    private var pillFill: Color {
        guard badge.needsYou else { return calmFill }
        return DS.C.brand
    }

    /// "3 days not in Jira" (+ "· something needs you").
    static func text(_ b: UnsentBadge) -> String {
        String(localized: "\(b.count) days not in Jira") + (b.needsYou ? " · " + String(localized: "something needs you") : "")
    }
}

/// Amber "needs you" dot.
struct NeedsYouDot: View {
    var size: CGFloat = 6
    var body: some View { Circle().fill(DS.C.warning).frame(width: size, height: size) }
}

/// Quiet state mark (✓ / ! / ⇄ / lock) used in rows, week cells, month ledger. Amber is kept for days that need
/// you (nothing tracked); "not sent yet" is a calm dashed circle. Every mark carries a tooltip — never colour alone.
struct StateMark: View {
    let status: DayStatus
    var body: some View {
        switch status {
        case .allInJira:
            // Design: lucide circle-check in $success.
            mark(Image(systemName: "checkmark.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.success))
        case .waiting:
            mark(Image(systemName: "circle.dashed").font(.system(size: 10)).foregroundStyle(DS.C.text3))
        case .failed:
            mark(Image(systemName: "exclamationmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(DS.C.danger))
        case .conflict:
            mark(Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.C.danger))
        case .locked:
            mark(Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(DS.C.text3))
        case .missed:
            mark(Image(systemName: "exclamationmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(DS.C.warning))
        case .none:
            EmptyView()
        }
    }

    private func mark(_ v: some View) -> some View {
        let label = status.label ?? ""
        return v.frame(minWidth: 12, minHeight: 12).contentShape(Rectangle()).help(label).accessibilityLabel(label)
    }
}

extension DayStatus {
    /// The words for the mark — its tooltip, and what VoiceOver reads in a row or cell (§14).
    var label: String? {
        switch self {
        case .allInJira: String(localized: "In Jira")
        case .waiting: String(localized: "Not in Jira yet")
        case .failed: String(localized: "Failed")
        case .conflict: String(localized: "Changed in Jira and here")
        case .locked: String(localized: "Locked")
        case .missed: String(localized: "Nothing tracked")
        case .none: nil
        }
    }
}

// MARK: Day ring (§11.1 "Day ring")

struct DayRing: View {
    let worked: Seconds
    let fund: Seconds
    var allInJira = false
    var dayOff = false
    var size: CGFloat = 40
    var lineWidth: CGFloat = 4
    var showLabel = true

    var body: some View {
        let frac = fund > 0 ? Double(worked) / Double(fund) : (worked > 0 ? 1 : 0)
        ZStack {
            // Design `popover/header` › Ring (rj0WN/a6uvh): track = border, ring 18 % of the radius.
            Circle().inset(by: lineWidth / 2).stroke(dayOff ? DS.C.surface2 : DS.C.border, lineWidth: lineWidth)
            Circle().inset(by: lineWidth / 2).trim(from: 0, to: allInJira ? 1 : min(1, frac))
                .stroke(allInJira ? DS.C.success : DS.C.brand, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if frac > 1 && !allInJira {
                Circle().inset(by: lineWidth / 2).trim(from: 0, to: min(1, frac - 1))
                    .stroke(DS.C.ringOvertime, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if showLabel {
                if allInJira {
                    // Sent: the full logo mark (tick + coral dot) at 55 % of the ring, as in the design (xpzd3).
                    LogoTick(size: size * 0.554, color: DS.C.success)
                } else {
                    VStack(spacing: 0) {
                        let label = fund > 0 || worked > 0 ? DurationFormat.clock(worked) : "0h"
                        Text(label)
                            .font(.system(size: size * 10 / 52, weight: .bold, design: .monospaced))
                            .foregroundStyle(DS.C.text)
                            .rolls(label)
                        if worked > fund && fund > 0 {
                            Text(DurationFormat.overClock(worked - fund))
                                .font(.system(size: size * 0.18, weight: .semibold, design: .monospaced))
                                .foregroundStyle(DS.C.successText)
                        }
                    }
                    .minimumScaleFactor(0.6)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Today \(DurationFormat.hm(worked)) of \(DurationFormat.hm(fund))")
    }
}

// MARK: Coral time pill: time zone | stop zone

struct TimePill: View {
    let elapsed: Seconds
    var showSeconds = true
    var compact = false
    var timeAction: (() -> Void)?
    /// Storyboard A · 4: on a fresh start ■ rotates in (90°) as the fill turns coral.
    var justStarted = false
    let stop: () -> Void
    @State private var hoverTime = false
    @State private var iconAngle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { timeAction?() }) {
                HStack(spacing: 3) {
                    let clock = DurationFormat.clock(elapsed, seconds: showSeconds)
                    // Design: running capsule fOBs2 (mono 16/700) · capsule/mini NcnmY (mono 12.5/700).
                    Text(clock)
                        .font(.system(size: compact ? 12.5 : 16, weight: .bold, design: .monospaced))
                        .lineLimit(1).fixedSize()   // never wraps while the pill morphs out of the Start button
                        .rolls(clock, short: true)
                    if hoverTime && timeAction != nil && !compact {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                }
                .padding(.leading, compact ? 9 : 16)
                .padding(.trailing, compact ? 6 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(timeAction == nil)
            .onHover { hoverTime = $0 }
            // White hairline and a white-tinted stop zone in both themes (design #FFFFFF55 / #FFFFFF26).
            Rectangle().fill(Color.white.opacity(0.33)).frame(width: 1, height: compact ? 16 : 20)
            Button(action: stop) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2).strokeBorder(DS.C.onTickStrong, lineWidth: 1.6).frame(width: compact ? 9 : 12, height: compact ? 9 : 12)
                        .rotationEffect(.degrees(iconAngle))
                }
                .frame(width: compact ? 24 : 36, height: compact ? 24 : 36)
                .padding(.leading, 2).padding(.trailing, compact ? 3 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            // Storyboard B · 2: ■ squishes to 0.92 (same as start) with the ring flash.
            .buttonStyle(.squish(ring: DS.C.onTickStrong, shape: Circle(), lift: false))
            .help("Stop · ⌥⌘S")
            .accessibilityLabel("Stop timer")
        }
        .foregroundStyle(DS.C.onTickStrong)
        .frame(height: compact ? 30 : 44)
        .background(Capsule().fill(DS.C.tickStrong))
        .onAppear {
            guard justStarted, !reduceMotion else { return }
            iconAngle = -90
            withAnimation(Motion.spring.delay(0.1)) { iconAngle = 0 }
        }
    }
}

// MARK: Illustrations

struct Illustration: View {
    let name: String
    var width: CGFloat
    var animated = true
    /// Loops played on appear (≤ 3 per Motion storyboards · G).
    var loops = 3
    var body: some View {
        Image(name).resizable().scaledToFit().frame(width: width)
            .modifier(IllustrationMotion(kind: animated ? IllustrationMotion.kind(for: name) : .none, loops: loops))
            .accessibilityHidden(true)
    }
}

/// Illustration loops (Motion storyboards · G): the whole illustration moves gently — plays on appear,
/// one loop ≤ 2 s, at most 3×, then rests at its normal pose. Reduce Motion → static.
/// (Per-part motion — the mug yawning, the plane drawing its trail — needs layered artwork / Rive later.)
struct IllustrationMotion: ViewModifier {
    enum Kind { case none, float, breathe, sway, pop }
    let kind: Kind
    var loops = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    @State private var appeared = false

    static func kind(for name: String) -> Kind {
        let n = name.lowercased()
        if n.contains("senthero") || n.contains("sentsmall") || n.contains("weekdone") || n.contains("onboardsend") { return .pop }
        if n.contains("offline") || n.contains("signedout") || n.contains("lockeddata") || n.contains("nojira") || n.contains("growing") { return .breathe }
        if n.contains("missed") || n.contains("permissions") || n.contains("doctor") || n.contains("restore") || n.contains("sentpartly") { return .sway }
        return .float
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .bottom)
            .rotationEffect(.degrees(rotation), anchor: .bottom)
            .offset(y: offsetY)
            .task {
                guard kind != .none, !reduceMotion else { appeared = true; return }
                if kind == .pop {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { appeared = true }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                } else {
                    appeared = true
                }
                // One loop = there and back (≤ 2 s); 3 loops, then rest.
                for _ in 0..<min(3, max(0, loops)) {
                    if Task.isCancelled { return }
                    withAnimation(.easeInOut(duration: 0.95)) { phase = true }
                    try? await Task.sleep(nanoseconds: 950_000_000)
                    withAnimation(.easeInOut(duration: 0.95)) { phase = false }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
    }

    private var scale: CGFloat {
        switch kind {
        case .pop: return (appeared ? 1 : 0.94) * (phase ? 1.015 : 1)
        case .breathe: return phase ? 1.03 : 1
        default: return 1
        }
    }

    private var rotation: Double { kind == .sway ? (phase ? 2.5 : -1) : 0 }

    private var offsetY: CGFloat {
        switch kind {
        case .float, .pop: return phase ? -3 : 0
        default: return 0
        }
    }
}

// MARK: Fields

struct FieldBackground: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            // A multi-line description grows the box; one line stays at the field height.
            .padding(.vertical, 6)
            .frame(minHeight: DS.H.field)
            .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(focused ? DS.C.focusRingStrong : DS.C.borderStrong, lineWidth: focused ? 2 : 1))
    }
}

extension View {
    func fieldStyle(focused: Bool = false) -> some View { modifier(FieldBackground(focused: focused)) }

    /// A click anywhere in a field's box — padding, unit, empty space — puts the cursor in it, not only a click on
    /// the text itself (beta 2026-10-21: "5 days" took focus only on the digit). Apply after the field's frame.
    func clickToFocus(_ focus: FocusState<Bool>.Binding) -> some View {
        contentShape(RoundedRectangle(cornerRadius: DS.R.field)).onTapGesture { focus.wrappedValue = true }
    }

    /// Fades content that isn't being edited (§11.1: "the rest fades to 28 %").
    func faded(_ on: Bool) -> some View { opacity(on ? 0.28 : 1).allowsHitTesting(!on).animation(.easeOut(duration: 0.18), value: on) }
}

/// Keyboard hint like `⌘K`.
struct Kbd: View {
    let text: String
    var body: some View {
        // Design `kbd` (Yy0y8 / QLeLW): mono 11, padding 1/5, radius 5, surface-2, no border.
        Text(text).font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(DS.C.text2)
            .padding(.horizontal, 5).padding(.vertical, 1).frame(minWidth: 17)
            .background(RoundedRectangle(cornerRadius: 5).fill(DS.C.surface2))
    }
}

/// Diagonal stripes for absences (`pattern/hatch`).
struct Hatch: View {
    var color: Color = DS.C.brand.opacity(0.13)
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            let step: CGFloat = 7
            var x: CGFloat = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            ctx.stroke(p, with: .color(color), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// Segmented control as a pill track with pill thumbs (Visual language).
struct PillSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    /// Settings rows: the 26 pt `segmented` of the design (22 pt thumbs, selected label semibold).
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = o.0 } } label: {
                    Text(o.1).font(compact && selection == o.0 ? DS.F.bodySemibold : DS.F.bodyMedium).lineLimit(1).fixedSize()
                        .foregroundStyle(selection == o.0 ? DS.C.text : DS.C.text2)
                        .padding(.horizontal, 12).frame(height: compact ? 22 : 26)
                        .background(Capsule().fill(selection == o.0 ? DS.C.surface : .clear).shadow(color: .black.opacity(selection == o.0 ? 0.08 : 0), radius: 2, y: 1))
                        .overlay(Capsule().inset(by: 0.5).stroke(selection == o.0 ? DS.C.borderStrong : .clear, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(TapButtonStyle(shape: AnyShape(Capsule()), hover: selection != o.0))
                .accessibilityAddTraits(selection == o.0 ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.C.surface2))
    }
}

// Sheets and popovers on the app's surface (design), not the system's grey — on that grey, tiles, segments and cards
// that sit on surface-2 disappear in dark mode (owner 2026-10-08). Use these instead of .sheet / .popover.
extension View {
    func surfaceSheet<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        sheet(isPresented: isPresented) { content().presentationBackground(DS.C.surface) }
    }
    func surfaceSheet<I: Identifiable, C: View>(item: Binding<I?>, @ViewBuilder content: @escaping (I) -> C) -> some View {
        sheet(item: item) { content($0).presentationBackground(DS.C.surface) }
    }
    func surfacePopover<C: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .top, @ViewBuilder content: @escaping () -> C) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) { content().presentationBackground(DS.C.surface) }
    }
}

/// Beta 2026-10-25: follows ⌘ while the pointer is over a task, so the task can read as a link to Jira (⌘-click
/// opens it; a plain click keeps doing what it did).
struct CommandHover: ViewModifier {
    @Binding var active: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    if monitor == nil {
                        let binding = $active
                        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
                            binding.wrappedValue = e.modifierFlags.contains(.command); return e
                        }
                    }
                } else {
                    stop()
                }
                active = inside && NSEvent.modifierFlags.contains(.command)
            }
            .onDisappear { stop(); active = false }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    func commandHover(_ active: Binding<Bool>) -> some View { modifier(CommandHover(active: active)) }
}
