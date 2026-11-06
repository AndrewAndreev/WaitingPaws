#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Right panel during a session, as little as reads at a glance. In the card: the exit strip (where in the plan, what
/// comes next, a repeat's ↺), «Выход 3» or «Перерыв», the exit's conditions in one quiet line only to read (in a break
/// the next exit's ⚡ trigger instead), the big number over a thin line — «+0:05» in orange past the plan. Under the
/// card the two steps, then the trainer's text, open unless the owner folds it. The numbers of the whole training
/// live in the timeline's header, «Завершить» in the toolbar.
struct ConsoleReadout: View {
    @Environment(AppModel.self) private var model
    let session: TrainingSession
    /// The trainer's text under the buttons: the owner's own words, open unless folded (here and before the start).
    @AppStorage(MacTrainerTextFold.key) private var trainerTextOpen = true

    var body: some View {
        let content = ReadoutContent(session: session)
        let exit = Self.shownExit(session)
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                ExitStrip(session: session, large: true)
                header(content)
                    .padding(.top, 12)
                info(exit)
                    .padding(.top, 4)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    // The iPhone's number: the plan's own count (nothing is marked from here); before the first exit
                    // its time quiet; in the last break the break's time counting up, without a line.
                    number(content.phoneStatus(at: context.date))
                }
                .padding(.top, 10)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Never squeezed by a short window: the trainer's text under it gives way instead.
            .fixedSize(horizontal: false, vertical: true)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.32))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07)))
            }
            buttons(content)
            if session.plan.rawText.isEmpty {
                Spacer(minLength: 0)
            } else {
                trainerText(exit)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The exit the card is about: the one under way (or about to start), in a break the next one.
    static func shownExit(_ session: TrainingSession) -> PlannedExit? {
        switch session.phase {
        case .ready, .leaving, .away:
            return session.currentExit
        case .breakTime(_, _, _, let next):
            guard let next, session.plan.exits.indices.contains(next) else { return nil }
            return session.plan.exits[next]
        case .finished:
            return nil
        }
    }

    /// «Выход 3», «Перерыв»: where in the plan and a repeat are on the strip. Right after a «Фальстарт», for as long
    /// as an undo still puts the owner back outside, «Отменить» beside it, a word without a sign (the ↺ is the chip's;
    /// later the menu's «Отменить фальстарт»).
    private func header(_ content: ReadoutContent) -> some View {
        HStack(alignment: .center, spacing: 8) {
            // «Перерыв» for the last break too, as on the iPhone: its buttons say it is the last.
            Text(content.phoneTitle)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if content.isBreak, let undo = model.falseStartUndo {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date.timeIntervalSince(undo.pressedAt) < AppModel.falseStartBackOutsideFor {
                        Button { withAnimation(.smooth(duration: 0.25)) { model.undoFalseStart() } } label: {
                            Text("Отменить")
                        }
                        .buttonStyle(ReadoutCapsuleStyle())
                        .help(String(localized: "Отменить фальстарт выхода \(undo.exitNumber)"))
                        .transition(.opacity)
                    }
                }
            }
        }
        .frame(height: 28)
    }

    /// The line about the exit (`InfoLine`), as tall as the plan's tallest such line: the card keeps one height from
    /// phase to phase.
    private func info(_ exit: PlannedExit?) -> some View {
        let plan = session.plan
        return ZStack(alignment: .topLeading) {
            ForEach(Array(InfoLine.variants(of: plan).enumerated()), id: \.offset) { _, items in
                InfoLine(items: items).hidden().accessibilityHidden(true)
            }
            InfoLine(items: exit.map { InfoLine.items(plan: plan, exit: $0, outside: session.phase.isOutside) } ?? [])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The big number, white («+0:05» in orange past the plan), and the thin line in the phase's colour (full past it).
    private func number(_ status: ReadoutContent.Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.value)
                .font(status.isWords ? .system(size: 46, weight: .bold, design: .rounded)
                                     : MacPalette.digits(88, weight: .semibold))
                .foregroundStyle(status.valueTint != .white ? status.valueTint : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .padding(.vertical, status.isWords ? 8 : -6)
            // Its room kept where nothing is counted down, so the card keeps its height.
            ThinProgress(value: status.progress ?? 0, tint: status.tint, height: 6)
                .opacity(status.progress == nil ? 0 : 1)
                .padding(.bottom, 2)
        }
    }

    /// «Текст тренера ⌃» over the trainer's text, the exit of the moment (its line and the lines under it) one marked
    /// block kept in view, the exits done faded, each exit line with its number; the fold hides it.
    private func trainerText(_ exit: PlannedExit?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MacTrainerTextFold(open: $trainerTextOpen)
            if trainerTextOpen {
                let plan = session.plan
                let lines = MacSourceLine.lines(plan.rawText)
                let link = MacPlanTextLink(plan: plan, lines: lines)
                let current = exit.flatMap { link.ordinals[$0.id] }
                let lit = current.map { MacSourceLine.ids(ofExits: [$0], in: lines) } ?? []
                // Before the exit the card is about (in a break, the next one): done.
                let shown = exit.flatMap { exit in plan.exits.firstIndex { $0.id == exit.id } }
                    ?? (session.isFinished ? plan.exits.count : 0)
                let doneOrdinals = Set(plan.exits.prefix(shown).compactMap { link.ordinals[$0.id] })
                MacTrainerTextView(link: link, lit: lit,
                                   dimmed: MacSourceLine.ids(ofExits: doneOrdinals, in: lines).subtracting(lit),
                                   fontSize: 12.5, colorsOnlyLit: true, focus: lit.min())
                    .frame(maxHeight: .infinity)
                    .background(MacTrainerTextFold.box)
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        #if DEBUG
        .onAppear {
            if CommandLine.arguments.contains("--demo-trainer-text") { trainerTextOpen = true }
            // `--demo-plan-edit`: exit 3 changed to 1 мин 30 с during the training (struck through in the text).
            if CommandLine.arguments.contains("--demo-plan-edit"), session.plan.exits.count > 2 {
                var plan = session.plan
                plan.exits[2].duration = 90
                _ = session.updatePlan(plan, quiet: true)
            }
        }
        #endif
    }

    // MARK: - Buttons

    /// The next step (Space) and the false start (⌫), as on the iPhone: blue toward a break, pink toward an exit.
    /// Before the first exit «Вышли» alone. Outside, «Фальстарт» runs out with the trainer's window («в первые 20
    /// секунд…»), its line shrinking, and folds away; in the last break «Завершить» leads and «Ещё выход» after it
    /// starts an extra exit without a planned time.
    private func buttons(_ content: ReadoutContent) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let falseStartLeft = content.falseStartLeft(at: context.date)
            let beforeFirst: Bool = if case .ready = session.phase { true } else { false }
            let showsFalseStart = content.showsFalseStart(at: context.date) && !beforeFirst
            HStack(spacing: 10) {
                if let step = content.step {
                    StepButton(title: step.title, icon: step.icon, key: String(localized: "Пробел"),
                               fill: step.tint, foreground: .black) {
                        switch step {
                        case .outside: session.markBehindDoor()
                        case .backInside: session.endExit()
                        case .finish: model.finishSession()
                        }
                    }
                }
                if content.canStartOpenExit {
                    StepButton(title: String(localized: "Ещё выход"), icon: .outside, key: nil,
                               fill: .white.opacity(0.08), foreground: .primary) {
                        session.startOpenExit()
                    }
                }
                if showsFalseStart {
                    // Orange, like a false start in the log and the history; what a click does is in the pointer's tip.
                    StepButton(title: String(localized: "Фальстарт"), icon: .symbol("arrow.uturn.backward"), key: "⌫",
                               fill: .white.opacity(0.08), foreground: MacPalette.orange,
                               hint: content.falseStartHint) {
                        model.falseStart()
                    }
                    .accessibilityLabel(content.falseStartAccessibilityLabel)
                    .accessibilityHint(content.falseStartHint ?? "")
                    .overlay(alignment: .bottom) {
                        if let falseStartLeft, let window = session.plan.falseStartWindow {
                            Capsule()
                                .fill(MacPalette.orange.opacity(0.7))
                                .frame(height: 3)
                                .scaleEffect(x: max(0, falseStartLeft / window), anchor: .leading)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 4)
                                .animation(.linear(duration: 0.5), value: falseStartLeft)
                        }
                    }
                    .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.35), value: showsFalseStart)
        }
    }
}

/// One quiet line about the exit, only to read — nothing on it is pressed; the iPhone card's line in its one form
/// (`ConditionsLine`). Outside: its conditions and the rule against coming in, «встала и пошла 0:30 · легла 0:20 ·
/// ⊖ тишина 0:30»; before it (a break, before the first exit) what to take, «⚡ взять ключи». The exit's note after
/// them. It breaks between whole items, a «·» only between two conditions on one line.
private struct InfoLine: View {
    enum Item: Hashable {
        case condition(words: String, time: String)
        case rule(words: String, time: String?)
        case trigger(String)
        case note(String)

        var isCondition: Bool {
            switch self {
            case .condition, .rule: return true
            default: return false
            }
        }
    }

    let items: [Item]
    private static let size: CGFloat = 14

    var body: some View {
        SeparatedFlowLayout(spacing: 5, lineSpacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    if item.isCondition && items[index - 1].isCondition { FlowDot() } else { Color.clear.frame(width: 6, height: 1) }
                }
                view(item)
            }
        }
        .font(.system(size: Self.size, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func view(_ item: Item) -> some View {
        switch item {
        case .condition(let words, let time):
            ConditionsLine.item(words: words, time: time, size: Self.size)
        case .rule(let words, let time):
            ConditionsLine.item(words: words, time: time, size: Self.size, rule: true)
        case .trigger(let text):
            Label {
                Text(verbatim: text).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "bolt.fill").foregroundStyle(Theme.warning)
            }
            .foregroundStyle(.primary)
        case .note(let text):
            Label {
                Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "text.bubble")
            }
        }
    }

    /// Outside the exit: its conditions and the rule; before it: its triggers. Its note in both.
    static func items(plan: TrainingPlan, exit: PlannedExit, outside: Bool) -> [Item] {
        var items: [Item]
        if outside {
            items = plan.earlyEntries(of: exit).map { .condition(words: $0.conditionWords, time: $0.conditionTime) }
            if let rule = plan.doNotEnterRule { items.append(.rule(words: rule.conditionWords, time: rule.conditionTime)) }
        } else {
            items = exit.triggers.map { .trigger($0) }
        }
        if let note = exit.noteText { items.append(.note(note)) }
        return items
    }

    /// Every line the plan can show, each once: the place is as tall as the tallest.
    static func variants(of plan: TrainingPlan) -> [[Item]] {
        var seen = Set<[Item]>()
        var lines: [[Item]] = []
        for exit in plan.exits {
            for outside in [true, false] {
                let items = items(plan: plan, exit: exit, outside: outside)
                if !items.isEmpty, seen.insert(items).inserted { lines.append(items) }
            }
        }
        return lines
    }
}

/// «Текст тренера ⌃» over the trainer's text on the panel, before the start and during the training: a quiet
/// header that folds it; the owner's choice is kept.
struct MacTrainerTextFold: View {
    static let key = "mac.trainerTextOpen"
    @Binding var open: Bool

    /// The text's box under the header.
    static var box: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.black.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Label("Текст тренера", systemImage: "doc.text")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A training step: a 42 pt rounded button, the title centred; its key (Space, ⌫) in the pointer's tip.
private struct StepButton: View {
    let title: String
    let icon: StepIcon.Kind
    let key: String?
    let fill: Color
    let foreground: Color
    /// What a click does, after the title in the pointer's tip.
    var hint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                StepIcon(kind: icon, size: 15)
                Text(title).lineLimit(1)
            }
            .fixedSize()
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(StepButtonStyle(fill: fill, foreground: foreground))
        .help([key.map { "\(title) · \($0)" } ?? title, hint].compactMap { $0 }.joined(separator: " — "))
    }
}

private struct StepButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(height: 42)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// «↶ Отменить» beside «Перерыв»: a small grey capsule, white words, no colour of its own.
private struct ReadoutCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.9))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.1), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Recording without a training: the clock and «Остановить» on a glass panel floating over the picture. In «Только
/// камера» (not recording) the same panel offers to record or to bring the panels back.
/// Drag it anywhere; it settles in the nearest corner or edge middle and stays there next time.
struct ClipRecordingHUD: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @AppStorage("mac.clipHUDPosition") private var position: HUDPosition = .bottom
    @State private var drag: CGSize = .zero
    @State private var hudSize: CGSize = .zero

    enum HUDPosition: String, CaseIterable {
        case topLeading, top, topTrailing, bottomLeading, bottom, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: return .topLeading
            case .top: return .top
            case .topTrailing: return .topTrailing
            case .bottomLeading: return .bottomLeading
            case .bottom: return .bottom
            case .bottomTrailing: return .bottomTrailing
            }
        }

        /// Where the panel's centre sits in an area of `size` for a panel of `hud`.
        func center(in size: CGSize, hud: CGSize, margin: CGFloat) -> CGPoint {
            let left = margin + hud.width / 2, right = size.width - margin - hud.width / 2
            let top = margin + hud.height / 2, bottom = size.height - margin - hud.height / 2
            switch self {
            case .topLeading: return CGPoint(x: left, y: top)
            case .top: return CGPoint(x: size.width / 2, y: top)
            case .topTrailing: return CGPoint(x: right, y: top)
            case .bottomLeading: return CGPoint(x: left, y: bottom)
            case .bottom: return CGPoint(x: size.width / 2, y: bottom)
            case .bottomTrailing: return CGPoint(x: right, y: bottom)
            }
        }
    }

    /// Clear of the camera's own timestamp in the top-left corner.
    private static let margin: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            panel
                .onGeometryChange(for: CGSize.self, of: \.size) { hudSize = $0 }
                .offset(drag)
                .gesture(
                    DragGesture(coordinateSpace: .local)
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            let start = position.center(in: geometry.size, hud: hudSize, margin: Self.margin)
                            let end = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                            let nearest = HUDPosition.allCases.min { a, b in
                                distance(a.center(in: geometry.size, hud: hudSize, margin: Self.margin), end)
                                    < distance(b.center(in: geometry.size, hud: hudSize, margin: Self.margin), end)
                            } ?? .bottom
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                position = nearest
                                drag = .zero
                            }
                        }
                )
                .padding(Self.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position.alignment)
        }
    }

    @ViewBuilder
    private var panel: some View {
        if model.isRecordingNow {
            recordingPanel
        } else {
            watchingPanel
        }
    }

    /// «Только камера»: nothing is recorded; record from here (⌘R) or go back to the panels (Esc).
    private var watchingPanel: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Только камера").font(.system(size: 13, weight: .semibold))
            }
            Button { model.startRecording() } label: {
                ShortcutLabel(title: String(localized: "Запись"), symbol: "record.circle", key: "⌘R")
            }
            .controlSize(.large)
            .disabled(!model.settings.isConfigured)
            Button { ui.cameraOnly = false } label: {
                ShortcutLabel(title: String(localized: "Панели"), symbol: "sidebar.right", key: "esc")
            }
            .controlSize(.large)
            .help("Вернуть расписание и шкалу · ⇧⌘F")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .modifier(HUDGlass())
        .environment(\.colorScheme, .dark)
        .help("Перетащите панель в любой угол")
    }

    /// Dark glass over any picture. Untinted, Liquid Glass turns light over a bright one (a white wall, now that a
    /// zoomed picture fills the window down to the panel): the words went black and the buttons pink, the panel
    /// read as blown out (the owner, 2026-11-06). The owner picked clear glass, the picture's colours showing
    /// through, at twice the darkening of a 45 % tint so the words read well: 80 % darkens the picture under it by
    /// about a quarter.
    static let glass = Glass.clear.tint(.black.opacity(0.8))
    /// An inactive window drops the clear glass's tint and frosts it light: over a white wall the panel all but
    /// vanished, while «Только камера» is often watched from another app. A shade over the glass (under the words)
    /// stands in for the tint there; one under it barely showed through the frost.
    static let inactiveShade = 0.6

    private var recordingPanel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 18) {
                HStack(alignment: .center, spacing: 10) {
                    RecordingDot()
                    Text(DurationText.clock(model.recordingDuration(at: context.date)))
                        .font(MacPalette.digits(34, weight: .medium))
                        .contentTransition(.numericText())
                }
                Text("Запись без тренировки").font(.system(size: 13, weight: .semibold))
                Button { ui.confirmStopRecording = true } label: {
                    ShortcutLabel(title: String(localized: "Остановить"), symbol: "stop.fill", key: "⌘R", prominent: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(MacPalette.red)
                .controlSize(.large)
            }
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .modifier(HUDGlass())
            .environment(\.colorScheme, .dark)
            .help("Перетащите панель в любой угол")
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// The floating panels' glass: `ClipRecordingHUD.glass`, shaded while the window is inactive, with the shadow of the
/// header's pieces floating over the picture (the owner, 2026-11-06: the same shadow, the plate's own glass).
private struct HUDGlass: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(.black.opacity(appearsActive ? 0 : ClipRecordingHUD.inactiveShade)))
            .glassEffect(ClipRecordingHUD.glass, in: .capsule)
            .modifier(FloatingShadow(amount: 1))
    }
}

/// A red dot that breathes while recording.
private struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(MacPalette.red)
            .frame(width: 12, height: 12)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
#endif
