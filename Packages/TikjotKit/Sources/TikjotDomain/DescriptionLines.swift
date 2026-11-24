import Foundation

/// A description may have several lines (⇧↩, or pasted) — beta 2026-10-22: a tester writes points ("- Handover …")
/// per entry and wants them as points in Jira. Lists show the first line + "+N"; Jira gets one point per line.
public enum DescriptionLines {
    static let marks = ["• ", "* ", "- "]

    /// The non-empty lines, trimmed. With several lines a typed list mark ("- ", "* ", "• ") is dropped.
    public static func lines(_ s: String) -> [String] {
        let ls = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ls.count > 1 ? ls.map(unmarked) : ls
    }

    static func unmarked(_ line: String) -> String {
        for m in marks where line.hasPrefix(m) {
            let rest = line.dropFirst(m.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? line : rest
        }
        return line
    }

    /// What lists show: the first line (as typed when it is the only one).
    public static func first(_ s: String) -> String { lines(s).first ?? "" }

    /// Lines after the first ("+N").
    public static func extra(_ s: String) -> Int { max(0, lines(s).count - 1) }

    /// The worklog comment (§9.3): every line of every description is one point, typed marks dropped, the same
    /// line once; a single line in total stays plain text as typed.
    public static func comment(_ descriptions: [String]) -> String {
        var seen = Set<String>()
        var points: [String] = []
        for d in descriptions {
            for l in lines(d) where seen.insert(l.lowercased()).inserted { points.append(l) }
        }
        switch points.count {
        case 0: return ""
        case 1: return points[0]
        default: return points.map { "• " + unmarked($0) }.joined(separator: "\n")
        }
    }
}
