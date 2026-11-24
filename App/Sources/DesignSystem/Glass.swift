import SwiftUI

/// Liquid Glass (SPEC §11.11, design "Liquid Glass" boards): the same binary renders glass on macOS 26 and today's
/// flat look on macOS 14–15. Standard controls (sheets, menus, popovers, the toolbar of a standard window) adopt it
/// by themselves with the macOS 26 SDK; our custom surfaces opt in here, always behind `#available(macOS 26, *)`.
/// Text on glass keeps the semantic token colours; glass is tinted towards the surface colour where it carries
/// content so contrast stays at the flat look's level.
extension View {
    /// macOS 26: a glass surface in `shape` (optionally tinted / interactive). macOS 14–15: the flat `fill` (+ `border`).
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S, fill: Color, border: Color? = nil, tint: Color? = nil,
                                         interactive: Bool = false) -> some View {
        if #available(macOS 26, *), !LiquidGlass.forceFlat {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(shape.fill(fill))
                .overlay { if let border { shape.strokeBorder(border, lineWidth: 1) } }
        }
    }

    @available(macOS 26, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

enum LiquidGlass {
    /// Renders the flat (macOS 14–15) look even on macOS 26. Offscreen rendering (`cacheDisplay` — snapshot tests and
    /// `-capture`) can't draw Liquid Glass (it leaves whole regions blank), so those set this; `-flatLook` in Debug too.
    nonisolated(unsafe) static var forceFlat = LaunchFlags.args.contains("-flatLook") || LaunchFlags.args.contains("-capture")

    /// True when glass is drawn: macOS 26 or later and not forced flat.
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return !forceFlat }
        return false
    }
}
