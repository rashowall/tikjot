import Foundation
import Testing
@testable import JiraKit

/// Worklog `started` and JQL dates around Europe/Bratislava's autumn change (Sun 25 Oct 2026 03:00 CEST → 02:00 CET).
@Suite struct JiraDateDSTTests {
    let tz = TimeZone(identifier: "Europe/Bratislava")!

    func utc(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    @Test func startedCarriesTheOffsetOfThatInstant() {
        let cases: [(String, String)] = [
            ("2026-10-24 23:30", "2026-10-25T01:30:00.000+0200"),   // summer time
            ("2026-10-25 00:30", "2026-10-25T02:30:00.000+0200"),   // first 02:30
            ("2026-10-25 01:30", "2026-10-25T02:30:00.000+0100"),   // second 02:30
            ("2026-10-25 02:30", "2026-10-25T03:30:00.000+0100"),   // winter time
            ("2026-03-29 00:30", "2026-03-29T01:30:00.000+0100"),
            ("2026-03-29 01:30", "2026-03-29T03:30:00.000+0200"),
        ]
        for (instant, text) in cases {
            #expect(JiraDate.format(utc(instant), timeZone: tz) == text)
            // Round trip: the same instant comes back, whatever zone parses it.
            #expect(JiraDate.parse(text) == utc(instant))
        }
    }

    @Test func jqlWindowNeverStartsLate() {
        // Ordinary times are written as they are.
        #expect(JiraDate.jql(utc("2026-10-24 21:15"), timeZone: tz) == "2026/10/24 23:15")
        #expect(JiraDate.jql(utc("2026-10-25 02:30"), timeZone: tz) == "2026/10/25 03:30")
        #expect(JiraDate.jql(utc("2026-03-29 01:30"), timeZone: tz) == "2026/03/29 03:30")
        // The first pass through 02:xx could be read as the second (an hour later): written as 01:59 instead.
        #expect(JiraDate.jql(utc("2026-10-25 00:30"), timeZone: tz) == "2026/10/25 01:59")
        // The second pass is safe as it is (either reading is not later).
        #expect(JiraDate.jql(utc("2026-10-25 01:30"), timeZone: tz) == "2026/10/25 02:30")
    }
}
