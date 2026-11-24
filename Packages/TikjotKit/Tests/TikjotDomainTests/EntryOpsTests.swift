import Foundation
import Testing
@testable import TikjotDomain

@Suite struct EntryOpsTests {
    let p = UUID()

    @Test func startStopsRunningContiguously() {
        let running = entry("2026-10-01 09:00", nil, issue: "1", project: p)
        let new = entry("2026-10-01 10:00", nil, issue: "2", project: p)
        let c = EntryOps.start(new, running: running, at: t("2026-10-01 10:00"))
        #expect(c.updated.first?.end == t("2026-10-01 10:00"))
        #expect(c.inserted.first?.end == nil)
    }

    @Test func stopUnderAMinuteDiscards() {
        let r = entry("2026-10-01 09:00", nil, issue: "1", project: p)
        #expect(EntryOps.stop(r, at: t("2026-10-01 09:00").addingTimeInterval(30)).discarded)
        #expect(!EntryOps.stop(r, at: t("2026-10-01 09:05")).discarded)
    }

    @Test func splitCarveMerge() throws {
        let e = entry("2026-10-01 09:00", "2026-10-01 11:00", issue: "1", project: p, desc: "Work")
        let s = try EntryOps.split(e, at: t("2026-10-01 10:00"))
        #expect(s.updated[0].end == t("2026-10-01 10:00"))
        #expect(s.inserted[0].start == t("2026-10-01 10:00"))

        let c = try EntryOps.carve(e, from: t("2026-10-01 09:30"), to: t("2026-10-01 10:00"))
        #expect(c.updated[0].end == t("2026-10-01 09:30"))
        #expect(c.inserted[0].start == t("2026-10-01 10:00"))

        let a = entry("2026-10-01 09:00", "2026-10-01 09:30", issue: "1", project: p, desc: "A")
        let b = entry("2026-10-01 09:40", "2026-10-01 10:00", issue: "1", project: p, desc: "B")
        let m = try EntryOps.merge([b, a])
        #expect(m.updated[0].start == t("2026-10-01 09:00"))
        #expect(m.updated[0].end == t("2026-10-01 10:00"))
        #expect(m.updated[0].description == "A; B")
        #expect(throws: EntryOpError.differentTasks) {
            try EntryOps.merge([a, entry("2026-10-01 10:00", "2026-10-01 10:30", issue: "2", project: p)])
        }
    }

    /// Beta 2026-10-22: only neighbours merge; a running entry or another task in between says why.
    @Test func mergeOnlyNeighbours() throws {
        let a = entry("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", project: p)
        let b = entry("2026-10-01 10:00", "2026-10-01 11:00", issue: "2", project: p)
        let c = entry("2026-10-01 11:00", "2026-10-01 12:00", issue: "1", project: p)
        let d = entry("2026-10-01 13:00", "2026-10-01 13:30", issue: "1", project: p)
        let day = [a, b, c, d]
        #expect(EntryOps.mergeProblem([a, c], within: day) == .notAdjacent)
        #expect(throws: EntryOpError.notAdjacent) { try EntryOps.merge([a, c], within: day) }
        // A gap with nothing in it is fine (and counts).
        #expect(EntryOps.mergeProblem([c, d], within: day) == nil)
        #expect(try EntryOps.merge([d, c], within: day).updated[0].end == t("2026-10-01 13:30"))
        var running = d
        running.end = nil
        #expect(EntryOps.mergeProblem([c, running], within: [a, b, c, running]) == .running)
        #expect(EntryOps.mergeProblem([a], within: day) == .nothingToMerge)
        #expect(EntryOps.mergeGap([d, c]) == 3600)
        #expect(EntryOps.mergeGap([a, b, c]) == 0)
    }

    @Test func overlapsAndGaps() {
        let es = [
            entry("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", project: p),
            entry("2026-10-01 09:40", "2026-10-01 10:30", issue: "2", project: p),
            entry("2026-10-01 11:00", "2026-10-01 12:00", issue: "3", project: p),
        ]
        let o = EntryOps.overlaps(es, now: t("2026-10-01 18:00"))
        #expect(o.count == 1)
        #expect(o[0].seconds == 20 * 60)
        let g = EntryOps.gaps(es, from: t("2026-10-01 08:00"), to: t("2026-10-01 12:00"), now: t("2026-10-01 18:00"))
        #expect(g.map(\.seconds) == [60 * 60, 30 * 60])
    }

    @Test func midnightNormalization() {
        let e = entry("2026-10-01 23:00", "2026-10-02 01:00", issue: "1", project: p)
        let c = EntryOps.normalizeMidnight(e, calendar: bratislava)
        #expect(c.updated[0].end == t("2026-10-02 00:00"))
        #expect(c.inserted.count == 1)
        #expect(c.inserted[0].start == t("2026-10-02 00:00"))
    }

    @Test func weekCellIncreaseDecrease() {
        let task = entry("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", project: p)
        let other = entry("2026-10-01 10:00", "2026-10-01 11:00", issue: "2", project: p)
        // increase while another entry follows → append after the last entry of the day
        let inc = EntryOps.setCell(task: task, dayEntries: [task, other], current: 3600, target: 5400,
                                   day: d("2026-10-01"), workdayStartMinutes: 480, description: "x", now: t("2026-10-01 18:00"), calendar: bratislava)
        #expect(inc.inserted.first?.start == t("2026-10-01 11:00"))
        #expect(inc.inserted.first?.end == t("2026-10-01 11:30"))
        // increase when it is the last entry → extend
        let ext = EntryOps.setCell(task: other, dayEntries: [task, other], current: 3600, target: 5400,
                                   day: d("2026-10-01"), workdayStartMinutes: 480, description: "x", now: t("2026-10-01 18:00"), calendar: bratislava)
        #expect(ext.updated.first?.end == t("2026-10-01 11:30"))
        // decrease shortens from the end
        let dec = EntryOps.setCell(task: task, dayEntries: [task, other], current: 3600, target: 1800,
                                   day: d("2026-10-01"), workdayStartMinutes: 480, description: "", now: t("2026-10-01 18:00"), calendar: bratislava)
        #expect(dec.updated.first?.end == t("2026-10-01 09:30"))
        // zero deletes
        let zero = EntryOps.setCell(task: task, dayEntries: [task, other], current: 3600, target: 0,
                                    day: d("2026-10-01"), workdayStartMinutes: 480, description: "", now: t("2026-10-01 18:00"), calendar: bratislava)
        #expect(zero.deleted.count == 1)
        // empty day → workday start
        let empty = EntryOps.setCell(task: task, dayEntries: [], current: 0, target: 3600,
                                     day: d("2026-10-05"), workdayStartMinutes: 480, description: "", now: t("2026-10-05 18:00"), calendar: bratislava)
        #expect(empty.inserted.first?.start == t("2026-10-05 08:00"))
    }

    @Test func newEntryPlacement() {
        let es = [entry("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", project: p),
                  entry("2026-10-01 11:00", "2026-10-01 12:00", issue: "1", project: p)]
        let (s, e) = EntryOps.placementForNewEntry(on: d("2026-10-01"), entries: es, workdayStartMinutes: 480, now: t("2026-10-05 10:00"), calendar: bratislava)
        #expect(s == t("2026-10-01 10:00") && e == t("2026-10-01 11:00"))
        let (s2, _) = EntryOps.placementForNewEntry(on: d("2026-10-02"), entries: [], workdayStartMinutes: 480, now: t("2026-10-05 10:00"), calendar: bratislava)
        #expect(s2 == t("2026-10-02 08:00"))
    }

    @Test func dragEdgeDeadZoneSnapAndMagnet() {
        let dz: TimeInterval = 150   // 3 pt at 72 pt per hour
        let o = t("2026-10-01 10:32")
        // Inside the dead zone the edge stays on its own (off-grid) time — no jump to 10:30.
        #expect(EntryOps.dragEdge(o, by: 0, deadZone: dz, edges: [], calendar: bratislava) == o)
        #expect(EntryOps.dragEdge(o, by: 149, deadZone: dz, edges: [], calendar: bratislava) == o)
        #expect(EntryOps.dragEdge(o, by: -149, deadZone: dz, edges: [], calendar: bratislava) == o)
        // Past it: the 5-min grid, in the direction of the drag.
        #expect(EntryOps.dragEdge(o, by: 150, deadZone: dz, edges: [], calendar: bratislava) == t("2026-10-01 10:35"))
        #expect(EntryOps.dragEdge(o, by: -150, deadZone: dz, edges: [], calendar: bratislava) == t("2026-10-01 10:30"))
        #expect(EntryOps.dragEdge(o, by: 13 * 60, deadZone: dz, edges: [], calendar: bratislava) == t("2026-10-01 10:45"))
        // ⌥: whole minutes, no magnet.
        #expect(EntryOps.dragEdge(o, by: 160, deadZone: dz, fine: true, edges: [t("2026-10-01 10:35")], calendar: bratislava) == t("2026-10-01 10:35"))
        #expect(EntryOps.dragEdge(o, by: 220, deadZone: dz, fine: true, edges: [t("2026-10-01 10:37")], calendar: bratislava) == t("2026-10-01 10:36"))
        // Magnet 2 min: a neighbour edge at 10:48 grabs 10:46.5 but not 10:45.
        let n = [t("2026-10-01 10:48")]
        #expect(EntryOps.dragEdge(o, by: 14.5 * 60, deadZone: dz, edges: n, calendar: bratislava) == t("2026-10-01 10:48"))
        #expect(EntryOps.dragEdge(o, by: 13 * 60, deadZone: dz, edges: n, calendar: bratislava) == t("2026-10-01 10:45"))
        #expect(EntryOps.resizeMagnet == 120)
        // Never lands on the far side of the original time, whatever the start offset or neighbour.
        for m in 0..<10 {
            let start = t("2026-10-01 10:30").addingTimeInterval(TimeInterval(m * 60))
            for d in stride(from: dz, through: 20 * 60, by: 10) {
                #expect(EntryOps.dragEdge(start, by: d, deadZone: dz, edges: [start.addingTimeInterval(d - 100)], calendar: bratislava) > start)
                #expect(EntryOps.dragEdge(start, by: -d, deadZone: dz, edges: [start.addingTimeInterval(-d + 100)], calendar: bratislava) < start)
            }
        }
    }
}
