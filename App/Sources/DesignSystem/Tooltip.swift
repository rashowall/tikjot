import SwiftUI

// MARK: Chart tooltip (owner 2026-10-07: "ours, not generic")

/// What a hover card says: a title ("Thu 1 Oct", "Week 40 · 28 Sep – 4 Oct"), label + value rows (numbers in tabular
/// figures, an optional project-colour dot) and an optional quiet note ("Click to open the day").
struct TooltipContent: Hashable {
    struct Row: Hashable {
        var label: String
        var value: String
        var dot: Color? = nil
        /// The row the card is about (a balance, a total): semibold.
        var strong = false
    }

    var title: String
    var rows: [Row] = []
    var note: String? = nil

    /// The same facts for VoiceOver ("Expected 55h, Worked 54h 13m, …") — hover is never the only way to them.
    var accessibilityValue: String {
        (rows.map { "\($0.label) \($0.value)" } + [note].compactMap { $0 }).joined(separator: ", ")
    }

    var accessibilityText: String { [title, accessibilityValue].filter { !$0.isEmpty }.joined(separator: ", ") }
}

/// tikjot's hover card: surface, 1 pt border, radius 10, soft shadow, 12 × 10 padding; title 11/600, rows
/// label (secondary) + value (tabular, primary). Used by every chart and by the month balance breakdown.
struct ChartTooltip: View {
    let content: TooltipContent
    init(_ content: TooltipContent) { self.content = content }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(content.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text)
                .fixedSize(horizontal: false, vertical: true)
            if !content.rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                        GridRow(alignment: .firstTextBaseline) {
                            HStack(spacing: 6) {
                                if let dot = row.dot { Circle().fill(dot).frame(width: 7, height: 7) }
                                Text(row.label).font(.system(size: 11)).foregroundStyle(DS.C.text2).lineLimit(1)
                            }
                            Text(row.value).font(.system(size: 11, weight: row.strong ? .semibold : .medium).monospacedDigit())
                                .foregroundStyle(DS.C.text)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            if let note = content.note {
                Text(note).font(.system(size: 11)).foregroundStyle(DS.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.C.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.C.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Host & hover

/// When the card appears, moves and goes (owner 2026-10-07: "as if the tooltip travels from one to the other").
/// The card never travels: moving onto another element replaces it in place at once (no fade, no motion);
/// it fades in only when none was shown and fades out only once the pointer has left every element — after a
/// short grace, so crossing the gap between two bars doesn't flicker. Pure, unit tested.
struct TooltipPresence {
    struct Shown: Equatable { let id: AnyHashable; var anchor: CGRect; var content: TooltipContent }

    /// What the host does with a change.
    enum Change: Equatable {
        /// Nothing to draw differently.
        case none
        /// A card where none was: fade in.
        case appear
        /// Another element (or new content / frame): swap in place, no animation.
        case replace
        /// The pointer left the shown element: keep the card for `TooltipCenter.grace`, then `graceEnded()`.
        case startGrace
        /// Gone: fade out.
        case disappear
    }

    private(set) var shown: Shown?
    /// The pointer has left the shown element; the card goes when the grace ends unless an element takes over.
    private(set) var leaving = false

    mutating func show(_ id: AnyHashable, anchor: CGRect, content: TooltipContent) -> Change {
        leaving = false
        let new = Shown(id: id, anchor: anchor, content: content)
        guard let old = shown else { shown = new; return .appear }
        if old == new { return .none }
        shown = new
        return .replace
    }

    mutating func hide(_ id: AnyHashable) -> Change {
        guard shown?.id == id, !leaving else { return .none }
        leaving = true
        return .startGrace
    }

    mutating func graceEnded() -> Change {
        guard leaving else { return .none }
        leaving = false
        shown = nil
        return .disappear
    }
}

/// One tooltip at a time per window: hovered elements hand the host their card and frame; the host draws it above
/// everything (no clipping by cards, rows or scroll views), next to the element, kept inside the window.
@MainActor @Observable
final class TooltipCenter {
    static let space = "tikjot.tooltip"
    /// How long a card stays after the pointer leaves its element (the gaps between bars).
    static let grace: Duration = .milliseconds(100)
    /// The fade on first appearance and when it goes (none with Reduce Motion).
    static let fade = Animation.easeOut(duration: 0.11)

    typealias Shown = TooltipPresence.Shown
    private(set) var presence = TooltipPresence()
    var shown: Shown? { presence.shown }
    /// Set by the host from the system setting: no fades at all.
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private var graceTask: Task<Void, Never>?

    func show(_ id: AnyHashable, anchor: CGRect, content: TooltipContent) {
        graceTask?.cancel(); graceTask = nil
        var p = presence
        apply(p.show(id, anchor: anchor, content: content), p)
    }

    func hide(_ id: AnyHashable) {
        var p = presence
        guard p.hide(id) == .startGrace else { return }
        presence = p
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.grace)
            guard !Task.isCancelled, let self else { return }
            var p = self.presence
            self.apply(p.graceEnded(), p)
        }
    }

    private func apply(_ change: TooltipPresence.Change, _ p: TooltipPresence) {
        switch change {
        case .none, .startGrace:
            if p.leaving != presence.leaving { presence = p }
        case .appear, .disappear:
            withAnimation(reduceMotion ? nil : Self.fade) { presence = p }
        case .replace:
            // Straight to the new place and content: no interpolation, whatever animation is around.
            var t = Transaction(animation: nil)
            t.disablesAnimations = true
            withTransaction(t) { presence = p }
        }
    }
}

private struct TooltipCenterKey: EnvironmentKey {
    static let defaultValue: TooltipCenter? = nil
}

extension EnvironmentValues {
    var tooltipCenter: TooltipCenter? {
        get { self[TooltipCenterKey.self] }
        set { self[TooltipCenterKey.self] = newValue }
    }
}

/// Places the card above the anchor (below when there's no room), centred on it, inside the host with an 8 pt margin.
struct TooltipPlacement: Layout {
    var anchor: CGRect
    var gap: CGFloat = 8
    var margin: CGFloat = 8
    var maxWidth: CGFloat = 300

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let size = card.sizeThatFits(ProposedViewSize(width: min(maxWidth, max(80, bounds.width - 2 * margin)), height: nil))
        let p = Self.origin(card: size, anchor: anchor, in: bounds.size, gap: gap, margin: margin)
        card.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: ProposedViewSize(size))
    }

    /// Top-left corner of a `card` next to `anchor` inside `bounds` (pure, unit tested).
    static func origin(card: CGSize, anchor: CGRect, in bounds: CGSize, gap: CGFloat = 8, margin: CGFloat = 8) -> CGPoint {
        var x = anchor.midX - card.width / 2
        x = min(max(margin, x), max(margin, bounds.width - card.width - margin))
        var y = anchor.minY - gap - card.height
        if y < margin { y = anchor.maxY + gap }   // no room above: below
        if y + card.height > bounds.height - margin { y = max(margin, min(anchor.minY - gap - card.height, bounds.height - card.height - margin)) }
        return CGPoint(x: x, y: y)
    }
}

private struct TooltipHost: ViewModifier {
    @State var center: TooltipCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.tooltipCenter, center)
            .coordinateSpace(.named(TooltipCenter.space))
            .overlay {
                if let s = center.shown {
                    TooltipPlacement(anchor: s.anchor) { ChartTooltip(s.content) }
                        // A new place or content never animates, even inside someone else's animation; only the
                        // whole card fades in and out (`TooltipCenter.apply`).
                        .animation(nil, value: s.anchor)
                        .animation(nil, value: s.content)
                        .transition(.opacity)
                }
            }
            .onChange(of: reduceMotion, initial: true) { _, r in center.reduceMotion = r }
    }
}

private struct TooltipHover: ViewModifier {
    @Environment(\.tooltipCenter) private var center
    let id: AnyHashable
    let content: TooltipContent?
    let accessible: Bool
    @State private var hovering = false

    func body(content view: Content) -> some View {
        let shown = view
            .onHover { inside in
                hovering = inside && content != nil
                if !hovering { center?.hide(id) }
            }
            .background {
                // Only the hovered element measures itself (no geometry work while scrolling past the rest).
                if hovering, let c = content {
                    GeometryReader { g in
                        let frame = g.frame(in: .named(TooltipCenter.space))
                        Color.clear
                            .onAppear { center?.show(id, anchor: frame, content: c) }
                            .onChange(of: frame) { _, f in center?.show(id, anchor: f, content: c) }
                            .onChange(of: c) { _, new in center?.show(id, anchor: frame, content: new) }
                    }
                }
            }
            .onDisappear { center?.hide(id) }
        if accessible, let c = content {
            shown.accessibilityElement(children: .combine)
                .accessibilityLabel(c.title)
                .accessibilityValue(c.accessibilityValue)
        } else {
            shown
        }
    }
}

extension View {
    /// Hosts hover cards for everything inside (a window's root: main window, popover).
    /// `center`: a given one (snapshot tests show a card without hovering).
    func tooltipHost(_ center: TooltipCenter = TooltipCenter()) -> some View { modifier(TooltipHost(center: center)) }

    /// tikjot's hover card for this element (`nil`: none). Shown at once, next to the element; also exposed to
    /// VoiceOver as label + value unless `accessible` is false (the element says it its own way).
    func chartTooltip(_ id: some Hashable, _ content: TooltipContent?, accessible: Bool = true) -> some View {
        modifier(TooltipHover(id: AnyHashable(id), content: content, accessible: accessible))
    }
}
