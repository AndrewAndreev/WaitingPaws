import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The iPhone's widget extension: only the Live Activity of a running training (no Home Screen widgets).
@main
struct WaitingPawsWidgets: WidgetBundle {
    var body: some Widget {
        TrainingLiveActivity()
    }
}

/// The training on the lock screen and in the Dynamic Island: where it is, one big number in the phase colour and the
/// app's main step as a button («Вернулись», «Вышли»). The app sends a new state only when something changes (a step,
/// the big number's kind); the numbers tick here by themselves from the dates in it, and at the end of a countdown the
/// card turns to what follows by itself too (`AtEnd`).
struct TrainingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainingActivityAttributes.self) { context in
            TrainingLockScreenView(state: context.state,
                                   readout: context.state.readout(at: .now, isStale: context.isStale),
                                   training: context.attributes.training)
                .activityBackgroundTint(LivePalette.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let readout = state.readout(at: .now, isStale: context.isStale)
            return DynamicIsland {
                // Beside the camera there are some 105 pt a side: the title on the left, the ⚡ of a break and «с Mac
                // в …» of old news on the right.
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    TitleRow(state: state, readout: readout, size: 15, glyph: 13, fits: true)
                        .padding(.leading, 8)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CornerNote(state: state, size: 11)
                        .padding(.trailing, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AtEnd(state: state, readout: readout) { shown in
                        ReadoutBody(state: state, readout: shown, training: context.attributes.training,
                                    number: 40, button: 38, gap: 10, progressGap: 6)
                    }
                    // Clear of the island's rounded bottom corners.
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                AtEnd(state: state, readout: readout, alignment: .center) { shown in
                    GlyphView(glyph: shown.glyph, size: 15)
                        .foregroundStyle(shown.tone.color)
                }
            } compactTrailing: {
                AtEnd(state: state, readout: readout, alignment: .trailing) { shown in
                    CompactValue(readout: shown, size: 15, width: 46)
                }
            } minimal: {
                AtEnd(state: state, readout: readout, alignment: .center) { shown in
                    if shown.ticks {
                        CompactValue(readout: shown, size: 12, width: 38)
                    } else {
                        GlyphView(glyph: shown.glyph, size: 13)
                            .foregroundStyle(shown.tone.color)
                    }
                }
            }
            .keylineTint(readout.tone.color)
        }
    }
}

// MARK: - Lock screen

/// «⇥ Выход 3 из 5», the big number with the step button beside it, the progress line. In a break «⚡ взять ключи»
/// after the title; a Mac's training heard of no more, «🕓 с Mac в 19:04» in the corner.
struct TrainingLockScreenView: View {
    let state: TrainingActivityAttributes.ContentState
    let readout: TrainingActivityAttributes.Readout
    let training: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TitleRow(state: state, readout: readout, size: 16, glyph: 14)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                if let updated = state.updated { UpdatedText(updated: updated, size: 12) }
            }
            AtEnd(state: state, readout: readout) { shown in
                ReadoutBody(state: state, readout: shown, training: training, number: 48, button: 44, gap: 12,
                            progressGap: 8)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
    }
}

// MARK: - Pieces

/// The big number with the step button beside it, and the progress line: the part of the card that turns into `then`
/// at the end of a countdown.
private struct ReadoutBody: View {
    let state: TrainingActivityAttributes.ContentState
    let readout: TrainingActivityAttributes.Readout
    let training: String
    let number: CGFloat
    let button: CGFloat
    let gap: CGFloat
    let progressGap: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: gap) {
                BigValue(readout: readout, size: number)
                if let step = state.step {
                    StepPill(step: step, training: training, height: button)
                } else if let open = state.openApp {
                    OpenPill(title: open, height: button)
                }
            }
            if readout.hidesProgress != true {
                ProgressLine(readout: readout)
                    .padding(.top, progressGap)
            }
        }
    }
}

/// The state's sign, «Выход 3» and «из 5»; in a break, «⚡ взять ключи» after them. The sign switches with the readout
/// at the end of a countdown (`AtEnd`). `fits`: beside the island's camera, no sign (the compact island shows it, and
/// «Выход 3 из 5» leaves it no room — it came and went from card to card) and «из 5» where it fits.
private struct TitleRow: View {
    let state: TrainingActivityAttributes.ContentState
    let readout: TrainingActivityAttributes.Readout
    let size: CGFloat
    let glyph: CGFloat
    var fits = false

    var body: some View {
        if fits {
            ViewThatFits(in: .horizontal) {
                row(glyph: false, position: true)
                row(glyph: false, position: false)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                row(glyph: true, position: true)
                    .fixedSize()
                if let triggers = state.triggers {
                    // The words where they fit, else the ⚡ alone.
                    ViewThatFits(in: .horizontal) {
                        TriggerText(triggers: triggers, size: size * 0.85)
                        TriggerText(triggers: nil, size: size * 0.85)
                    }
                }
            }
        }
    }

    private func row(glyph showsGlyph: Bool, position showsPosition: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if showsGlyph {
                AtEnd(state: state, readout: readout, alignment: .center) { shown in
                    GlyphView(glyph: shown.glyph, size: glyph)
                        .foregroundStyle(shown.tone.color)
                }
                // Centred on the title's capitals (their middle is some 0.35 of the size over the baseline).
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + size * 0.35 }
            }
            Text(state.title)
                .font(.system(size: size, weight: .bold, design: .rounded))
            if showsPosition, let position = state.position {
                Text(position)
                    .font(.system(size: size * 0.8, weight: .semibold, design: .rounded))
                    .foregroundStyle(LivePalette.quiet)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.white)
    }
}

/// «⚡ взять ключи»: what to take for the next exit, the trainer's ⚡ in the app's colour of it (`Theme.warning`, as on
/// the plan's chips); the words nil: the ⚡ alone.
private struct TriggerText: View {
    let triggers: String?
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(TrainingActivityAttributes.Tone.orange.color)
            if let triggers {
                Text(triggers)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// «🕓 с Mac в 19:04», quiet.
private struct UpdatedText: View {
    let updated: TrainingActivityAttributes.Updated
    let size: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
            Text(updated.text)
        }
        .font(.system(size: size, weight: .medium, design: .rounded))
        .foregroundStyle(LivePalette.quiet)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(updated.spoken)
    }
}

/// The expanded island's corner beside its camera: «⚡ взять ключи» in a break, «🕓 с Mac в 19:04» once the news is
/// old; both where they fit, else the ⚡ alone beside the clock's words.
private struct CornerNote: View {
    let state: TrainingActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(words: true, updated: true)
            row(words: false, updated: true)
            row(words: true, updated: false)
            row(words: false, updated: false)
        }
    }

    @ViewBuilder
    private func row(words: Bool, updated showsUpdated: Bool) -> some View {
        HStack(spacing: 6) {
            if let triggers = state.triggers { TriggerText(triggers: words ? triggers : nil, size: size + 1) }
            if showsUpdated, let updated = state.updated { UpdatedText(updated: updated, size: size) }
        }
    }
}

/// `content` drawn for the readout until its countdown runs out, and for `then` from that moment on: the exit's «0:00»
/// becomes a yellow «+0:01…» — on time, with the app suspended. Nothing can redraw a Live Activity then (a local
/// notification doesn't wake the app), and iOS draws `then` only once it marks the activity stale, in practice minutes
/// after `staleDate`; until then the countdown sat at 0:00 (design council, round 7). So both are drawn, one over the
/// other, each under a mask that the system itself moves on with the clock: a progress line over the quarter second at
/// the end (`ProgressView(timerInterval:)`), empty before it and full after, or the other way round, stretched over the
/// view. Its track is faint but not clear (some 25 %), so each mask is laid on four times: the track's alpha to the
/// fourth leaves no trace (cubed, a hidden yellow «+0:53» still showed a level or two over the dark card). (A text of
/// a format of its own, `DiscreteFormatStyle`, would switch by itself too, but a Live Activity with one is drawn only
/// as a placeholder.)
private struct AtEnd<Content: View>: View {
    let state: TrainingActivityAttributes.ContentState
    let readout: TrainingActivityAttributes.Readout
    var alignment: Alignment = .topLeading
    @ViewBuilder let content: (TrainingActivityAttributes.Readout) -> Content

    var body: some View {
        if let end = readout.endsAt, let then = state.then, readout == state.status {
            ZStack(alignment: alignment) {
                content(readout).shown(until: end)
                // Read out once, as it is drawn until the moment (VoiceOver can't follow the masks).
                content(then).shown(from: end)
                    .accessibilityHidden(true)
            }
        } else {
            content(readout)
        }
    }
}

private extension View {
    func shown(until moment: Date) -> some View { switched(at: moment, appears: false) }
    func shown(from moment: Date) -> some View { switched(at: moment, appears: true) }

    func switched(at moment: Date, appears: Bool) -> some View {
        mask { SwitchMask(moment: moment, appears: appears) }
            .mask { SwitchMask(moment: moment, appears: appears) }
            .mask { SwitchMask(moment: moment, appears: appears) }
            .mask { SwitchMask(moment: moment, appears: appears) }
    }
}

/// Opaque before `moment` and clear after it, or (`appears`) the other way round, by itself (`AtEnd`).
private struct SwitchMask: View {
    let moment: Date
    let appears: Bool

    var body: some View {
        ProgressView(timerInterval: moment...moment.addingTimeInterval(0.25), countsDown: !appears) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .progressViewStyle(.linear)
        .tint(.white)
        .labelsHidden()
        // A line some 4 pt tall with round ends, over the whole view and past its sides.
        .scaleEffect(x: 1.5, y: 60)
    }
}

/// The main step of the app as one pill in the colour of the phase it starts, the app's door icon in it: «Вернулись»
/// blue (the break), «Вышли» pink (the exit). Its colour never changes. The press runs in the app
/// (`TrainingStepIntent`).
private struct StepPill: View {
    let step: TrainingActivityAttributes.StepButton
    let training: String
    let height: CGFloat

    var body: some View {
        Button(intent: TrainingStepIntent(step: step.kind, training: training)) {
            HStack(spacing: 7) {
                DoorArrowShape(entering: step.kind == .backInside)
                    .stroke(style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(step.title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 18)
            .frame(height: height)
            .foregroundStyle(.black)
            .background(step.kind.tint, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// «Открыть» where the step button would be while the Mac can't be reached: grey with the ring, as a button that is
/// there but doesn't press the training on. Not a button of its own: a tap on it is the card's, which opens the app
/// (and the app finds the Mac again).
private struct OpenPill: View {
    let title: String
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .frame(height: height)
        .foregroundStyle(.white)
        .background(LivePalette.control, in: Capsule())
        .overlay(Capsule().strokeBorder(LivePalette.ring, lineWidth: 1.5))
        .fixedSize()
    }
}

/// The big number: counting down to `endsAt`, up from `countsUpFrom` («+0:05» past the plan, yellow), or the words
/// («Нет связи с Mac»).
private struct BigValue: View {
    let readout: TrainingActivityAttributes.Readout
    let size: CGFloat

    var body: some View {
        Group {
            if readout.isWords {
                Text(readout.value)
                    .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
            } else {
                TimerText(readout: readout)
                    .font(.system(size: size, weight: .bold, design: .rounded))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        // A timer text takes all the width it may need and centres itself in it.
        .multilineTextAlignment(.leading)
        .foregroundStyle(readout.tintsValue ? readout.tone.color : .white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The ticking time of a readout; the frozen value when it has no date.
private struct TimerText: View {
    let readout: TrainingActivityAttributes.Readout

    var body: some View {
        if let endsAt = readout.endsAt {
            Text(timerInterval: min(Date.now, endsAt)...endsAt, countsDown: true)
        } else if let since = readout.countsUpFrom {
            if readout.plus {
                Text("+\(Text(since, style: .timer))")
            } else {
                Text(since, style: .timer)
            }
        } else {
            Text(readout.value)
        }
    }
}

/// The compact island's number in the phase colour; nothing for words («Нет связи с Mac»): the yellow crossed-out
/// Wi-Fi beside it says it, and the expanded island has the words (design council, round 13).
private struct CompactValue: View {
    let readout: TrainingActivityAttributes.Readout
    let size: CGFloat
    let width: CGFloat

    var body: some View {
        if readout.ticks || !readout.isWords {
            TimerText(readout: readout)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: width, alignment: .trailing)
                .lineLimit(1)
                .foregroundStyle(readout.tone.color)
        }
    }
}

/// The phase's sign (`TrainingActivityAttributes.Glyph`): the app's door with the arrow out for an exit, ⏸ for a break
/// (the app's), the crossed-out Wi-Fi when the Mac can't be reached.
private struct GlyphView: View {
    let glyph: TrainingActivityAttributes.Glyph
    let size: CGFloat

    var body: some View {
        Group {
            switch glyph {
            case .outside: door(entering: false)
            case .rest: symbol("pause.circle.fill")
            case .done: symbol("flag.checkered")
            case .noLink: symbol("wifi.slash")
            }
        }
        .accessibilityHidden(true)
    }

    private func door(entering: Bool) -> some View {
        DoorArrowShape(entering: entering)
            .stroke(style: StrokeStyle(lineWidth: max(1.8, size * 0.14), lineCap: .round, lineJoin: .round))
            .frame(width: size * 1.3, height: size * 1.3)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .bold))
    }
}

/// A thin line filling up to the end of the countdown by itself; full past the plan.
private struct ProgressLine: View {
    let readout: TrainingActivityAttributes.Readout

    var body: some View {
        Group {
            if let from = readout.progressFrom, let end = readout.endsAt, from < end {
                ProgressView(timerInterval: from...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: readout.progressFull ? 1 : 0)
            }
        }
        .progressViewStyle(.linear)
        .tint(readout.tone.color)
        .labelsHidden()
    }
}

// MARK: - Colours

/// The app's `Theme`, which the extension does not compile.
enum LivePalette {
    static let background = Color(white: 0.07).opacity(0.92)
    static let quiet = Color.white.opacity(0.6)
    /// The app's `Theme.control`: a button that is there but doesn't press the training on («Открыть»).
    static let control = Color(white: 0.22)
    /// The ring of such a button, as the app's (`BigButton`'s held look): there to press, not switched off.
    static let ring = Color.white.opacity(0.32)
}

extension TrainingActivityAttributes.Tone {
    var color: Color {
        switch self {
        case .pink: return Color(red: 1.00, green: 0.72, blue: 0.80)
        case .blue: return Color(red: 0.55, green: 0.75, blue: 1.00)
        // The app's `Theme.overtime` (`SessionHUD.swift`): past the plan.
        case .yellow: return Color(red: 1.00, green: 0.87, blue: 0.27)
        // The app's `Theme.warning`: the false start's orange, here the lost link and the trigger's ⚡.
        case .orange: return Color(red: 1.00, green: 0.72, blue: 0.30)
        }
    }
}

extension TrainingActivityAttributes.Step {
    /// The colour of the phase the step starts, as on the app's buttons: blue for the break, pink for the exit.
    var tint: Color {
        switch self {
        case .outside: return TrainingActivityAttributes.Tone.pink.color
        case .backInside: return TrainingActivityAttributes.Tone.blue.color
        }
    }
}

extension TrainingActivityAttributes.Readout {
    /// The number ticks by itself.
    var ticks: Bool { endsAt != nil || countsUpFrom != nil }
}
