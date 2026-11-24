import AppKit

/// A click outside the text field you're typing in ends the editing, like in Finder or Notes
/// (owner 2026-10-07: "I can't click out of the description"). The click itself still goes where it was aimed;
/// fields save on losing focus. The popover keeps its own focus rules (its lists react to focus).
@MainActor
enum ClickAway {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            guard let w = e.window, !String(describing: type(of: w)).contains("Popover"),
                  let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView, field.window === w else { return e }
            if !field.bounds.contains(field.convert(e.locationInWindow, from: nil)) { w.makeFirstResponder(nil) }
            return e
        }
    }
}
