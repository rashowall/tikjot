import AudioToolbox
import Foundation

/// Sound set (Motion storyboards · H, SPEC §11.11) — off by default (Settings › General › Sounds).
///
/// Our own short sounds, synthesised by `scripts/make-sounds.py` into `App/Resources/Sounds/*.caf`
/// (≈ −20 LUFS, < 600 ms, no clipping): tick on start, tock on stop, whoosh + chime when everything was sent,
/// one muted tap when a send fails or a conflict appears (never for reminders).
///
/// Played as system sounds (`AudioServicesPlaySystemSound`), so they follow the **alert volume** and the
/// "Play user interface sound effects" switch, and are silent when the Mac is muted. Focus / Do Not Disturb has no
/// public, permission-free API on macOS 14+ (`INFocusStatusCenter` needs the Communication Notifications
/// entitlement and a permission prompt), so Focus can't be detected reliably; the alert-volume route is the
/// closest we get.
enum Sounds {
    enum Kind { case start, stop, sent, failed }

    /// Storyboard C: the plane takes off 200 ms after the last ✓, the hero lands 800 ms later.
    static let whooshDelay: TimeInterval = 0.2
    static let chimeDelay: TimeInterval = 1.0

    @MainActor
    static func play(_ k: Kind, enabled: Bool) {
        guard enabled else { return }
        switch k {
        case .start: play("tick")
        case .stop: play("tock")
        case .failed: play("tap")
        case .sent:
            DispatchQueue.main.asyncAfter(deadline: .now() + whooshDelay) { play("whoosh") }
            DispatchQueue.main.asyncAfter(deadline: .now() + chimeDelay) { play("chime") }
        }
    }

    // MARK: Players

    @MainActor private static var ids: [String: SystemSoundID] = [:]

    /// Bundle URL of one of our sounds (`nil` if it isn't in the bundle).
    static func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "caf")
            ?? Bundle.main.url(forResource: name, withExtension: "caf", subdirectory: "Sounds")
    }

    @MainActor
    private static func play(_ name: String) {
        if let id = ids[name] {
            AudioServicesPlaySystemSound(id)
            return
        }
        guard let u = url(name) else {
            Log.error("sound \(name).caf missing from the bundle")
            return
        }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(u as CFURL, &id) == kAudioServicesNoError else { return }
        ids[name] = id
        AudioServicesPlaySystemSound(id)
    }
}
