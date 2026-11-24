import AppKit
import SwiftUI

/// Motion tokens (Motion storyboards, SPEC §11.11): UI ≤ 400 ms; default easing = spring (response 0.35,
/// damping 0.8); "ease-out" = cubic(0.2, 0.8, 0.2, 1). Reduce Motion → 120 ms cross-fades only.
enum Motion {
    /// Default UI spring.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    /// Snappier spring for presses and pops (220 ms storyboards A/B, ✓ pop in C).
    static let pressSpring = Animation.spring(response: 0.22, dampingFraction: 0.62)
    /// Storyboard "ease-out": cubic(0.2, 0.8, 0.2, 1).
    static func easeOut(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }
    /// The only motion left with Reduce Motion on.
    static let crossFade = Animation.easeInOut(duration: 0.12)

    /// `animation`, or a 120 ms cross-fade with Reduce Motion.
    static func pick(_ reduceMotion: Bool, _ animation: Animation) -> Animation { reduceMotion ? crossFade : animation }

    /// `withAnimation` that honours Reduce Motion (system setting — usable outside views).
    @MainActor
    static func animate<R>(_ animation: Animation = spring, _ body: () throws -> R) rethrows -> R {
        try withAnimation(pick(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, animation), body)
    }

    /// Storyboard D: "nothing moves while you type" — true while a text field / editor in the key window has focus.
    @MainActor
    static var isTyping: Bool {
        guard let r = NSApp?.keyWindow?.firstResponder else { return false }
        return r is NSTextView || r is NSTextField
    }
}

// MARK: Numbers roll (storyboard D)

/// Only the changed digits roll (old slide up and fade, new slide in from below), tabular figures keep the width.
/// Values swap instantly while the user is typing; Reduce Motion → 120 ms cross-fade.
struct RollingDigits: ViewModifier {
    let value: String
    /// The running clock (changes every second): no roll — see body.
    var short = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if short {
            // The running clock changes every second: rolling it kept a numeric-text animation (with its blur, drawn
            // on the CPU) going all the time — ~40 % CPU with the popover or main window open (2026-10-15), and the
            // likely weight behind the two-monitor hang. The seconds just change, like any clock.
            content.monospacedDigit()
        } else {
            content
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(animation, value: value)
        }
    }

    @MainActor private var animation: Animation? {
        if Motion.isTyping { return nil }
        if reduceMotion { return Motion.crossFade }
        return .spring(response: 0.28, dampingFraction: 0.86)
    }
}

extension View {
    /// Rolls the changed digits of a total when `value` changes (storyboard D).
    func rolls(_ value: String, short: Bool = false) -> some View { modifier(RollingDigits(value: value, short: short)) }

    /// Balance pill (storyboard D · 5): the fill cross-fades amber ↔ green after the roll, 200 ms.
    func signFlip(_ negative: Bool) -> some View {
        animation(Motion.easeOut(0.2).delay(0.28), value: negative)
    }
}

// MARK: Hover & press (2026-10-05: quiet, one system for every custom button)

/// Hover and press for custom (non-pill) buttons: a state layer in the text colour — 6 % on hover, 11 % pressed —
/// in the button's own shape, and a slight press scale on small targets. No lift, no shadow (the timer's Start/Stop
/// squish keeps those). Reduce Motion → no scale. The layer is drawn over the label's own fill, so selected chips and
/// highlighted rows react too.
struct TapButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: DS.R.row, style: .continuous))
    var hover = true
    var pressScale: CGFloat = 1
    /// Icons: a fixed circle (24 pt) around the glyph, whatever its frame — the layout doesn't move.
    var fixedSize: CGFloat?

    static let hoverOpacity = 0.06
    static let pressOpacity = 0.11

    func makeBody(configuration: Configuration) -> some View { TapBody(configuration: configuration, style: self) }

    private struct TapBody: View {
        let configuration: Configuration
        let style: TapButtonStyle
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed && enabled
            let amount = pressed ? TapButtonStyle.pressOpacity : (hovering && style.hover && enabled ? TapButtonStyle.hoverOpacity : 0)
            configuration.label
                .overlay {
                    // Visual only: the icon circle reaches past the glyph and must not take clicks from neighbours.
                    let layer = style.shape.fill(DS.C.text.opacity(amount)).allowsHitTesting(false)
                    if let d = style.fixedSize { layer.frame(width: d, height: d) } else { layer }
                }
                .scaleEffect(reduceMotion || !pressed ? 1 : style.pressScale)
                .animation(Motion.easeOut(0.12), value: hovering)
                .animation(Motion.easeOut(pressed ? 0.06 : 0.16), value: pressed)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == TapButtonStyle {
    /// Icon-only buttons (✕, chevrons, ★): a 24 pt circle on hover, press shrinks to 0.9.
    static var icon: TapButtonStyle { TapButtonStyle(shape: AnyShape(Circle()), pressScale: 0.9, fixedSize: 24) }
    /// List rows, menu options, text buttons: a rounded-rect layer.
    static var row: TapButtonStyle { TapButtonStyle() }
    /// Rows that already show their own hover / keyboard highlight: press only.
    static var rowPress: TapButtonStyle { TapButtonStyle(hover: false) }
    /// Field-like buttons (pop-ups, recorders, tiles).
    static var field: TapButtonStyle { TapButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DS.R.field, style: .continuous))) }
    /// Chips, swatches, day toggles: their capsule / circle, press shrinks to 0.95.
    static var chip: TapButtonStyle { TapButtonStyle(shape: AnyShape(Capsule()), pressScale: 0.95) }
    static var dot: TapButtonStyle { TapButtonStyle(shape: AnyShape(Circle()), pressScale: 0.92) }
    /// Segments and capsule controls that keep their size.
    static var segment: TapButtonStyle { TapButtonStyle(shape: AnyShape(Capsule())) }
}

// MARK: Press squish (storyboards A/B)

/// Timer start / stop buttons: hover lifts (scale 1.04, 4 px shadow, 120 ms ease-out), press squishes to 0.92 and a
/// 2 px ring flashes outwards (+12 px, 0.4 → 0, 260 ms). Reduce Motion → no scale, no ring.
struct SquishButtonStyle: ButtonStyle {
    var ringColor: Color = DS.C.tick
    var shape: AnyShape = AnyShape(Capsule())
    var lift = true

    func makeBody(configuration: Configuration) -> some View {
        SquishBody(configuration: configuration, ringColor: ringColor, shape: shape, lift: lift)
    }

    private struct SquishBody: View {
        let configuration: ButtonStyleConfiguration
        let ringColor: Color
        let shape: AnyShape
        let lift: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        @State private var ring = false

        var body: some View {
            configuration.label
                .background {
                    if !reduceMotion { RingProgress(progress: ring ? 1 : 0, color: ringColor, shape: shape) }
                }
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.92 : (hover && lift && enabled ? 1.04 : 1)))
                .shadow(color: .black.opacity(hover && lift && enabled && !reduceMotion ? 0.14 : 0), radius: 4, y: 2)
                .opacity(enabled ? 1 : 0.45)
                .animation(configuration.isPressed ? Motion.easeOut(0.1) : Motion.pressSpring, value: configuration.isPressed)
                .animation(Motion.easeOut(0.12), value: hover)
                .onHover { hover = $0 }
                .onChange(of: configuration.isPressed) { _, pressed in
                    guard pressed, !reduceMotion else { return }
                    ring = false
                    withAnimation(Motion.easeOut(0.26)) { ring = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ring = false }
                }
        }
    }

    /// The ring: grows 12 px while fading 0.4 → 0 (only visible while it animates).
    private struct RingProgress: View, Animatable {
        var progress: Double
        let color: Color
        let shape: AnyShape
        nonisolated var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }
        var body: some View {
            shape.stroke(color, lineWidth: 2)
                .padding(-12 * progress)
                .opacity(progress > 0 && progress < 1 ? 0.4 * (1 - progress) : 0)
                .allowsHitTesting(false)
        }
    }
}

extension ButtonStyle where Self == SquishButtonStyle {
    static var squish: SquishButtonStyle { SquishButtonStyle() }
    static func squish(ring: Color, shape: some Shape = Capsule(), lift: Bool = true) -> SquishButtonStyle {
        SquishButtonStyle(ringColor: ring, shape: AnyShape(shape), lift: lift)
    }
}

// MARK: Transitions

extension AnyTransition {
    /// Storyboard A/B "slides in (8 px, fade)"; Reduce Motion → fade.
    static func slideFade(_ reduceMotion: Bool, edge: CGFloat = 8) -> AnyTransition {
        reduceMotion ? .opacity : .offset(y: edge).combined(with: .opacity)
    }

    /// ▶ rotates out / ■ rotates in (90°).
    static func rotateFade(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: RotateFade(angle: 90, opacity: 0), identity: RotateFade(angle: 0, opacity: 1))
    }
}

extension AnyTransition {
    /// Storyboard B · 6: a block shrinks away (scale 0.9 from the top + fade). At rest no scale effect is applied,
    /// so the block stays pixel-aligned (a `scaleEffect(1)` would render it at fractional positions).
    static func shrinkAway(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: ShrinkAway(on: true), identity: ShrinkAway(on: false))
    }
}

private struct ShrinkAway: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content.scaleEffect(0.9, anchor: .top).opacity(0)
        } else {
            content
        }
    }
}

private struct RotateFade: ViewModifier {
    let angle: Double
    let opacity: Double
    func body(content: Content) -> some View { content.rotationEffect(.degrees(angle)).opacity(opacity) }
}
