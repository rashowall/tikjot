import Foundation
import os

/// Local rotating log — never descriptions or tokens (§13 Diagnostics).
enum Log {
    static let logger = Logger(subsystem: "com.tikjot.mac", category: "app")
    private static let queue = DispatchQueue(label: "tikjot.log")

    static func info(_ message: String) { let m = redact(message); write("INFO", m); logger.info("\(m, privacy: .public)") }
    static func error(_ message: String) { let m = redact(message); write("ERROR", m); logger.error("\(m, privacy: .public)") }

    /// Backstop: raw keys (x'…' literals, 64-hex runs) never reach the log, os_log or a diagnostics export.
    static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: "[xX]'[0-9a-fA-F]{32,}'", with: "x'<redacted>'", options: .regularExpression)
            .replacingOccurrences(of: "[0-9a-fA-F]{64,}", with: "<redacted>", options: .regularExpression)
    }

    private static func write(_ level: String, _ message: String) {
        queue.async {
            let url = Paths.logs.appendingPathComponent("tikjot.log")
            let line = "\(ISO8601DateFormatter().string(from: Clock.now)) [\(level)] \(message)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
                    let old = Paths.logs.appendingPathComponent("tikjot.1.log")
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.moveItem(at: url, to: old)
                }
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
