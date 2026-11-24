import SwiftUI
import TikjotDomain

/// Design tokens from `design/handoff/tokens.json` (colours live in Colors.xcassets with light/dark).
enum DS {
    enum C {
        static let tick = Color("tick")
        static let tickSoft = Color("tick-soft")
        static let tickText = Color("tick-text")
        static let bg = Color("bg")
        static let surface = Color("surface")
        static let surface2 = Color("surface-2")
        static let border = Color("border")
        static let borderStrong = Color("border-strong")
        static let text = Color("text-primary")
        static let text2 = Color("text-secondary")
        static let text3 = Color("text-tertiary")
        static let success = Color("success")
        static let successSoft = Color("success-soft")
        static let warning = Color("warning")
        static let warningSoft = Color("warning-soft")
        static let danger = Color("danger")
        static let dangerSoft = Color("danger-soft")
        static let brand = Color("brand")
        static let brandSoft = Color("brand-soft")
        static let brandText = Color("brand-text")
        static let onBrand = Color("on-brand")
        static let onTick = Color("on-tick")
        static let focusRing = Color("focus-ring")
        static let ringOvertime = Color("ring-overtime")
        // Text-safe (WCAG AA 4.5:1) versions of the signal colours — signals stay for dots, edges, rings, icons.
        static let warningText = Color("warning-text")
        static let dangerText = Color("danger-text")
        static let successText = Color("success-text")
        /// Coral fill that carries text (running time pill, stop) + its content colour.
        static let tickStrong = Color("tick-strong")
        static let onTickStrong = Color("on-tick-strong")
        static let tickOnWhite = Color("tick-on-white")
        static let focusRingStrong = Color("focus-ring-strong")
        /// Inverse bubbles (tooltips, toasts on text-primary).
        static let inverseSecondary = Color("inverse-secondary")
        static let warningInverse = Color("warning-inverse")
        static let successInverse = Color("success-inverse")
        static let brandInverse = Color("brand-inverse")
    }

    enum R {
        static let row: CGFloat = 8
        static let field: CGFloat = 9
        static let card: CGFloat = 14
        static let window: CGFloat = 18
    }

    enum H {
        static let small: CGFloat = 24
        static let regular: CGFloat = 30
        static let field: CGFloat = 32
        static let hero: CGFloat = 44
    }

    enum S {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
    }

    enum F {
        static let caption = Font.system(size: 11)
        static let captionMedium = Font.system(size: 11, weight: .medium)
        static let body = Font.system(size: 13)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let bodySemibold = Font.system(size: 13, weight: .semibold)
        static let title = Font.system(size: 15, weight: .semibold)
        /// Brand display face (design `$font-display`, bundled, OFL) — screen titles, popover moments, onboarding.
        static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
            Font.custom("Bricolage Grotesque", size: size).weight(weight)
        }
        static let header = display(17, .heavy)
        static let screenTitle = display(20, .bold)
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoMedium = Font.system(size: 12, weight: .medium, design: .monospaced)
        static let monoBig = Font.system(size: 15, weight: .semibold, design: .monospaced)
        static let monoHero = Font.system(size: 17, weight: .bold, design: .monospaced)
        static let sectionLabel = Font.system(size: 10, weight: .semibold, design: .monospaced)
        /// The one Jira-key style (TaskTag, KeyName, popover, review, unsent…): mono 11/600 in `keyColor`.
        static let key = Font.system(size: 11, weight: .semibold, design: .monospaced)
        static let keyColor = DS.C.text2
        /// Large numbers (KPI cards, totals): SF Pro with tabular digits — mono stays for durations in rows.
        static func number(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { Font.system(size: size, weight: weight).monospacedDigit() }
    }

    static func project(_ name: String) -> Color {
        if name.hasPrefix("#") { return Color(hex: name) ?? Color("project-slate") }
        return ProjectPalette.names.contains(name) ? Color("project-\(name)") : Color("project-slate")
    }

    static func projectTint(_ name: String) -> Color {
        if name.hasPrefix("#") { return (Color(hex: name) ?? .gray).opacity(0.16) }
        return ProjectPalette.names.contains(name) ? Color("project-\(name)-tint") : Color("project-slate-tint")
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
