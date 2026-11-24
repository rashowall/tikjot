import AppKit
import SwiftUI
import TikjotDomain

/// Multi-line descriptions (owner 2026-10-22, pen board "Multi-line descriptions · B"): ⇧↩ adds a line in every
/// description field — kept quiet, no hint anywhere. Lists show the first line and a quiet "+N"; hover shows all.

/// One-line view of a description: the first line + "+N" for the lines below, all lines as the tooltip.
struct DescriptionLabel: View {
    let text: String
    var font: Font = DS.F.body
    var color: Color = DS.C.text

    var body: some View {
        let extra = DescriptionLines.extra(text)
        HStack(spacing: 5) {
            Text(extra > 0 ? DescriptionLines.first(text) : text).font(font).foregroundStyle(color).lineLimit(1)
            if extra > 0 { MoreLinesChip(count: extra) }
        }
        .help(extra > 0 ? DescriptionLines.lines(text).joined(separator: "\n") : "")
    }
}

/// "+2": the lines a list leaves out. Outline only, so it reads the same on a card and on a tinted Day block.
struct MoreLinesChip: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(DS.C.text2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(DS.C.borderStrong, lineWidth: 1))
            .fixedSize()
            .accessibilityLabel(String(localized: "\(count) more lines"))
    }
}

extension String {
    /// The first line of a description, for single-line places (sentences, the widget).
    var descriptionFirstLine: String { contains(where: \.isNewline) ? DescriptionLines.first(self) : self }
}

extension View {
    /// ⇧↩ adds a line to a description field; ↩ keeps its job (Start / Done / pick). Not advertised.
    func shiftReturnAddsLine() -> some View {
        onKeyPress(.return, phases: .down) { press in
            guard press.modifiers == .shift else { return .ignored }
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
    }
}
