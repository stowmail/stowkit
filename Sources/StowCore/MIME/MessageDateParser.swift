import Foundation

/// Parses the Date header (RFC 5322 section 3.3, including the obsolete forms
/// in section 4.3) into a `Date`.
///
/// Written by hand rather than with `DateFormatter`, which is slow, depends on
/// the user's locale and needs one pattern per variant. Accepts: an optional
/// day name, one- or two-digit days, two-, three- or four-digit years, times
/// with or without seconds, numeric zones (`+0100`), the named zones RFC 5322
/// lists (`GMT`, `EST` and so on) and trailing comments such as `(BST)`.
/// The `asctime` order some old software writes (`Mon Sep  2 09:01:00 2025`)
/// works too. Anything that does not add up to a real moment returns nil.
public enum MessageDateParser {
    public struct Result: Sendable, Equatable {
        public var date: Date
        /// True if the zone was missing or unknown, so UTC was assumed.
        public var assumedUTC: Bool
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    /// Zone names from RFC 5322 section 4.3, in minutes east of UTC.
    private static let zones: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0,
        "edt": -4 * 60, "est": -5 * 60, "cdt": -5 * 60, "cst": -6 * 60,
        "mdt": -6 * 60, "mst": -7 * 60, "pdt": -7 * 60, "pst": -8 * 60,
    ]

    public static func parse(_ raw: String) -> Result? {
        // Remove comments, then split on whitespace and commas.
        var cleaned = ""
        var depth = 0
        for c in raw {
            if c == "(" { depth += 1; continue }
            if c == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { cleaned.append(c) }
        }
        let tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "\r" || $0 == "\n" })
            .map(String.init)

        var month: Int?
        var numbers: [String] = []
        var time: (Int, Int, Int)?
        var offsetMinutes: Int?
        var assumedUTC = false

        for token in tokens {
            let lower = token.lowercased()
            if token.contains(":") {
                guard time == nil, let parsed = parseTime(token) else { return nil }
                time = parsed
            } else if let first = token.first, first == "+" || first == "-" {
                guard time != nil, offsetMinutes == nil, let offset = parseOffset(token) else { return nil }
                offsetMinutes = offset
            } else if token.allSatisfy(\.isASCIIDigit) {
                numbers.append(token)
            } else if token.allSatisfy(\.isLetter) {
                let prefix = String(lower.prefix(3))
                if time == nil, month == nil, lower.count >= 3, let index = months.firstIndex(of: prefix),
                   isPrefixOfMonthName(lower, index) {
                    month = index + 1
                } else if time == nil, lower.count >= 3, days.contains(prefix) {
                    continue
                } else if time != nil, offsetMinutes == nil {
                    if let zone = zones[lower] {
                        offsetMinutes = zone
                    } else {
                        // Unknown names, and military single letters (RFC 5322 says
                        // treat those as -0000), are taken as UTC.
                        offsetMinutes = 0
                        assumedUTC = true
                    }
                } else if time != nil {
                    continue  // a second zone name after a numeric zone, for example "+0000 GMT"
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }

        guard let month, let time, numbers.count == 2,
              let day = Int(numbers[0]), numbers[0].count <= 2,
              var year = Int(numbers[1])
        else { return nil }

        switch numbers[1].count {
        case 2: year += year < 50 ? 2000 : 1900
        case 3: year += 1900
        case 4: break
        default: return nil
        }
        if offsetMinutes == nil {
            offsetMinutes = 0
            assumedUTC = true
        }
        guard (1...daysIn(month: month, year: year)).contains(day) else { return nil }

        let (hour, minute, second) = time
        let dayNumber = daysFromCivil(year: year, month: month, day: day)
        let seconds = dayNumber * 86_400 + hour * 3600 + minute * 60 + second - offsetMinutes! * 60
        return Result(date: Date(timeIntervalSince1970: TimeInterval(seconds)), assumedUTC: assumedUTC)
    }

    private static func isPrefixOfMonthName(_ lower: String, _ index: Int) -> Bool {
        let full = ["january", "february", "march", "april", "may", "june", "july", "august",
                    "september", "october", "november", "december"][index]
        return full.hasPrefix(lower) || lower == "sept"
    }

    private static func parseTime(_ token: String) -> (Int, Int, Int)? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isASCIIDigit) }),
              let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return nil }
        let second = parts.count == 3 ? Int(parts[2]) ?? -1 : 0
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        // A leap second is folded into the one before it.
        return (hour, minute, min(second, 59))
    }

    private static func parseOffset(_ token: String) -> Int? {
        let digits = token.dropFirst()
        guard digits.count == 4, digits.allSatisfy(\.isASCIIDigit),
              let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
              hours <= 14, minutes <= 59
        else { return nil }
        let total = hours * 60 + minutes
        return token.first == "-" ? -total : total
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 for a Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
