import Foundation

/// CSV text for exports (§12.5), safe to open in Excel/Numbers/LibreOffice.
public enum CSVText {
    /// Rows joined with CRLF; each field made safe by `cell`.
    public static func encode(_ rows: [[String]], separator: String) -> String {
        rows.map { r in r.map { cell($0, separator: separator) }.joined(separator: separator) }.joined(separator: "\r\n")
    }

    /// One field. Text starting with `= + - @`, tab or CR would run as a formula in a spreadsheet, so it gets a
    /// leading `'`; plain numbers ("-1.5", "2,25") stay numbers. Fields with the separator, quotes or line
    /// breaks are quoted.
    public static func cell(_ field: String, separator: String) -> String {
        var f = field
        if let first = f.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first), !isNumber(f) {
            f = "'" + f
        }
        let needs = f.contains(separator) || f.contains("\"") || f.contains("\n") || f.contains("\r")
        return needs ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
    }

    static func isNumber(_ s: String) -> Bool {
        s.range(of: #"^-?[0-9]+([.,][0-9]+)?$"#, options: .regularExpression) != nil
    }
}
