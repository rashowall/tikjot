import AppKit
import TikjotDomain

/// Single-key shortcuts of the main window (§11.4): ← → T N S M ⌫ ↑ ↓ ⇥ ? — handled by a key monitor
/// that steps aside while a text field is being edited (SwiftUI key equivalents would fire while typing).
@MainActor
final class KeyCommands {
    static let shared = KeyCommands()
    private var monitor: Any?
    private weak var model: AppModel?
    private var showShortcuts: (() -> Void)?

    func install(model: AppModel, showShortcuts: @escaping () -> Void) {
        self.model = model
        self.showShortcuts = showShortcuts
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            nonisolated(unsafe) let ev = e
            let handled = MainActor.assumeIsolated { KeyCommands.shared.handle(ev) }
            return handled ? nil : e
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let model, let window = e.window, window.identifier?.rawValue == "main",
              window.attachedSheet == nil else { return false }
        // Typing somewhere? Let the text field have it.
        if window.firstResponder is NSText || window.firstResponder is NSTextView { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        if mods == .command && model.mainSelection == .day {
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "a": model.selectAllOnDay(); return true
            case "c": if let first = model.selectedEntries.first { model.copyDescription(first); return true }
            default: break
            }
        }
        guard mods.isEmpty else { return false }
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let section = model.mainSelection
        switch (e.keyCode, chars) {
        case (123, _): step(model, -1); return true                     // ←
        case (124, _): step(model, 1); return true                      // →
        case (48, _):                                                   // ⇥ / ⇧⇥ next / previous block
            // Only when no control has keyboard focus, so Full Keyboard Access keeps working.
            guard section == .day, !(window.firstResponder is NSControl) else { return false }
            moveSelection(model, e.modifierFlags.contains(.shift) ? -1 : 1, wrap: true); return true
        case (126, _): moveSelection(model, -1); return section == .day // ↑
        case (125, _): moveSelection(model, 1); return section == .day  // ↓
        case (51, _), (117, _):                                         // ⌫ / ⌦
            guard section == .day, !model.selectedEntryIds.isEmpty, model.lock.canEditEntries(on: model.selectedDay, today: model.today) else { return false }
            model.delete(model.selectedEntries); return true
        case (_, "t"): model.selectedDay = model.today; return true
        case (_, "n"):
            guard section == .day else { return false }
            model.addEntry(on: model.selectedDay); return true
        case (_, "s"):
            guard section == .day, let id = model.selectedEntryIds.first else { return false }
            model.splitRequest = id; return true
        case (_, "m"):
            guard section == .day else { return false }
            model.mergeSelectionWithPrevious(); return true
        case (_, "?"), (_, "/") where e.modifierFlags.contains(.shift):
            showShortcuts?(); return true
        default: return false
        }
    }

    private func step(_ m: AppModel, _ n: Int) {
        switch m.mainSelection {
        case .day: m.selectedDay = m.selectedDay.adding(days: n); m.selectedEntryIds = []
        case .week: m.selectedDay = m.selectedDay.adding(days: 7 * n)
        case .month: m.selectedDay = m.selectedDay.firstOfMonth.adding(months: n)
        default: break
        }
    }

    /// ↑ ↓ move between timeline blocks (§11.4); Tab does the same and wraps around.
    private func moveSelection(_ m: AppModel, _ n: Int, wrap: Bool = false) {
        guard m.mainSelection == .day else { return }
        let es = m.ledger.entries(on: m.selectedDay)
        guard !es.isEmpty else { return }
        let idx = es.firstIndex { m.selectedEntryIds.contains($0.id) }
        let next = idx.map { wrap ? ($0 + n + es.count) % es.count : min(max(0, $0 + n), es.count - 1) } ?? (n > 0 ? 0 : es.count - 1)
        m.selectedEntryIds = [es[next].id]
    }
}

