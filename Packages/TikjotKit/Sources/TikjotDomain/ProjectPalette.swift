import Foundation

/// The 12 curated project colours (OKLCH, equal lightness & chroma — design tokens `project.*`).
public enum ProjectPalette {
    public static let names = ["blue", "amber", "green", "cyan", "slate", "rose",
                               "tangerine", "olive", "jade", "sky", "grape", "magenta"]

    /// First palette colour not used yet; cycles when all are taken (§10.4 "auto-pick unused").
    public static func nextUnused(_ used: [String]) -> String {
        let counts = Dictionary(used.map { ($0, 1) }, uniquingKeysWith: +)
        return names.min { (counts[$0] ?? 0, names.firstIndex(of: $0)!) < (counts[$1] ?? 0, names.firstIndex(of: $1)!) }!
    }
}
