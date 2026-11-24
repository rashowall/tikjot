import Foundation
import TikjotDomain

/// §9.3 — one line in total → plain text; ≥ 2 → bullet list, one point per line (Cloud: ADF `bulletList`, DC: wiki
/// `* item`).
public enum CommentRenderer {
    public static func plain(_ descriptions: [String]) -> String { DescriptionLines.comment(descriptions) }

    /// Lines of a plain comment: bullet items or paragraphs.
    static func items(fromPlain text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            var s = String(line).trimmingCharacters(in: .whitespaces)
            for prefix in ["• ", "* ", "- "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
            return s
        }.filter { !$0.isEmpty }
    }

    static func isBulletList(_ text: String) -> Bool {
        let lines = text.split(separator: "\n")
        return lines.count >= 2 && lines.allSatisfy { $0.hasPrefix("• ") }
    }

    // MARK: Cloud (ADF)

    public static func adf(_ text: String) -> [String: Any] {
        var content: [[String: Any]] = []
        if text.isEmpty {
            content = []
        } else if isBulletList(text) {
            content = [[
                "type": "bulletList",
                "content": items(fromPlain: text).map { item in
                    ["type": "listItem", "content": [["type": "paragraph", "content": [["type": "text", "text": item]]]]]
                },
            ]]
        } else {
            content = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.isEmpty ? ["type": "paragraph"] : ["type": "paragraph", "content": [["type": "text", "text": String(line)]]]
            }
        }
        return ["type": "doc", "version": 1, "content": content]
    }

    /// ADF → plain text: paragraphs on lines, list items as "• item".
    public static func plain(fromADF node: Any?) -> String {
        guard let doc = node as? [String: Any] else {
            if let s = node as? String { return s }
            return ""
        }
        var lines: [String] = []
        func text(of n: [String: Any]) -> String {
            if let t = n["text"] as? String { return t }
            if (n["type"] as? String) == "hardBreak" { return " " }
            if (n["type"] as? String) == "mention", let a = n["attrs"] as? [String: Any] { return (a["text"] as? String) ?? "" }
            return ((n["content"] as? [[String: Any]]) ?? []).map(text).joined()
        }
        func walk(_ n: [String: Any], bullet: Bool) {
            let type = n["type"] as? String ?? ""
            switch type {
            case "paragraph", "heading":
                let t = text(of: n).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines.append(bullet ? "• \(t)" : t) }
            case "bulletList", "orderedList":
                for item in (n["content"] as? [[String: Any]]) ?? [] { walk(item, bullet: true) }
            case "listItem":
                let t = ((n["content"] as? [[String: Any]]) ?? []).map(text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines.append("• \(t)") }
            default:
                for c in (n["content"] as? [[String: Any]]) ?? [] { walk(c, bullet: bullet) }
            }
        }
        walk(doc, bullet: false)
        return lines.joined(separator: "\n")
    }

    // MARK: DC (wiki markup)

    public static func wiki(_ text: String) -> String {
        if isBulletList(text) {
            return items(fromPlain: text).map { "* \($0)" }.joined(separator: "\n")
        }
        return text
    }

    public static func plain(fromWiki text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count >= 2 && lines.allSatisfy({ $0.hasPrefix("* ") || $0.hasPrefix("- ") }) {
            return lines.map { "• " + $0.dropFirst(2) }.joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A comment turned into an entry description (imported worklogs): bullet items joined with "; ".
    public static func description(fromPlain text: String) -> String {
        isBulletList(text) ? items(fromPlain: text).joined(separator: "; ") : text
    }

    /// Take Jira's: one line per point, as a multi-line description (#126) — so the entry sends back exactly this
    /// comment. Imports keep "; " (changing them would make every imported list look edited).
    public static func multiLineDescription(fromPlain text: String) -> String {
        isBulletList(text) ? items(fromPlain: text).joined(separator: "\n") : text
    }
}
