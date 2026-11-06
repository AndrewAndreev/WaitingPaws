import ActivityKit
import Foundation

/// The running training on the lock screen and in the Dynamic Island: where it is («Выход 3 из 5», «Перерыв»), the big
/// number in the phase colour and the app's main step as a button — little else (design council, round 12: a glance,
/// not a small remote; the trainer's conditions are read in the app). The app keeps it up to date (`TrainingGlance`);
/// the widget extension only draws it. Every text arrives already localized by the app, so the extension has no strings
/// of its own, and the timers count by themselves from the dates (the app is often in the background, and then it
/// can't update anything).
struct TrainingActivityAttributes: ActivityAttributes {
    /// Which training this is (`TrainingGlance.trainingID`): a press on the step button acts only on it.
    var training: String

    struct ContentState: Codable, Hashable {
        /// «Выход 3», «Перерыв», «Ещё выход».
        var title: String
        /// «из 5».
        var position: String?
        /// The big number now.
        var status: Readout
        /// What `status` turns into when its countdown runs out (`status.endsAt`) and the app can't say so itself
        /// (suspended): the exit's «0:00» becomes a yellow «+0:01…». The extension draws it from that moment on by
        /// itself (`AtEnd`), not only once iOS marks the activity stale.
        var then: Readout?
        /// Before an exit (a break, or the first exit not started), what to take for it by the trainer's text: «взять
        /// ключи», after a ⚡. Nil without one, and outside.
        var triggers: String?
        /// A Mac's training whose news the iPhone no longer hears (the app is about to be suspended): when it last did,
        /// quiet in the corner («🕓 с Mac в 19:04»). Nil while the news is current.
        var updated: Updated?
        /// The main step as a button: «Вернулись» outside, «Вышли» in a break. Never «Завершить» or «Фальстарт» (too
        /// easy to hit by mistake from a pocket); none while a Mac's training can't be reached. Its colour is the
        /// step's own, always.
        var step: StepButton?
        /// In the step button's place where there is none because the Mac can't be reached: «Открыть», quiet — the
        /// app, opened, finds the Mac again. A tap on it is a tap on the card, which opens the app.
        var openApp: String?

        /// The readout to draw at `now`: the next one once the countdown has run out.
        func readout(at now: Date, isStale: Bool) -> Readout {
            guard let then else { return status }
            if isStale { return then }
            if let endsAt = status.endsAt, endsAt <= now { return then }
            return status
        }
    }

    /// One state of the big number.
    struct Readout: Codable, Hashable {
        var tone: Tone
        /// What is going on, for the Dynamic Island's corner (the compact island has no room for words).
        var glyph: Glyph
        /// The number frozen at the update («0:15» before the first exit), or the words («Нет связи с Mac»): shown
        /// when there is no date to count from. The compact island has no room for words: its sign says it alone.
        var value: String
        var isWords: Bool
        /// Counts down to this date…
        var endsAt: Date?
        /// …or up from this one (with `plus`: «+0:05» past the plan).
        var countsUpFrom: Date?
        var plus: Bool
        /// The number in the phase colour (past the plan, no link), not white.
        var tintsValue: Bool
        /// The progress line: filled by itself from `progressFrom` to `endsAt`, or full, or none.
        var progressFrom: Date?
        var progressFull: Bool
        /// No progress line at all (no link: nothing counts).
        var hidesProgress: Bool?
    }

    /// The phase's sign, before the title on the lock screen, alone in the compact island: the door with the arrow out
    /// (an exit), ⏸ (a break: the app's sign of it in the plan), the flag (the training is over — never the check,
    /// which could pass for «come in»), the crossed-out Wi-Fi (the Mac whose training this is can't be reached). It
    /// names the phase and stays across zero (design council, round 13: a door in place of ⏸ once the break ran over
    /// made the sign mean an action); past the plan says the yellow and the «+».
    enum Glyph: String, Codable, Hashable {
        case outside, rest, done, noLink
    }

    /// The phase colours of the app (`Theme`): pink outside, blue in a break, yellow past the plan (`Theme.overtime`,
    /// one yellow everywhere — not the false start's orange); orange for what holds the card back (no link to the Mac,
    /// `Theme.warning`).
    enum Tone: String, Codable, Hashable {
        case pink, blue, yellow, orange
    }

    /// «🕓 с Mac в 19:04»: what the iPhone knew of a Mac's training was last heard then (the app is about to be
    /// suspended, and then it hears nothing; the timers go on from it). The time is in the words, formatted by the app
    /// (its language).
    struct Updated: Codable, Hashable {
        /// «с Mac в 19:04» after the clock sign. The source and «в» stay: «Mac · 19:04» read as the Mac's clock.
        var text: String
        /// VoiceOver says it whole: «Обновлено с Mac в 19:04».
        var spoken: String
        var at: Date
    }

    /// «Вернулись» or «Вышли»: the step the app's main button would take now.
    struct StepButton: Codable, Hashable {
        var kind: Step
        var title: String
    }

    enum Step: String, Codable, Hashable {
        /// «Вышли»: in a break (or before the first exit), the exit's countdown starts.
        case outside
        /// «Вернулись»: outside, back inside; the break begins.
        case backInside
    }
}
