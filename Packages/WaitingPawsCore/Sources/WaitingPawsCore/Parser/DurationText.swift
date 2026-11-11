import Foundation

/// Formatting of durations in the app's language ("2 мин", "15 с" / "2 min", "15 s", "1:30") and parsing in
/// Russian and English.
public enum DurationText {
    /// "15 с", "2 мин", "1 мин 30 с", "1 ч 5 мин".
    public static func short(_ seconds: TimeInterval) -> String {
        let total = whole(seconds, .toNearestOrAwayFromZero)
        if total < 0 { return "−" + short(TimeInterval(-total)) }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(tr("\(hours) h", ru: "\(hours) ч")) }
        if minutes > 0 { parts.append(tr("\(minutes) min", ru: "\(minutes) мин")) }
        if secs > 0 || parts.isEmpty { parts.append(tr("\(secs) s", ru: "\(secs) с")) }
        return parts.joined(separator: " ")
    }

    /// Very short form for chips: "5с", "30с", "1м", "1м30", "5м" / "5s", "1m", "1m30".
    public static func compact(_ seconds: TimeInterval) -> String {
        let total = whole(seconds, .toNearestOrAwayFromZero)
        let s = tr("s", ru: "с"), m = tr("m", ru: "м")
        if total < 60 { return "\(total)\(s)" }
        let minutes = total / 60
        let secs = total % 60
        return secs == 0 ? "\(minutes)\(m)" : "\(minutes)\(m)\(secs)"
    }

    /// "0:15", "12:03", "1:02:03". Negative values are prefixed with a minus sign.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = whole(seconds, .down)
        let negative = total < 0
        let value = abs(total)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let secs = value % 60
        let body = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
        return negative ? "−" + body : body
    }

    /// Parses "15 с", "2 минуты", "1 мин 30 сек", "2 minutes", "1:30", "90". Returns `nil` when nothing
    /// recognisable is found, and for more than `longestTyped`.
    public static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        guard let value = parseClock(trimmed) ?? sumOfUnits(in: trimmed) ?? decimal(trimmed.replacingOccurrences(of: ",", with: ".")),
              abs(value) <= longestTyped else { return nil }
        return value
    }

    /// The longest time `parse` takes: a day. An exit or a break is minutes; "inf" or "1e400" typed into a
    /// duration field is no time at all.
    public static let longestTyped: TimeInterval = 24 * 3600

    /// Sums every "<number> <unit>" pair found in `text`. Returns `nil` if no unit is present, and for more than
    /// `longestTyped`: «1 выход - 99999999999999999999 секунд» pasted into a plan is no time either.
    public static func sumOfUnits(in text: String) -> TimeInterval? {
        let range = NSRange(text.startIndex..., in: text)
        let matches = unitRegex.matches(in: text, range: range)
        guard !matches.isEmpty else { return nil }

        var total: TimeInterval = 0
        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text) else { continue }
            let valueText = text[valueRange].replacingOccurrences(of: ",", with: ".")
            guard let value = Double(valueText) else { continue }
            total += value * multiplier(forUnit: String(text[unitRange]))
        }
        // Too many digits make an infinite Double: it is past the limit too.
        return total <= longestTyped ? total : nil
    }

    /// Whole seconds as the formatters count them, for any number (a plan from elsewhere may carry one): `Int(_:)`
    /// traps on NaN, infinity and past `Int.max`.
    public static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        whole(seconds, .toNearestOrAwayFromZero)
    }

    /// `Double(text)` for decimals only ("90", "1.5", "2e3"), as on Windows: not "inf", "nan" or "0x1p4".
    private static func decimal(_ text: String) -> Double? {
        guard text.range(of: #"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
        else { return nil }
        return Double(text)
    }

    /// Whole seconds for the formatters. `Int(_:)` traps on NaN, infinity and anything past `Int.max`: such a time is
    /// cut to 68 years (NaN to 0), which no real one comes near.
    private static func whole(_ seconds: TimeInterval, _ rule: FloatingPointRoundingRule) -> Int {
        guard !seconds.isNaN else { return 0 }
        let limit = TimeInterval(Int32.max)
        return Int(min(max(seconds, -limit), limit).rounded(rule))
    }

    private static func parseClock(_ text: String) -> TimeInterval? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = clockRegex.firstMatch(in: text, range: range) else { return nil }
        // Not Int: "9999999999999999:00" would overflow it.
        var parts: [TimeInterval] = []
        for index in 1..<match.numberOfRanges {
            guard let partRange = Range(match.range(at: index), in: text) else { continue }
            if let value = TimeInterval(text[partRange]) { parts.append(value) }
        }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    private static func multiplier(forUnit unit: String) -> TimeInterval {
        guard let first = unit.lowercased().first else { return 1 }
        switch first {
        case "ч", "h": return 3600
        case "м", "m": return 60
        default: return 1
        }
    }

    private static let clockRegex = try! NSRegularExpression(
        pattern: #"^(\d+):(\d{1,2})(?::(\d{1,2}))?$"#
    )

    // Order matters: longer unit spellings must be tried before the single-letter ones.
    private static let unitRegex = try! NSRegularExpression(
        pattern: #"(\d+(?:[.,]\d+)?)\s*(час\p{L}*|hour\p{L}*|hr\p{L}*|мин\p{L}*|min\p{L}*|сек\p{L}*|sec\p{L}*|ч|h|м|m|с|s)(?![\p{L}])"#,
        options: [.caseInsensitive]
    )
}
