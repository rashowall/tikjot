import Testing
@testable import TikjotDomain

@Suite struct LocalDateTests {
    @Test func parsingAndArithmetic() {
        let x = d("2026-10-02")
        #expect(x.description == "2026-10-02")
        #expect(x.isoWeekday == 5)
        #expect(x.isoWeek == 40)
        #expect(x.startOfWeek == d("2026-09-28"))
        #expect(d("2026-02-01").lastOfMonth == d("2026-02-28"))
        #expect(d("2026-12-31").adding(days: 1) == d("2027-01-01"))
        #expect(d("2026-10-01").days(until: d("2026-10-31")) == 30)
        #expect(DateRange(d("2026-09-01"), d("2026-09-30")).count == 30)
        #expect(d("2026-08-15").firstOfQuarter == d("2026-07-01"))
    }

    @Test func dstDayHas23Hours() {
        let day = d("2026-03-29")
        #expect(day.end(in: bratislava).timeIntervalSince(day.start(in: bratislava)) == 23 * 3600)
    }
}
