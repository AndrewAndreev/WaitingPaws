#if os(macOS)
import AppKit
import SwiftUI
import WaitingPawsCore

/// Plan vs actual on one time axis, from the first exit on (the wait before it is of no interest: until then the
/// plan slides along with now). The header carries the numbers of the whole training. The plan lane is the schedule
/// itself: click an exit or a break to type its length, or drag its right edge (⇧ snaps to 5 s). Edits apply as they
/// go — the timer follows at once, a linked iPhone gets every step with the next state — and the log notes each one
/// once, when it is done.
struct SessionTimelineView: View {
    let model: LiveSessionModel

    private let labelWidth: CGFloat = 86
    private let laneHeight: CGFloat = 34
    /// Room before the first exit, so its start is not glued to the lane titles.
    private let lead: TimeInterval = 15

    /// One block of the plan: the exit at `index` or the break after it.
    struct PlanEdge: Hashable {
        enum Kind: Hashable { case exit, pause }
        let index: Int
        let kind: Kind
    }

    private struct Segment {
        let start: Date
        let end: Date
        let color: Color
        var label: String? = nil
        var dashed = false
        var strong = false
        /// One bar in two colours: from `split` on it is `splitColor` (an exit or a break past its plan).
        var split: Date? = nil
        var splitColor: Color? = nil
        var edge: PlanEdge? = nil
    }

    private struct EdgeDrag {
        let edge: PlanEdge
        let startValue: TimeInterval
        /// The axis frozen for the drag, so the edge stays under the pointer while the plan grows.
        let axis: ClosedRange<Date>
        let width: CGFloat
    }

    @State private var drag: EdgeDrag?
    @State private var hovered: PlanEdge?
    /// The block whose length is being typed (popover), with the value so far.
    @State private var editing: PlanEdge?
    /// The plan before the drag or the typing: the log notes the whole edit against it.
    @State private var editStart: TrainingPlan?

    private var plan: TrainingPlan { model.plan }

    var body: some View {
        VStack(spacing: 0) {
            TimelineHeader(model: model)
            Divider()
            GeometryReader { geo in
                let width = geo.size.width - labelWidth - 16
                let axis = drag?.axis ?? axisRange
                ZStack(alignment: .topLeading) {
                    ruler(width: width, axis: axis)
                    VStack(alignment: .leading, spacing: 10) {
                        lane(String(localized: "План"), segments: planSegments, width: width, axis: axis)
                        lane(String(localized: "Факт"), segments: factSegments, width: width, axis: axis)
                        lane(String(localized: "Запись"), segments: recordSegments, width: width, axis: axis, height: 14)
                    }
                    .padding(.top, 30)
                    playhead(width: width, axis: axis, height: geo.size.height)
                    if let drag {
                        dragTip(drag, width: width, axis: axis)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        #if DEBUG
        // `--demo-plan-pill N`: the length of exit N open for typing (UI checks).
        .task {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--demo-plan-pill"), i + 1 < args.count, let n = Int(args[i + 1]),
                  model.plan.exits.indices.contains(n - 1) else { return }
            try? await Task.sleep(for: .seconds(1.5))
            beginTyping(PlanEdge(index: n - 1, kind: .exit))
        }
        #endif
    }

    // MARK: - Data

    private var axisRange: ClosedRange<Date> {
        let start = model.planStart
        let planEnd = start.addingTimeInterval(plan.estimatedDuration)
        let end = max(planEnd, model.eta).addingTimeInterval(120)
        return start.addingTimeInterval(-lead)...end
    }

    /// The schedule laid out from the first exit; every block can be edited.
    private var planSegments: [Segment] {
        var t = model.planStart
        var segments: [Segment] = []
        for (index, exit) in plan.exits.enumerated() {
            segments.append(Segment(start: t, end: t.addingTimeInterval(max(exit.duration, 4)), color: MacPalette.pink.opacity(0.85),
                                    label: "\(exit.number)", edge: PlanEdge(index: index, kind: .exit)))
            t = t.addingTimeInterval(exit.duration)
            if index < plan.exits.count - 1 {
                let b = plan.breakAfter(exitAt: index)
                segments.append(Segment(start: t, end: t.addingTimeInterval(b),
                                        color: exit.breakAfter != nil ? MacPalette.breakOwn : MacPalette.breakFill,
                                        label: exit.breakAfter != nil ? DurationText.short(b) : nil,
                                        edge: PlanEdge(index: index, kind: .pause)))
                t = t.addingTimeInterval(b)
            }
        }
        return segments
    }

    private var factSegments: [Segment] {
        var segments: [Segment] = []
        let results = model.session.results
        for (i, r) in results.enumerated() {
            if let left = r.leftAt {
                // A walk to the door only in sessions run from an older iPhone («Начать выход»).
                if left > r.startedAt { segments.append(Segment(start: r.startedAt, end: left, color: .gray.opacity(0.7))) }
                let planned = left.addingTimeInterval(r.plannedDuration)
                // Pink, as planned: the goal is the longer exit, not a «success» colour for a shorter one.
                segments.append(Segment(start: left, end: max(r.endedAt, left.addingTimeInterval(4)),
                                        color: r.falseStart ? MacPalette.orange : MacPalette.pink,
                                        label: r.falseStart ? "↺" : "\(r.number)", strong: true,
                                        split: !r.falseStart && r.endedAt > planned ? planned : nil, splitColor: MacPalette.orange))
            } else if r.falseStart {
                // A false start before «Вышли»: a short mark where the break started over.
                segments.append(Segment(start: r.startedAt, end: max(r.endedAt, r.startedAt.addingTimeInterval(4)),
                                        color: MacPalette.orange, label: "↺", strong: true))
            }
            let next = i + 1 < results.count ? results[i + 1].startedAt : (currentStart ?? model.now)
            let planned = r.endedAt.addingTimeInterval(r.plannedBreak)
            segments.append(Segment(start: r.endedAt, end: next, color: MacPalette.breakFill,
                                    split: next > planned ? planned : nil, splitColor: MacPalette.orange))
        }
        switch model.phase {
        case .leaving(_, let since):
            segments.append(Segment(start: since, end: model.now, color: .gray.opacity(0.7)))
        case .away(let index, let since, let leftAt):
            if leftAt > since { segments.append(Segment(start: since, end: leftAt, color: .gray.opacity(0.7))) }
            let planned = leftAt.addingTimeInterval(plan.exits[index].duration)
            segments.append(Segment(start: leftAt, end: max(model.now, leftAt.addingTimeInterval(1)), color: MacPalette.pink,
                                    label: "\(plan.exits[index].number)", strong: true,
                                    split: model.now > planned ? planned : nil, splitColor: MacPalette.orange))
        default: break
        }
        // What is left, projected from now: the rest of the current exit or break, then the plan as it goes.
        if let index = model.session.currentExitIndex, index < plan.exits.count {
            var t = model.now
            var started = false
            switch model.phase {
            case .away(let i, _, let leftAt):
                t = max(model.now, leftAt.addingTimeInterval(plan.exits[i].duration))
                started = true
            case .leaving:
                started = true
            case .breakTime:
                let left = max(0, model.remaining ?? 0)
                if left > 0 {
                    segments.append(Segment(start: t, end: t.addingTimeInterval(left), color: MacPalette.blue.opacity(0.3), dashed: true))
                }
                t = t.addingTimeInterval(left)
            default: break
            }
            for i in index..<plan.exits.count {
                if i > index || !started {
                    let e = t.addingTimeInterval(max(plan.exits[i].duration, 4))
                    segments.append(Segment(start: t, end: e, color: MacPalette.pink.opacity(0.5), label: "\(plan.exits[i].number)", dashed: true))
                    t = t.addingTimeInterval(plan.exits[i].duration)
                }
                if i < plan.exits.count - 1 {
                    let b = plan.breakAfter(exitAt: i)
                    segments.append(Segment(start: t, end: t.addingTimeInterval(b), color: MacPalette.blue.opacity(0.3), dashed: true))
                    t = t.addingTimeInterval(b)
                }
            }
        }
        return segments
    }

    private var currentStart: Date? {
        switch model.phase {
        case .leaving(_, let since), .away(_, let since, _): return since
        default: return nil
        }
    }

    private var recordSegments: [Segment] {
        guard let since = model.recordingSince else { return [] }
        return [Segment(start: since, end: model.now, color: MacPalette.red.opacity(0.75), label: "REC \(model.recordingText ?? "")")]
    }

    // MARK: - Drawing

    private func x(_ date: Date, width: CGFloat, axis: ClosedRange<Date>) -> CGFloat {
        let total = axis.upperBound.timeIntervalSince(axis.lowerBound)
        return labelWidth + CGFloat(date.timeIntervalSince(axis.lowerBound) / total) * width
    }

    private func pointsPerSecond(width: CGFloat, axis: ClosedRange<Date>) -> CGFloat {
        width / CGFloat(axis.upperBound.timeIntervalSince(axis.lowerBound))
    }

    private func ruler(width: CGFloat, axis: ClosedRange<Date>) -> some View {
        Canvas { context, size in
            let cal = Calendar.current
            var tick = cal.date(bySetting: .second, value: 0, of: axis.lowerBound) ?? axis.lowerBound
            if tick < axis.lowerBound { tick = tick.addingTimeInterval(60) }
            while tick <= axis.upperBound {
                let px = x(tick, width: width, axis: axis)
                let minute = cal.component(.minute, from: tick)
                let major = minute % 5 == 0
                var path = Path()
                path.move(to: CGPoint(x: px, y: major ? 14 : 19))
                path.addLine(to: CGPoint(x: px, y: 24))
                context.stroke(path, with: .color(.secondary.opacity(major ? 0.7 : 0.35)), lineWidth: 1)
                if major {
                    var grid = Path()
                    grid.move(to: CGPoint(x: px, y: 26))
                    grid.addLine(to: CGPoint(x: px, y: size.height))
                    context.stroke(grid, with: .color(.white.opacity(0.05)), lineWidth: 1)
                    context.draw(Text(MacFormat.time.string(from: tick)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                                 at: CGPoint(x: px + 3, y: 7), anchor: .leading)
                }
                tick = tick.addingTimeInterval(60)
            }
        }
    }

    private func lane(_ title: String, segments: [Segment], width: CGFloat, axis: ClosedRange<Date>, height: CGFloat? = nil) -> some View {
        let h = height ?? laneHeight
        return ZStack(alignment: .topLeading) {
            // By position: a lane's blocks keep their order, so a block stays the same view from second to second
            // (its popover and drag survive the redraws).
            ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                // Nothing left of the axis (a recording started before the first exit is cut at its start).
                let x0 = max(labelWidth, x(s.start, width: width, axis: axis))
                let x1 = x(s.end, width: width, axis: axis)
                if x1 > labelWidth {
                    segmentView(s, width: max(2, x1 - x0), height: h, splitAt: s.split.map { x($0, width: width, axis: axis) - x0 })
                        .offset(x: x0)
                }
            }
            // The plan's drag handles above all its blocks: each straddles the edge between two of them.
            ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                if let edge = s.edge {
                    let x1 = x(s.end, width: width, axis: axis)
                    if x1 > labelWidth {
                        handle(edge, height: h, width: width, axis: axis)
                            .offset(x: x1 - 5)
                    }
                }
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth - 10, height: h, alignment: .leading)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(height: h)
    }

    @ViewBuilder
    private func segmentView(_ s: Segment, width w: CGFloat, height h: CGFloat, splitAt: CGFloat?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let lit = s.edge != nil && (s.edge == hovered || s.edge == drag?.edge || s.edge == editing)
        let body = Group {
            if let splitAt, let splitColor = s.splitColor, splitAt > 0, splitAt < w {
                // One bar, two colours: no rounded seam, the overrun is the same stage going on.
                HStack(spacing: 0) {
                    Rectangle().fill(s.color).frame(width: splitAt)
                    Rectangle().fill(splitColor)
                }
                .clipShape(shape)
            } else {
                shape.fill(s.dashed ? AnyShapeStyle(s.color.opacity(0.25)) : AnyShapeStyle(s.color))
            }
        }
        .overlay {
            if s.dashed {
                shape.strokeBorder(s.color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            if lit {
                shape.strokeBorder(.white.opacity(0.7), lineWidth: 1)
            }
        }
        .overlay {
            if let label = s.label, w > 12 || s.strong || h < 20 {
                Text(label)
                    .font(.system(size: h < 20 ? 9 : 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(s.strong || s.edge?.kind == .exit ? Color.black.opacity(0.75) : .primary.opacity(0.85))
                    .fixedSize()
            }
        }
        .frame(width: w, height: h)

        if let edge = s.edge {
            body
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { hovered = edge } else if hovered == edge { hovered = nil }
                }
                .onTapGesture { beginTyping(edge) }
                .popover(isPresented: Binding(get: { editing == edge }, set: { if !$0 { endTyping(edge) } }), arrowEdge: .bottom) {
                    typingEditor(edge)
                }
                .help(edgeTitle(edge) + " — " + String(localized: "щёлкните, чтобы вписать, или тяните край (⇧ — по 5 с)"))
        } else {
            body
        }
    }

    /// Grab zone on the right edge of a plan block: drag to change its length.
    private func handle(_ edge: PlanEdge, height: CGFloat, width: CGFloat, axis: ClosedRange<Date>) -> some View {
        let lit = hovered == edge || drag?.edge == edge
        return Color.clear
            .frame(width: 10, height: height)
            .overlay {
                if lit {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white.opacity(drag?.edge == edge ? 1 : 0.8))
                        .frame(width: 4, height: height - 12)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = edge } else if hovered == edge, drag == nil { hovered = nil }
            }
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in resize(edge, by: value.translation.width, width: width, axis: axis) }
                    .onEnded { _ in finishResize() }
            )
    }

    private func playhead(width: CGFloat, axis: ClosedRange<Date>, height: CGFloat) -> some View {
        let px = x(model.now, width: width, axis: axis)
        return ZStack(alignment: .top) {
            Rectangle().fill(.white).frame(width: 1.5, height: height - 4).offset(y: 4)
            Text(MacFormat.timeSeconds.string(from: model.now))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.black)
                .fixedSize()
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(.white, in: Capsule())
        }
        .frame(width: 64)
        .offset(x: px - 32)
        .allowsHitTesting(false)
    }

    /// «Выход 4 · 0:50 (+0:05)» above the edge being dragged.
    private func dragTip(_ drag: EdgeDrag, width: CGFloat, axis: ClosedRange<Date>) -> some View {
        let value = value(of: drag.edge, in: plan)
        let delta = value - drag.startValue
        let end = planSegments.first { $0.edge == drag.edge }?.end ?? model.now
        let tip = (Text(verbatim: edgeTitle(drag.edge) + " · ") + Text(verbatim: DurationText.clock(value)).fontWeight(.bold)
                   + Text(verbatim: delta == 0 ? "" : " (\(MacPlanFormat.signed(delta)))").foregroundStyle(.black.opacity(0.55)))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.black)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        return tip
            .frame(width: 240)
            .offset(x: min(max(x(end, width: width, axis: axis) - 120, labelWidth), labelWidth + width - 240), y: 4)
            .allowsHitTesting(false)
    }

    // MARK: - Editing the plan

    private func edgeTitle(_ edge: PlanEdge) -> String {
        let number = plan.exits.indices.contains(edge.index) ? plan.exits[edge.index].number : edge.index + 1
        return edge.kind == .exit ? String(localized: "Выход \(number)") : String(localized: "Перерыв после \(number)")
    }

    private func value(of edge: PlanEdge, in plan: TrainingPlan) -> TimeInterval {
        guard plan.exits.indices.contains(edge.index) else { return 0 }
        return edge.kind == .exit ? plan.exits[edge.index].duration : plan.breakAfter(exitAt: edge.index)
    }

    /// `plan` with the block at `edge` set to `value` (a break other than the common one becomes the exit's own).
    private func setting(_ edge: PlanEdge, to value: TimeInterval?, in plan: TrainingPlan) -> TrainingPlan {
        var plan = plan
        guard plan.exits.indices.contains(edge.index) else { return plan }
        switch edge.kind {
        case .exit:
            plan.exits[edge.index].duration = max(0, value ?? plan.exits[edge.index].duration)
        case .pause:
            plan.exits[edge.index].breakAfter = value == nil || value == plan.defaultBreak ? nil : value
        }
        return plan
    }

    /// One step of an edit: applied at once, without a note.
    private func applyStep(_ edited: TrainingPlan) {
        guard edited != model.plan else { return }
        model.session.updatePlan(edited, quiet: true)
    }

    /// The edit is done: one note with everything it changed.
    private func finishEdit() {
        guard let start = editStart else { return }
        editStart = nil
        if model.plan != start { model.session.updatePlan(model.plan, changesSince: start) }
    }

    private func beginTyping(_ edge: PlanEdge) {
        guard drag == nil else { return }
        editStart = model.plan
        editing = edge
    }

    private func endTyping(_ edge: PlanEdge) {
        guard editing == edge else { return }
        editing = nil
        finishEdit()
    }

    /// The typed value goes into the plan as it changes (the timer follows); nil for a break: the common one.
    private func typedValue(_ edge: PlanEdge) -> Binding<TimeInterval?> {
        Binding {
            edge.kind == .pause && model.plan.exits[edge.index].breakAfter == nil ? nil : value(of: edge, in: model.plan)
        } set: { newValue in
            applyStep(setting(edge, to: edge.kind == .exit ? (newValue ?? value(of: edge, in: model.plan)) : newValue, in: model.plan))
        }
    }

    private func typingEditor(_ edge: PlanEdge) -> some View {
        MacDurationEditor(value: typedValue(edge),
                          title: edgeTitle(edge),
                          presets: edge.kind == .exit ? MacPlanFormat.exitPresets : MacPlanFormat.breakPresets,
                          defaultValue: edge.kind == .pause ? model.plan.defaultBreak : nil,
                          tint: edge.kind == .exit ? MacPalette.pink : MacPalette.blue,
                          onClose: { endTyping(edge) })
    }

    private func resize(_ edge: PlanEdge, by dx: CGFloat, width: CGFloat, axis: ClosedRange<Date>) {
        if drag?.edge != edge {
            editing = nil
            editStart = model.plan
            drag = EdgeDrag(edge: edge, startValue: value(of: edge, in: model.plan), axis: axis, width: width)
        }
        guard let drag else { return }
        let raw = drag.startValue + TimeInterval(dx / pointsPerSecond(width: drag.width, axis: drag.axis))
        // Seconds as they come; with ⇧ the 5 s grid.
        let step: TimeInterval = NSEvent.modifierFlags.contains(.shift) ? 5 : 1
        let value = min(max((raw / step).rounded() * step, 0), 60 * 60)
        guard value != self.value(of: edge, in: model.plan) else { return }
        applyStep(setting(edge, to: value, in: model.plan))
        if value.truncatingRemainder(dividingBy: 30) == 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func finishResize() {
        drag = nil
        finishEdit()
    }
}

/// «Таймлайн», the legend, and the whole training at a glance: exits, false starts, how long it runs, the planned
/// end and how far it is from the plan. «Расписание…» opens the schedule in the editor.
private struct TimelineHeader: View {
    let model: LiveSessionModel
    @Environment(AppModel.self) private var app
    @Environment(MacUIState.self) private var ui

    var body: some View {
        HStack(spacing: 14) {
            Text("Таймлайн").font(.headline)
            // The legend goes first when the window is narrow; the numbers stay.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    legendItems
                    Spacer(minLength: 12)
                    stats
                }
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    stats
                }
            }
            Button { ui.editSessionPlan(app) } label: {
                Label("Расписание…", systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)
            .help("Поправить выходы и перерывы прямо во время тренировки · ⌘E")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    @ViewBuilder
    private var legendItems: some View {
        legend(MacPalette.pink, String(localized: "выход"))
        legend(MacPalette.breakFill, String(localized: "перерыв"))
        legend(MacPalette.orange, String(localized: "сверх плана / фальстарт"))
    }

    private var stats: some View {
        let falseStarts = model.session.falseStartsCount
        return HStack(spacing: 16) {
            stat(String(localized: "\(model.session.completedExitsCount) из \(model.plan.exits.count)"), String(localized: "выходов"))
            stat("\(falseStarts)", String(localized: "фальстартов"), tint: falseStarts > 0 ? MacPalette.orange : nil)
            stat(model.sessionElapsed, String(localized: "идёт тренировка"))
            stat("≈ \(MacFormat.time.string(from: model.eta))", String(localized: "конец по плану"))
            if let drift = model.drift, abs(drift) >= 1 {
                stat((drift > 0 ? "+" : "−") + DurationText.clock(abs(drift)), String(localized: "от плана"),
                     tint: drift > 60 ? MacPalette.orange : nil)
                    .help(drift > 0 ? String(localized: "отстаём от плана на \(DurationText.clock(drift))")
                                    : String(localized: "опережаем план на \(DurationText.clock(-drift))"))
            }
        }
        .fixedSize()
    }

    private func stat(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint ?? .primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}
#endif
