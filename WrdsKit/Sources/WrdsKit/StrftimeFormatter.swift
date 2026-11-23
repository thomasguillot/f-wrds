import Foundation

/// Renders a date through an strftime-style format string.
///
/// The format strings come from Espanso configs, which are C `strftime` at heart, so this is a
/// translation layer rather than a wrapper: each token is looked up in a table and answered from
/// `Calendar` arithmetic, or — for the four name tokens and AM/PM — from a `DateFormatter`'s symbol
/// arrays. Handing the format string to `DateFormatter.dateFormat` instead would be wrong twice
/// over: `%d` is not a Unicode date pattern, and the characters around the tokens ("-", ":", any
/// prose) would be read as pattern syntax and quietly rewritten.
///
/// Numbers are Gregorian and ASCII whatever the locale prefers, because that is what `%Y-%m-%d`
/// means; only the names and the AM/PM symbols follow the locale.
///
/// Unknown tokens pass through verbatim. A config carrying a token this app has not implemented
/// should show which one it was, not lose a chunk of the date.
public enum StrftimeFormatter {

    /// - Parameters:
    ///   - locale: names and AM/PM symbols only — never the numbers.
    ///   - timeZone: the zone the date is read in, which decides what "today" is.
    public static func format(_ format: String, date: Date, locale: Locale = .current,
                              timeZone: TimeZone = .current) -> String {
        // Most formats are a handful of tokens; a format with none at all is pure literal text.
        guard format.contains("%") else { return format }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday, .dayOfYear], from: date)

        // Both of these cost far more to build than the whole of the rest of this function, and the
        // everyday formats ("%Y-%m-%d", "%H:%M") need neither, so they are built on first use.
        var symbolFormatter: DateFormatter?
        func symbols() -> DateFormatter {
            if let symbolFormatter { return symbolFormatter }
            let formatter = DateFormatter()
            // Locale first: assigning it resets the calendar to the locale's own, which for a
            // Buddhist or Japanese locale would rename the months out from under the Gregorian
            // numbers above.
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            symbolFormatter = formatter
            return formatter
        }

        var output = ""
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            index = format.index(after: index)
            guard character == "%", index < format.endIndex else {
                // A trailing "%" has nothing to escape, so it is literal like everything else.
                output.append(character)
                continue
            }
            let specifier = format[index]
            index = format.index(after: index)
            output += expansion(of: specifier, parts: parts, date: date,
                                timeZone: timeZone, symbols: symbols) ?? "%\(specifier)"
        }
        return output
    }

    /// The text `specifier` stands for, or `nil` if it is not a token this renders.
    private static func expansion(of specifier: Character, parts: DateComponents, date: Date,
                                  timeZone: TimeZone, symbols: () -> DateFormatter) -> String? {
        // Absent components cannot happen for the fields requested above, but a zero reads better
        // in the output than a crash would.
        let year = parts.year ?? 0
        let hour = parts.hour ?? 0
        switch specifier {
        case "Y": return padded(year, width: 4)
        case "y": return padded(year % 100, width: 2)
        case "m": return padded(parts.month ?? 0, width: 2)
        case "d": return padded(parts.day ?? 0, width: 2)
        case "e": return padded(parts.day ?? 0, width: 2, with: " ")
        case "H": return padded(hour, width: 2)
        // Midnight and noon are both 12 on a 12-hour clock, which a bare remainder gets wrong.
        case "I": return padded(hour % 12 == 0 ? 12 : hour % 12, width: 2)
        case "M": return padded(parts.minute ?? 0, width: 2)
        case "S": return padded(parts.second ?? 0, width: 2)
        case "j": return padded(parts.dayOfYear ?? 0, width: 3)
        case "V": return padded(isoWeek(of: date, in: timeZone), width: 2)
        case "p": return (hour < 12 ? symbols().amSymbol : symbols().pmSymbol) ?? ""
        // `weekday` is 1-based from Sunday in the Gregorian calendar, which is the order the symbol
        // arrays are in whatever the locale's own first day of the week is.
        case "A": return symbols().weekdaySymbols[safe: (parts.weekday ?? 1) - 1]
        case "a": return symbols().shortWeekdaySymbols[safe: (parts.weekday ?? 1) - 1]
        case "B": return symbols().monthSymbols[safe: (parts.month ?? 1) - 1]
        case "b": return symbols().shortMonthSymbols[safe: (parts.month ?? 1) - 1]
        case "%": return "%"
        default: return nil
        }
    }

    /// The ISO 8601 week number: weeks start on Monday and week 1 is the one holding the 4th of
    /// January. The `.iso8601` calendar carries exactly those two rules, which is why the week is
    /// read from a calendar of its own rather than from the Gregorian one above.
    private static func isoWeek(of date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar.component(.weekOfYear, from: date)
    }

    /// `value` right-aligned in `width`, padded with `pad`. Never truncates: a wider number keeps
    /// all of its digits.
    private static func padded(_ value: Int, width: Int, with pad: Character = "0") -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: pad, count: width - digits.count) + digits
    }
}

extension Array {
    /// The element at `index`, or `nil` if it is out of bounds. Guards the symbol lookups: an index
    /// derived from a date component should always be in range, and a wrong date is no reason to
    /// take the whole expansion down.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
