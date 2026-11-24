import SwiftUI

// Shared by the app and the widget.

/// The tikjot logo mark — the exact tick and coral dot of `logo/mark` in the design file (256 × 256 artboard:
/// tick filled + 9.44 round-joined stroke at 14.7, 77.0 · 191.2 × 147.7; dot ⌀ 42.5 at 203.5, 26.6).
struct LogoTick: View {
    var size: CGFloat = 16
    var color: Color = Color("brand")
    var dotColor: Color = Color("tick")

    var body: some View {
        let u = size / 256
        ZStack(alignment: .topLeading) {
            LogoTickShape().fill(color)
                .overlay(LogoTickShape().stroke(color, style: StrokeStyle(lineWidth: 9.44 * u, lineJoin: .round)))
                .frame(width: 191.22 * u, height: 147.73 * u)
                .offset(x: 14.72 * u, y: 76.99 * u)
            Circle().fill(dotColor)
                .frame(width: 42.49 * u, height: 42.49 * u)
                .offset(x: 203.51 * u, y: 26.56 * u)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The logo's tick as a shape (path data copied from the design), scaled to fill its rect.
struct LogoTickShape: Shape {
    private static let base = SVGPath.parse("M5.82401 60.032c-2.744-3.528-5.82401-8.34399-5.82401-12.76799 0-8.12001 6.72-13.04802 14.22401-13.04802 6.60799 0 12.82399 5.04001 18.76 10.64001 7.896 7.504 16.352 16.408 21.55999 21 2.74399 2.51999 5.6 1.73599 7.952-0.89599 10.47202-11.98401 31.36-36.84801 40.88-47.60001 5.88-6.664 20.272-17.36 26.37601-17.36 5.48801 0 9.12799 3.91999 9.12799 8.96 0 3.02399-1.45599 5.824-3.41601 8.344-17.13598 23.12799-37.79998 54.20799-54.376 74.92799-7 8.84801-15.79199 15.064-25.14399 15.064-9.01599 0-16.744-6.496-23.632-14.896-8.512-10.472-18.03201-21.952-26.48799-32.36799z")

    func path(in rect: CGRect) -> Path {
        let b = Self.base.boundingRect
        guard b.width > 0, b.height > 0 else { return Self.base }
        let t = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / b.width, y: rect.height / b.height)
            .translatedBy(x: -b.minX, y: -b.minY)
        return Self.base.applying(t)
    }
}

/// Minimal SVG path-data reader (M/m, L/l, H/h, V/v, C/c, Z/z) — enough for artwork copied from the design file.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var p = Path()
        var tokens: [String] = []
        var num = ""
        func flush() { if !num.isEmpty { tokens.append(num); num = "" } }
        for ch in d {
            if ch.isLetter && ch != "e" { flush(); tokens.append(String(ch)) }
            else if ch == "-" && !num.isEmpty && num.last != "e" { flush(); num = "-" }
            else if ch == " " || ch == "," { flush() }
            else if ch == "." && num.contains(".") { flush(); num = "." }
            else { num.append(ch) }
        }
        flush()
        var i = 0, cmd = "M", cur = CGPoint.zero, start = CGPoint.zero
        func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter { cmd = tokens[i]; i += 1; if cmd == "Z" || cmd == "z" { p.closeSubpath(); cur = start; continue } }
            let rel = cmd == cmd.lowercased()
            let o = rel ? cur : .zero
            switch cmd.uppercased() {
            case "M":
                cur = CGPoint(x: o.x + n(), y: o.y + n()); start = cur; p.move(to: cur); cmd = rel ? "l" : "L"
            case "L": cur = CGPoint(x: o.x + n(), y: o.y + n()); p.addLine(to: cur)
            case "H": cur = CGPoint(x: (rel ? cur.x : 0) + n(), y: cur.y); p.addLine(to: cur)
            case "V": cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + n()); p.addLine(to: cur)
            case "C":
                let c1 = CGPoint(x: o.x + n(), y: o.y + n()), c2 = CGPoint(x: o.x + n(), y: o.y + n())
                cur = CGPoint(x: o.x + n(), y: o.y + n())
                p.addCurve(to: cur, control1: c1, control2: c2)
            default: i += 1
            }
        }
        return p
    }
}
