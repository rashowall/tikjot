import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey` (works sandboxed, no Accessibility permission).
/// Defaults: ⌥⌘T open the popover with the task switcher, ⌥⌘S stop / continue last (§11.2).
@MainActor
final class Hotkeys {
    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// Parses "⌥⌘T" style strings.
        init?(_ s: String) {
            var mods: UInt32 = 0
            var key: Character?
            for ch in s {
                switch ch {
                case "⌘": mods |= UInt32(cmdKey)
                case "⌥": mods |= UInt32(optionKey)
                case "⌃": mods |= UInt32(controlKey)
                case "⇧": mods |= UInt32(shiftKey)
                default: key = ch
                }
            }
            guard let key, let code = Combo.keyCodes[Character(key.uppercased())] else { return nil }
            keyCode = code
            modifiers = mods
        }

        static let keyCodes: [Character: UInt32] = [
            "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B), "C": UInt32(kVK_ANSI_C), "D": UInt32(kVK_ANSI_D),
            "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F), "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H),
            "I": UInt32(kVK_ANSI_I), "J": UInt32(kVK_ANSI_J), "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L),
            "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N), "O": UInt32(kVK_ANSI_O), "P": UInt32(kVK_ANSI_P),
            "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R), "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T),
            "U": UInt32(kVK_ANSI_U), "V": UInt32(kVK_ANSI_V), "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X),
            "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z), "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1),
            "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
        ]
    }

    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    nonisolated(unsafe) static var actions: [UInt32: @MainActor @Sendable () -> Void] = [:]

    func register(_ bindings: [(String, @MainActor @Sendable () -> Void)]) {
        unregister()
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                let n = id.id
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.actions[n]?() } }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        for (i, (s, action)) in bindings.enumerated() {
            guard let combo = Combo(s) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x746B6A74), id: UInt32(i + 1)) // 'tkjt'
            if RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr {
                refs.append(ref)
                Hotkeys.actions[UInt32(i + 1)] = action
            }
        }
    }

    func unregister() {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs.removeAll()
        Hotkeys.actions.removeAll()
    }
}
