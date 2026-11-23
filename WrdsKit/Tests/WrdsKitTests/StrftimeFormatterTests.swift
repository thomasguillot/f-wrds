import Foundation
import Testing
import WrdsKit

/// 2023-11-14 22:13:20 UTC — a Tuesday, day 318 of the year, in ISO week 46.
private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
/// 2023-11-04 22:13:20 UTC — a Saturday. Single-digit day and month, for the padding tokens.
private let singleDigitDayDate = Date(timeIntervalSince1970: 1_700_000_000 - 10 * 86_400)

/// Fixed rather than `.current`: every expectation below is a literal, so the locale has to be too.
private let posix = Locale(identifier: "en_US_POSIX")

private func format(_ format: String, date: Date = referenceDate,
                    locale: Locale = posix, timeZone: TimeZone = .gmt) -> String {
    StrftimeFormatter.format(format, date: date, locale: locale, timeZone: timeZone)
}

@Suite("StrftimeFormatter")
struct StrftimeFormatterTests {

    // MARK: Numeric tokens

    @Test("A date renders its numeric tokens")
    func rendersNumericTokens() {
        #expect(format("%Y") == "2023")
        #expect(format("%y") == "23")
        #expect(format("%m") == "11")
        #expect(format("%d") == "14")
        #expect(format("%H") == "22")
        #expect(format("%M") == "13")
        #expect(format("%S") == "20")
    }

    @Test("%I is the 12-hour clock and %p its half of the day")
    func rendersTwelveHourClock() {
        // 22:13 UTC — the one hour of the day where a 24-hour reading (22) and a 12-hour one (10)
        // cannot be confused for each other.
        #expect(format("%I") == "10")
        #expect(format("%p") == "PM")
        // Midnight is the case a naive `hour % 12` gets wrong: it reads as 12 AM, not 0 AM.
        let midnight = Date(timeIntervalSince1970: 1_700_000_000 - 22 * 3600 - 13 * 60 - 20)
        #expect(format("%I %p %H", date: midnight) == "12 AM 00")
    }

    @Test("%d zero-pads a single-digit day and %e space-pads it")
    func padsTheDayTwoWays() {
        #expect(format("%d", date: singleDigitDayDate) == "04")
        #expect(format("%e", date: singleDigitDayDate) == " 4")
        // Nothing to pad on a two-digit day: both tokens render it the same.
        #expect(format("%d %e") == "14 14")
    }

    @Test("%j is the day of the year and %V the ISO week")
    func rendersDayOfYearAndIsoWeek() {
        #expect(format("%j") == "318")
        #expect(format("%V") == "46")
        #expect(format("%j %V", date: singleDigitDayDate) == "308 44")
    }

    // MARK: Symbolic tokens

    @Test("The name tokens render the weekday and month")
    func rendersNameTokens() {
        #expect(format("%A") == "Tuesday")
        #expect(format("%a") == "Tue")
        #expect(format("%B") == "November")
        #expect(format("%b") == "Nov")
    }

    @Test("Names follow the locale, numbers do not")
    func namesFollowTheLocale() {
        let french = Locale(identifier: "fr_FR")
        #expect(format("%B", locale: french) == "novembre")
        // The numeric tokens are ASCII digits whatever the locale asks for.
        #expect(format("%Y-%m-%d", locale: french) == "2023-11-14")
    }

    @Test("A non-Gregorian locale still renders the Gregorian date")
    func ignoresTheLocalesOwnCalendar() {
        // strftime is Gregorian by definition. A locale that would otherwise drag in the Buddhist
        // calendar (year 2566) must not move the numbers.
        #expect(format("%Y-%m-%d", locale: Locale(identifier: "th_TH@calendar=buddhist")) == "2023-11-14")
    }

    // MARK: Time zones

    @Test("The time zone decides which day it is")
    func timeZoneDecidesTheDay() {
        // 22:13 UTC is already tomorrow east of UTC+2 and still yesterday's evening west of it.
        #expect(format("%Y-%m-%d %H", timeZone: TimeZone(identifier: "Pacific/Kiritimati") ?? .gmt)
            == "2023-11-15 12")
        #expect(format("%Y-%m-%d %H", timeZone: TimeZone(identifier: "America/New_York") ?? .gmt)
            == "2023-11-14 17")
    }

    // MARK: Literals and unknown tokens

    @Test("Text around the tokens is preserved")
    func preservesSurroundingText() {
        #expect(format("Today is %Y-%m-%d, at %H:%M.") == "Today is 2023-11-14, at 22:13.")
        #expect(format("no tokens here") == "no tokens here")
        #expect(format("") == "")
    }

    @Test("%% is a literal percent")
    func rendersLiteralPercent() {
        #expect(format("100%%") == "100%")
        #expect(format("%%Y") == "%Y", "the escape must not leave a token behind for the next pass")
    }

    @Test("An unknown token passes through literally")
    func passesUnknownTokensThrough() {
        // Espanso configs carry strftime tokens this app has not implemented. Rendering them
        // verbatim keeps the text recoverable rather than silently dropping a chunk of the date.
        #expect(format("%q") == "%q")
        #expect(format("%Y %q %d") == "2023 %q 14")
        #expect(format("%") == "%", "a trailing percent has nothing to escape")
    }
}
