import Testing
import TikjotDomain
@testable import TikjotHolidays

@Suite struct HolidayTests {
    @Test func easter() {
        #expect(HolidayEngine.easterSunday(2025) == LocalDate("2025-04-20")!)
        #expect(HolidayEngine.easterSunday(2026) == LocalDate("2026-04-05")!)
        #expect(HolidayEngine.easterSunday(2027) == LocalDate("2027-03-28")!)
    }

    @Test func slovakia2026() {
        let h = HolidayEngine.holidays(country: "SK", years: 2026...2026)
        let dates = Set(h.map(\.date.description))
        #expect(h.count == 11)
        #expect(dates.contains("2026-04-03")) // Good Friday
        #expect(dates.contains("2026-04-06")) // Easter Monday
        #expect(!dates.contains("2026-05-08"))
        #expect(!dates.contains("2026-09-15"))
        #expect(!dates.contains("2026-09-01"))
        #expect(!dates.contains("2026-11-17"))
    }

    @Test func slovakiaHistory() {
        let d2024 = Set(HolidayEngine.holidays(country: "SK", years: 2024...2024).map(\.date.description))
        #expect(d2024.contains("2024-11-17"))
        #expect(!d2024.contains("2024-09-01"))
        let d2025 = Set(HolidayEngine.holidays(country: "SK", years: 2025...2025).map(\.date.description))
        #expect(d2025.contains("2025-09-15"))
        #expect(!d2025.contains("2025-11-17"))
    }

    @Test func slovakNames() {
        let h = HolidayEngine.holidays(country: "SK", years: 2026...2026, language: "sk")
        #expect(h.first?.name == "Deň vzniku Slovenskej republiky")
    }
}

/// Expected 2026 dates come from the official lists (gov.uk, opm.gov, BOE, citizensinformation.ie, national
/// laws) and published calendars — not from the engine. Western Easter 2026 = 5 Apr, Orthodox = 12 Apr.
@Suite struct CountryHolidayTests {
    private func dates(_ c: String, _ y: Int) -> Set<String> {
        Set(HolidayEngine.holidays(country: c, years: y...y).map(\.date.description))
    }

    private func check(_ c: String, count: Int, has: [String], hasNot: [String] = []) {
        let h = HolidayEngine.holidays(country: c, years: 2026...2026)
        let d = Set(h.map(\.date.description))
        #expect(h.count == count, "\(c): \(h.map(\.date.description))")
        for x in has { #expect(d.contains(x), "\(c) should have \(x)") }
        for x in hasNot { #expect(!d.contains(x), "\(c) should not have \(x)") }
    }

    @Test func allCountriesLoad() {
        #expect(HolidayEngine.availableCountries.count == 24)
        for c in HolidayEngine.availableCountries {
            #expect(HolidayEngine.definition(for: c) != nil, "\(c)")
            #expect(HolidayEngine.countryName(c, language: "sk") != c, "\(c) has a Slovak name")
        }
        #expect(HolidayEngine.countryName("DE", language: "sk") == "Nemecko")
        #expect(HolidayEngine.countryName("DE", language: "en") == "Germany")
        #expect(HolidayEngine.availableCountries.first == "AT")
    }

    @Test func defaultCountry() {
        #expect(HolidayEngine.defaultCountry(forRegion: "CZ") == "CZ")
        #expect(HolidayEngine.defaultCountry(forRegion: "UK") == "GB")
        #expect(HolidayEngine.defaultCountry(forRegion: "JP") == "SK")
        #expect(HolidayEngine.defaultCountry(forRegion: nil) == "SK")
    }

    @Test func orthodoxEaster() {
        #expect(HolidayEngine.orthodoxEasterSunday(2023) == LocalDate("2023-04-16")!)
        #expect(HolidayEngine.orthodoxEasterSunday(2024) == LocalDate("2024-05-05")!)
        #expect(HolidayEngine.orthodoxEasterSunday(2025) == LocalDate("2025-04-20")!)
        #expect(HolidayEngine.orthodoxEasterSunday(2026) == LocalDate("2026-04-12")!)
    }

    @Test func year2026() {
        check("CZ", count: 13, has: ["2026-04-03", "2026-04-06", "2026-07-06", "2026-09-28", "2026-12-24"])
        check("PL", count: 12, has: ["2026-01-06", "2026-06-04", "2026-11-11", "2026-12-24"])
        check("HU", count: 11, has: ["2026-03-15", "2026-04-03", "2026-05-25", "2026-10-23"], hasNot: ["2026-12-24"])
        check("AT", count: 13, has: ["2026-05-14", "2026-05-25", "2026-06-04", "2026-10-26", "2026-12-08"], hasNot: ["2026-04-03"])
        check("DE", count: 9, has: ["2026-04-03", "2026-05-14", "2026-05-25", "2026-10-03"], hasNot: ["2026-10-31"])
        check("CH", count: 4, has: ["2026-01-01", "2026-05-14", "2026-08-01", "2026-12-25"])
        check("GB", count: 8, has: ["2026-04-03", "2026-05-04", "2026-05-25", "2026-08-31", "2026-12-28"], hasNot: ["2026-12-26"])
        check("IE", count: 10, has: ["2026-02-02", "2026-03-17", "2026-05-04", "2026-06-01", "2026-08-03", "2026-10-26", "2026-12-26"])
        check("US", count: 11, has: ["2026-01-19", "2026-02-16", "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07", "2026-10-12", "2026-11-26"], hasNot: ["2026-07-04"])
        check("NL", count: 7, has: ["2026-04-06", "2026-04-27", "2026-05-14", "2026-05-25"], hasNot: ["2026-04-03", "2026-05-05"])
        check("FR", count: 11, has: ["2026-05-08", "2026-05-14", "2026-05-25", "2026-07-14", "2026-11-11"])
        check("ES", count: 10, has: ["2026-01-06", "2026-04-03", "2026-10-12", "2026-12-08"], hasNot: ["2026-04-06"])
        check("IT", count: 12, has: ["2026-04-06", "2026-04-25", "2026-06-02", "2026-10-04"])
        check("PT", count: 12, has: ["2026-04-03", "2026-06-04", "2026-06-10", "2026-10-05", "2026-12-01"])
        check("BE", count: 10, has: ["2026-04-06", "2026-05-14", "2026-05-25", "2026-07-21", "2026-11-11"])
        check("SE", count: 12, has: ["2026-01-06", "2026-05-14", "2026-06-06", "2026-06-19", "2026-12-31"], hasNot: ["2026-05-25"])
        check("DK", count: 8, has: ["2026-04-02", "2026-04-03", "2026-05-14", "2026-05-25"], hasNot: ["2026-05-01"])
        check("NO", count: 10, has: ["2026-04-02", "2026-05-17", "2026-05-14", "2026-05-25"])
        check("FI", count: 11, has: ["2026-01-06", "2026-06-19", "2026-12-06", "2026-12-24"])
        check("RO", count: 14, has: ["2026-01-07", "2026-01-24", "2026-04-10", "2026-04-13", "2026-06-01", "2026-11-30"], hasNot: ["2026-04-06"])
        check("HR", count: 13, has: ["2026-04-06", "2026-05-30", "2026-06-04", "2026-06-22", "2026-11-18"], hasNot: ["2026-06-25", "2026-10-08"])
        check("SI", count: 13, has: ["2026-01-02", "2026-02-08", "2026-04-27", "2026-06-25", "2026-10-31"])
        check("UA", count: 0, has: [])
        check("SK", count: 11, has: ["2026-04-03"])
    }

    @Test func mergedSameDay() {
        let jun1 = HolidayEngine.holidays(country: "RO", years: 2026...2026).first { $0.date == LocalDate("2026-06-01")! }
        #expect(jun1?.name == "Children's Day / Orthodox Whit Monday")
    }

    @Test func substitutesAndHistory() {
        // UK: Christmas Sat + Boxing Day Sun 2021 → 27 and 28 Dec; 2020 VE Day; 2022 jubilee + funeral.
        let gb2021 = dates("GB", 2021)
        #expect(gb2021.isSuperset(of: ["2021-12-27", "2021-12-28"]))
        let gb2020 = dates("GB", 2020)
        #expect(gb2020.contains("2020-05-08") && !gb2020.contains("2020-05-04"))
        let gb2022 = dates("GB", 2022)
        #expect(gb2022.isSuperset(of: ["2022-06-02", "2022-06-03", "2022-09-19", "2022-01-03"]))
        #expect(!gb2022.contains("2022-05-30"))
        #expect(dates("GB", 2023).contains("2023-05-08"))
        // US: 4 Jul 2021 Sunday → Mon 5 Jul; 25 Dec 2021 Saturday → Fri 24 Dec; 1 Jan 2022 Sat → Fri 31 Dec 2021.
        let us2021 = dates("US", 2021)
        #expect(us2021.isSuperset(of: ["2021-07-05", "2021-12-24"]))
        #expect(dates("US", 2022).contains("2021-12-31"))
        #expect(!dates("US", 2020).contains("2020-06-19"))
        // IE St Brigid's Day: 2024 → Mon 5 Feb, 2027 → Mon 1 Feb, 2030 → Fri 1 Feb; one-off 18 Mar 2022.
        #expect(dates("IE", 2024).contains("2024-02-05"))
        #expect(dates("IE", 2027).contains("2027-02-01"))
        #expect(dates("IE", 2030).contains("2030-02-01"))
        #expect(dates("IE", 2022).contains("2022-03-18"))
        // Midsummer Eve: 2024 → 21 Jun, 2025 → 20 Jun.
        #expect(dates("SE", 2024).contains("2024-06-21"))
        #expect(dates("FI", 2025).contains("2025-06-20"))
        // DK Great Prayer Day until 2023 (5 May 2023).
        #expect(dates("DK", 2023).contains("2023-05-05"))
        #expect(!dates("DK", 2024).contains("2024-04-26"))
        // PL Christmas Eve from 2025, Epiphany from 2011.
        #expect(!dates("PL", 2024).contains("2024-12-24"))
        #expect(dates("PL", 2025).contains("2025-12-24"))
        #expect(!dates("PL", 2010).contains("2010-01-06"))
        // IT St Francis from 2026; RO 6/7 Jan from 2024; HR 2019 vs 2020; PT 2013–2015; DE 2017; SI 2013–2016.
        #expect(!dates("IT", 2025).contains("2025-10-04"))
        #expect(!dates("RO", 2023).contains("2023-01-06"))
        #expect(dates("HR", 2019).isSuperset(of: ["2019-06-25", "2019-10-08"]))
        #expect(!dates("PT", 2014).contains("2014-10-05"))
        #expect(dates("DE", 2017).contains("2017-10-31"))
        #expect(!dates("SI", 2015).contains("2015-01-02"))
        // UA 2021 (pre-war): 1 May Sat → Mon 3 May, Easter Sun 2 May → Tue 4 May, 9 May Sun → Mon 10 May.
        #expect(dates("UA", 2021).isSuperset(of: ["2021-05-03", "2021-05-04", "2021-05-10"]))
        #expect(dates("UA", 2022) == ["2022-01-03", "2022-01-07"])
    }

    @Test func localNames() {
        let de = HolidayEngine.holidays(country: "DE", years: 2026...2026, language: "sk")
        #expect(de.first { $0.date == LocalDate("2026-10-03")! }?.name == "Deň nemeckej jednoty")
    }
}
