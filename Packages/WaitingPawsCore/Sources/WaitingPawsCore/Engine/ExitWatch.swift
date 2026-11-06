import Foundation

/// What the owner saw from behind the door, marked with a tap on one of the exit's conditions: «Легла» starts its
/// countdown to coming back early; the trainer's rule against coming in has two marks — «лает» (no count: wait) and
/// «замолчала», from which the quiet the trainer asked for is counted (`TrainingPlan.Rule.quietTime`). The readout's big number then answers the one question behind the door: come in now, in how long,
/// or not yet. It only holds for the exit and the attempt it was made on, and only on the device that was tapped
/// (the app does not see the dog: it times what the owner saw).
public struct ExitWatch: Equatable {
    /// The exit it was made on (`PlannedExit.id`) and its attempt: a false start or the next exit forgets it.
    public let exitID: UUID
    public let attempt: Int
    /// The condition seen last («Легла») and when.
    public private(set) var entry: EarlyEntry?
    public private(set) var entryAt: Date?
    /// The dog is barking now («Залаяла, завыла»): nothing counts until she is quiet.
    public private(set) var barking = false
    /// When she went quiet: the quiet counts from there (a new «лает» takes it back).
    public private(set) var quietSince: Date?

    /// The rule against coming in is being watched (barking, or counting the quiet).
    public var watchesQuiet: Bool { barking || quietSince != nil }

    public init(exitID: UUID, attempt: Int) {
        self.exitID = exitID
        self.attempt = attempt
    }

    /// What the big number says.
    public enum Verdict: Equatable {
        /// Nothing marked: the plan's countdown.
        case plan
        /// «Легла — входите через 0:12».
        case comeBackIn(TimeInterval, entry: EarlyEntry)
        /// «Легла 0:40 назад — через пару минут»: the trainer's words for a time the parser couldn't read.
        case comeBackAfter(String, elapsed: TimeInterval, entry: EarlyEntry)
        /// The condition's time is up, or the dog has been quiet long enough (`entry` nil).
        case canComeIn(entry: EarlyEntry?)
        /// «Лает»: wait, nothing counts yet (`needed`: the quiet the rule asks for).
        case barking(needed: TimeInterval?)
        /// «Тишина 0:12 из 0:30»: quiet since she stopped, not long enough yet (`needed` nil: the rule gives no time).
        case waitForQuiet(quiet: TimeInterval, needed: TimeInterval?)
    }

    /// Nothing marked.
    public var isEmpty: Bool { entry == nil && !watchesQuiet }

    /// A tap on a condition always means «seen now»: its countdown starts (again, if it was running). One gesture,
    /// one meaning on every chip; taking a mark back is `clear()`.
    public mutating func mark(_ entry: EarlyEntry, at time: Date) {
        self.entry = entry
        entryAt = time
    }

    /// «Лает»: the dog is heard now; the quiet is not counted until `markQuiet`.
    public mutating func markBarking(at time: Date) {
        barking = true
        quietSince = nil
    }

    /// «Замолчала»: the quiet counts from now.
    public mutating func markQuiet(at time: Date) {
        barking = false
        quietSince = time
    }

    /// Takes every mark of the exit back (✕ next to what the big number says).
    public mutating func clear() {
        entry = nil
        entryAt = nil
        barking = false
        quietSince = nil
    }

    public func verdict(at now: Date, quietNeeded: TimeInterval?) -> Verdict {
        if barking { return .barking(needed: quietNeeded) }
        if let quietSince {
            let quiet = max(0, now.timeIntervalSince(quietSince))
            guard let quietNeeded, quiet >= quietNeeded else { return .waitForQuiet(quiet: quiet, needed: quietNeeded) }
        }
        if let entry, let entryAt {
            let elapsed = max(0, now.timeIntervalSince(entryAt))
            if let delay = entry.delay, delay > 0 {
                return elapsed < delay ? .comeBackIn(delay - elapsed, entry: entry) : .canComeIn(entry: entry)
            }
            if let words = entry.unreadDelay { return .comeBackAfter(words, elapsed: elapsed, entry: entry) }
            return .canComeIn(entry: entry)
        }
        return quietSince == nil ? .plan : .canComeIn(entry: nil)
    }

    /// When the verdict next changes by itself (a countdown runs out): for a signal at that moment. `nil` when
    /// nothing is counting down.
    public func nextChange(after now: Date, quietNeeded: TimeInterval?) -> Date? {
        var dates: [Date] = []
        if !barking, let quietSince, let quietNeeded {
            dates.append(quietSince.addingTimeInterval(quietNeeded))
        }
        if let entry, let entryAt, let delay = entry.delay, delay > 0 {
            dates.append(entryAt.addingTimeInterval(delay))
        }
        return dates.filter { $0 > now }.min()
    }
}

extension TrainingPlan.Rule {
    /// «…входим когда молчала 30 секунд»: how long the dog must be quiet before coming in, if the rule says.
    public var quietTime: TimeInterval? {
        let source = detail.isEmpty ? text : detail
        let range = NSRange(source.startIndex..., in: source)
        for match in Self.timeRegex.matches(in: source, range: range) {
            guard let found = Range(match.range, in: source),
                  let seconds = DurationText.sumOfUnits(in: String(source[found])), seconds > 0 else { continue }
            return seconds
        }
        return nil
    }

    /// «30 секунд», «1 минуту», "30 seconds", "1.5 min".
    private static let timeRegex = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?\s*\p{L}+"#)
}
