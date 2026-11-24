import AppKit
import Foundation
import TikjotDomain
import UniformTypeIdentifiers

/// CSV exports (§12.5): entries (raw), daily worklogs, summary, attendance; plus everything as ZIP.
/// UTF-8 with BOM; `;` or `,` by locale (Excel-friendly); durations decimal + `h m`.
@MainActor
enum Exporter {
    enum Kind: String, CaseIterable, Identifiable {
        case entries, worklogs, summary, attendance
        var id: String { rawValue }
        var title: String {
            switch self {
            case .entries: return String(localized: "Entries (raw)")
            case .worklogs: return String(localized: "Daily worklogs")
            case .summary: return String(localized: "Summary by project and task")
            case .attendance: return String(localized: "Attendance by day")
            }
        }
        var fileName: String { "tikjot-\(rawValue)" }
    }

    static var separator: String { Locale.current.decimalSeparator == "," ? ";" : "," }

    static func csv(_ rows: [[String]]) -> Data {
        // Formula-looking text is neutralized; numbers stay numbers (CSVText).
        Data([0xEF, 0xBB, 0xBF]) + Data(CSVText.encode(rows, separator: separator).utf8)
    }

    static func dec(_ s: Seconds) -> String {
        let v = DurationFormat.decimalHours(s)
        return separator == ";" ? v.replacingOccurrences(of: ".", with: ",") : v
    }

    static func make(_ kind: Kind, model m: AppModel, range: DateRange, projects: Set<UUID>?, billable: Bool?) -> Data {
        let l = m.ledger
        let include: (UUID?) -> Bool = { pid in
            if let projects, !projects.contains(pid ?? UUID()) { return false }
            if let billable { return (m.project(pid)?.billable ?? false) == billable }
            return true
        }
        switch kind {
        case .entries:
            var rows = [["date", "start", "end", "duration_h", "duration", "instance", "issue_key", "summary", "project", "billable", "description", "sync_state"]]
            for d in range {
                for e in l.workEntries(on: d) where include(e.projectId) {
                    let i = m.issue(for: e), p = m.project(e.projectId)
                    let line = l.lines(on: d).first { $0.entries.contains { $0.id == e.id } }
                    let state = line.map { l.state(of: $0, lock: m.lock).rawValue } ?? ""
                    rows.append([d.description, Fmt.time(e.start), e.end.map(Fmt.time) ?? "", dec(e.duration(now: m.now)), DurationFormat.hm(e.duration(now: m.now)),
                                 m.data.instances.first { $0.id == e.instanceId }?.name ?? "", i?.key ?? "", i?.summary ?? "", p?.name ?? "",
                                 (p?.billable ?? false) ? "yes" : "no", e.description, state])
                }
            }
            return csv(rows)
        case .worklogs:
            var rows = [["date", "issue_key", "summary", "project", "raw_h", "rounded_h", "rounded", "comment", "in_jira"]]
            for d in range {
                for line in l.lines(on: d) where include(line.projectId) && !line.isNoIssue {
                    let i = m.issue(line.issue)
                    rows.append([d.description, i?.key ?? "", i?.summary ?? "", m.project(line.projectId)?.name ?? "", dec(line.raw), dec(line.value),
                                 DurationFormat.hm(line.value), line.comment.replacingOccurrences(of: "\n", with: "; "),
                                 l.state(of: line, lock: m.lock) == .synced || l.state(of: line, lock: m.lock) == .locked ? "yes" : "no"])
                }
            }
            return csv(rows)
        case .summary:
            var byProject: [UUID?: Seconds] = [:]
            var byIssue: [String: (key: String, summary: String, project: String, secs: Seconds)] = [:]
            for d in range {
                for line in l.lines(on: d) where include(line.projectId) {
                    byProject[line.projectId, default: 0] += line.value
                    let i = m.issue(line.issue)
                    let k = i?.id ?? "none-\(line.projectId?.uuidString ?? "")"
                    var x = byIssue[k] ?? (i?.key ?? "", i?.summary ?? String(localized: "No task"), m.project(line.projectId)?.name ?? "", 0)
                    x.secs += line.value
                    byIssue[k] = x
                }
            }
            var rows = [["level", "project", "issue_key", "summary", "hours", "duration", "billable"]]
            for (pid, s) in byProject.sorted(by: { $0.value > $1.value }) {
                let p = m.project(pid)
                rows.append(["project", p?.name ?? "", "", "", dec(s), DurationFormat.hm(s), (p?.billable ?? false) ? "yes" : "no"])
            }
            for x in byIssue.values.sorted(by: { $0.secs > $1.secs }) {
                rows.append(["issue", x.project, x.key, x.summary, dec(x.secs), DurationFormat.hm(x.secs), ""])
            }
            return csv(rows)
        case .attendance:
            var rows = [["date", "day_type", "fund_h", "absences", "worked_h", "balance_h", "cumulative_h"]]
            let cal = m.dayCalendar
            var cum = 0
            for d in range {
                let f = l.fund(d), w = l.worked(d)
                cum += w - f
                let abs = m.absences(on: d).compactMap { a in m.absenceType(a.typeId).map { "\($0.name) \(a.unit == .hours ? DurationFormat.short(a.amountSeconds) : a.unit.rawValue)" } }.joined(separator: "; ")
                rows.append([d.description, cal.dayType(d).rawValue, dec(f), abs, dec(w), dec(w - f), dec(cum)])
            }
            return csv(rows)
        }
    }

    static func save(_ kind: Kind?, model: AppModel, range: DateRange, projects: Set<UUID>?, billable: Bool?) {
        let panel = NSSavePanel()
        let suffix = "\(range.start)_\(range.end)"
        if let kind {
            panel.nameFieldStringValue = "\(kind.fileName)-\(suffix).csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        } else {
            panel.nameFieldStringValue = "tikjot-\(suffix).zip"
            panel.allowedContentTypes = [.zip]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let kind {
                try make(kind, model: model, range: range, projects: projects, billable: billable).write(to: url)
            } else {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tikjot-export-\(suffix)")
                try? FileManager.default.removeItem(at: dir)
                // The CSVs hold descriptions: they must not outlive the zip.
                defer { try? FileManager.default.removeItem(at: dir) }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for k in Kind.allCases {
                    try make(k, model: model, range: range, projects: projects, billable: billable).write(to: dir.appendingPathComponent("\(k.fileName)-\(suffix).csv"))
                }
                try zip(dir, to: url)
            }
            model.showToast(String(localized: "Exported"), actionTitle: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            model.showToast(String(localized: "Export failed — \(error.localizedDescription)"))
        }
    }

    /// Zips a folder using the system's file coordinator (no third-party code).
    static func zip(_ dir: URL, to dest: URL) throws {
        var err: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &err) { zipped in
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipped, to: dest)
            } catch { inner = error }
        }
        if let e = err ?? inner { throw e }
    }
}
