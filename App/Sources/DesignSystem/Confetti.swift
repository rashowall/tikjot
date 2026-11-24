import AppKit
import SwiftUI

/// A one-off burst of brand-coloured paper (violet, coral, lilac) from the centre of its frame: the day is in Jira
/// (owner 2026-10-07, from the promo video). About two seconds, then nothing. Reduce Motion: not shown.
struct ConfettiBurst: View {
    /// Where the burst starts, in the view's own points (top-left origin); nil = a little above the centre.
    var origin: CGPoint? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    private static let duration: TimeInterval = 2.6
    private static let pieces: [Piece] = {
        var rng = SystemRandomNumberGenerator()
        let colors: [Color] = [DS.C.brand, Color(hex: "#F05072")!, Color(hex: "#B9AEFF")!, Color(hex: "#8E7CFF")!, Color(hex: "#FFB4C3")!]
        return (0..<120).map { i in
            let a = Double.random(in: -172 ... -8, using: &rng) * .pi / 180
            let v = Double.random(in: 380 ... 820, using: &rng)
            return Piece(vx: cos(a) * v, vy: sin(a) * v, spin: Double.random(in: -9 ... 9, using: &rng),
                         flip: Double.random(in: 4 ... 12, using: &rng), size: Double.random(in: 5 ... 9, using: &rng),
                         round: i % 4 == 0, color: colors[i % colors.count], delay: Double.random(in: 0 ... 0.12, using: &rng))
        }
    }()

    struct Piece {
        let vx, vy, spin, flip, size: Double
        let round: Bool
        let color: Color
        let delay: Double
    }

    var body: some View {
        if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation(paused: start.map { Date().timeIntervalSince($0) > Self.duration } ?? false)) { ctx in
                Canvas { g, size in
                    guard let start else { return }
                    let t0 = ctx.date.timeIntervalSince(start)
                    guard t0 < Self.duration else { return }
                    let origin = self.origin ?? CGPoint(x: size.width / 2, y: size.height * 0.55)
                    for p in Self.pieces {
                        let t = t0 - p.delay
                        guard t > 0 else { continue }
                        // Air drag on the launch, gravity pulling down, a little sideways sway.
                        let k = 1.8
                        let drag = (1 - exp(-k * t)) / k
                        let x = origin.x + p.vx * drag + sin(t * 3 + p.spin) * 8
                        let y = origin.y + p.vy * drag + 300 * t * t
                        let fade = max(0, min(1, (Self.duration - t0) / 0.6))
                        var c = g
                        c.opacity = fade
                        c.translateBy(x: x, y: y)
                        c.rotate(by: .radians(p.spin * t))
                        let w = p.size * abs(cos(t * p.flip)) + 1   // paper flipping
                        let r = CGRect(x: -w / 2, y: -p.size * 0.7, width: w, height: p.size * (p.round ? 1 : 1.4))
                        c.fill(p.round ? Path(ellipseIn: r) : Path(r), with: .color(p.color))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { start = Date() }
        }
    }
}

/// Lets the burst fly past the edges of the sheet it celebrates: a transparent, click-through window over the
/// screen point, gone after the burst.
@MainActor
enum ConfettiOverlay {
    private static var window: NSWindow?

    private static var last = Date.distantPast

    static func burst(at p: NSPoint) {
        // One burst per moment, even if the view reporting the point is rebuilt.
        guard Date().timeIntervalSince(last) > 3 else { return }
        last = Date()
        // The whole screen, so the paper falls past the window's bottom edge instead of being cut off mid-air.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main else { return }
        let f = screen.frame
        let w = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false   // a panel hides with its app otherwise
        w.level = .popUpMenu   // above the sheet, which re-orders itself to the front as it updates
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.transient, .ignoresCycle]
        w.contentView = NSHostingView(rootView: ConfettiBurst(origin: CGPoint(x: p.x - f.minX, y: f.maxY - p.y)).frame(width: f.width, height: f.height))
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) { [weak w] in
            w?.close()
            if window === w { window = nil }
        }
    }
}

/// Reports where a SwiftUI view sits on screen (its centre), once it is in a window.
struct ScreenCentre: NSViewRepresentable {
    let onPlace: (NSPoint) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // A moment later: the sheet settles to its result size first, which moves the view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let w = v.window else { return }
            let r = w.convertToScreen(v.convert(v.bounds, to: nil))
            onPlace(NSPoint(x: r.midX, y: r.midY))
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
