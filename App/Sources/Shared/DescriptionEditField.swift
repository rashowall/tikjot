import SwiftUI
import TikjotDomain
import TikjotSuggestions

/// The description field of an existing entry (popover card, Day inspector) with the same list of earlier entries
/// as "What are you working on?": a pick takes that description and its task (owner 2026-10-07).
struct DescriptionEditField: View {
    @Environment(AppModel.self) private var model
    let placeholder: String
    @Binding var text: String
    let entry: TimeEntry
    var focused: FocusState<Bool>.Binding
    /// Highlighted row; the owner turns its own ↩ shortcut off while one is highlighted.
    @Binding var highlighted: Int?
    var locked = false
    var focusedStyle = false
    var identifier = "entry.description"
    /// The field grows with a multi-line description up to this many lines, then scrolls (owner 2026-10-22).
    var maxLines = 6
    /// ↩ with no row highlighted.
    var submit: () -> Void = {}
    let pick: (DescriptionSuggestions.Suggestion) -> Void

    @State private var listUp = false
    @State private var listHover = false

    private var items: [DescriptionSuggestions.Suggestion] {
        model.descriptionSuggestions(text, limit: text.isEmpty ? 4 : 5)
            .filter { !($0.description == entry.description && $0.issueId == entry.issueId) }
    }

    private var multi: Bool { text.contains(where: \.isNewline) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...maxLines)
                .textFieldStyle(.plain).fieldStyle(focused: focusedStyle)
                .focused(focused)
                .disabled(locked)
                .accessibilityIdentifier(identifier)
                // With several lines the arrows move the caret between them.
                .onKeyPress(.downArrow) { if multi { return .ignored }; move(1); return .handled }
                .onKeyPress(.upArrow) { if multi { return .ignored }; move(-1); return .handled }
                .onKeyPress(.escape) { if highlighted != nil { highlighted = nil; return .handled }; if listUp { listUp = false; return .handled }; return .ignored }
                .onSubmit { if let i = highlighted, items.indices.contains(i) { choose(items[i]) } else { submit() } }
                .shiftReturnAddsLine()
                .onChange(of: text) { _, _ in highlighted = nil }
                .onChange(of: focused.wrappedValue) { _, f in
                    if f { listUp = true } else {
                        // A moment later, and not while the pointer is on the list, so a click on a row lands.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if !focused.wrappedValue && !listHover { listUp = false; highlighted = nil } }
                    }
                }
            // A second line makes it your own text: the earlier entries step aside.
            if listUp && !locked && !multi && !items.isEmpty {
                DescriptionSuggestionList(query: text, items: items, highlighted: highlighted,
                                          footer: String(localized: "↑↓ choose · ↩ use"), showNew: false,
                                          pick: choose, startNew: {})
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
                    .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border, lineWidth: 1))
                    .onHover { h in
                        listHover = h
                        if !h && !focused.wrappedValue { listUp = false; highlighted = nil }
                    }
                    .transition(.opacity)
            }
        }
    }

    private func move(_ d: Int) {
        let n = items.count
        guard n > 0 else { return }
        listUp = true
        if let i = highlighted { let j = i + d; highlighted = j < 0 ? nil : min(j, n - 1) } else if d > 0 { highlighted = 0 }
    }

    private func choose(_ s: DescriptionSuggestions.Suggestion) {
        text = s.description
        listUp = false; listHover = false; highlighted = nil
        pick(s)
    }
}
