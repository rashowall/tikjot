import Testing
@testable import TikjotDomain

@Suite struct CSVTextTests {
    @Test func formulasAreNeutralized() {
        #expect(CSVText.cell("=HYPERLINK(\"http://x\")", separator: ",") == "\"'=HYPERLINK(\"\"http://x\"\")\"")
        #expect(CSVText.cell("+1+2", separator: ",") == "'+1+2")
        #expect(CSVText.cell("-2+3", separator: ",") == "'-2+3")
        #expect(CSVText.cell("@SUM(A1)", separator: ",") == "'@SUM(A1)")
        #expect(CSVText.cell("\t=1", separator: ",") == "'\t=1")
        #expect(CSVText.cell("\r=1", separator: ",") == "\"'\r=1\"")
    }

    @Test func numbersAndPlainTextStayAsTheyAre() {
        #expect(CSVText.cell("-1.50", separator: ",") == "-1.50")
        #expect(CSVText.cell("-2,25", separator: ";") == "-2,25")
        #expect(CSVText.cell("7.5", separator: ",") == "7.5")
        #expect(CSVText.cell("Code review", separator: ",") == "Code review")
        #expect(CSVText.cell("a = b", separator: ",") == "a = b")
    }

    @Test func quoting() {
        #expect(CSVText.cell("a,b", separator: ",") == "\"a,b\"")
        #expect(CSVText.cell("a;b", separator: ",") == "a;b")
        #expect(CSVText.cell("line\rbreak", separator: ",") == "\"line\rbreak\"")
        #expect(CSVText.encode([["a", "=1"], ["-1", "x"]], separator: ";") == "a;'=1\r\n-1;x")
    }
}
