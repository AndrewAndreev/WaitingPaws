#if os(macOS)
import AppKit
import SwiftUI
import WaitingPawsCore

/// The plan on the «Пульт» timeline before the start (A6). Drawn like the live «план и факт» timeline:
/// pink exits, blue breaks, a ruler with major grid lines, «Факт» and «Запись» lanes under the plan.
/// Edited with the mouse: drag the right edge of an exit or a break (5 s steps, everything after it moves,
/// a changed break becomes the exit's own break); zoom with a pinch, ⌥-scroll, ⌘−/⌘+ or «По ширине»;
/// scroll sideways when zoomed in, or click/drag the overview strip.
struct MacPlanTimelineEditor: View {
    @Binding var plan: TrainingPlan
    /// The plan as the trainer sent it («Как у тренера»), nil when unknown.
    var original: TrainingPlan?

    @Environment(AppModel.self) private var model

    init(plan: Binding<TrainingPlan>, original: TrainingPlan?) {
        _plan = plan
        self.original = original
    }

    /// Right edge of one block: the exit at `index` or the break after it.
    struct BlockEdge: Hashable {
        enum Kind: Hashable { case exit, pause }
        let index: Int
        let kind: Kind
    }

    private struct EdgeDrag {
        let edge: BlockEdge
        let startValue: TimeInterval
        /// Axis span and scale frozen for the drag, so the edge stays under the pointer while the plan grows.
        let span: TimeInterval
        let pps: CGFloat
    }

    private struct Pinch {
        let zoom: CGFloat
        let anchor: CGFloat
        let time: TimeInterval
    }

    @State private var zoom: CGFloat = 1
    @State private var drag: EdgeDrag?
    @State private var hovered: BlockEdge?
    /// Drawn as if being dragged (DEBUG screenshots only); gone at the first real touch.
    @State private var staged: BlockEdge?
    @State private var viewport: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var position = ScrollPosition()
    @State private var pinch: Pinch?

    // MARK: Geometry

    private let titleWidth: CGFloat = 86
    private let inset: CGFloat = 12
    private let planTop: CGFloat = 30
    private let planHeight: CGFloat = 46
    private let factHeight: CGFloat = 22
    private let recordHeight: CGFloat = 14
    private let laneGap: CGFloat = 10
    private let footerHeight: CGFloat = 24
    private static let zoomSteps: [CGFloat] = [1, 1.5, 2, 3, 4, 6, 8, 12]
    private static let snap: TimeInterval = 5

    private var factTop: CGFloat { planTop + planHeight + laneGap }
    private var recordTop: CGFloat { factTop + factHeight + laneGap }

    /// Room after the plan for the finish flag and its time.
    private let trailingRoom: CGFloat = 72

    /// Seconds that fit the width at 100 %: the longer of the two plans.
    private var fitSpan: TimeInterval {
        max(60, original?.estimatedDuration ?? 0, plan.estimatedDuration)
    }
    private var span: TimeInterval { drag?.span ?? fitSpan }

    private func pointsPerSecond(_ width: CGFloat, zoom: CGFloat? = nil) -> CGFloat {
        max(120, width - inset - trailingRoom) / span * (zoom ?? self.zoom)
    }

    private func contentWidth(_ width: CGFloat, zoom: CGFloat? = nil) -> CGFloat {
        let pps = pointsPerSecond(width, zoom: zoom)
        return max(width, inset + max(span, plan.estimatedDuration) * pps + trailingRoom)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if plan.exits.isEmpty {
                Text("В расписании нет выходов")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    laneTitles
                        .frame(width: titleWidth, alignment: .leading)
                    GeometryReader { geo in
                        ScrollView(.horizontal) {
                            lanes(width: geo.size.width, height: geo.size.height)
                        }
                        .scrollPosition($position)
                        .scrollIndicators(zoom > 1.001 ? .visible : .hidden)
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in offset = x }
                        .onChange(of: geo.size.width, initial: true) { _, width in viewport = width }
                        .background(OptionScrollZoom { factor, x in setZoom(zoom * factor, anchor: x) })
                        .simultaneousGesture(magnify)
                    }
                }
                HStack(spacing: 0) {
                    Color.clear.frame(width: titleWidth)
                    footer
                }
                .frame(height: footerHeight)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .pointerStyle(drag == nil ? nil : PointerStyle.frameResize(position: .trailing))
        #if DEBUG
        .task { await debugStage() }
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("План").font(.headline)
            Text("\(MacPlanFormat.exits(plan.exits.count)) · \(MacPlanFormat.approx(plan.estimatedDuration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            if let original, differs(from: original) {
                deviation(from: original)
            }
            Spacer(minLength: 12)
            ViewThatFits(in: .horizontal) {
                hint("Тяните край блока, чтобы изменить длительность")
                hint("Тяните край блока")
                Color.clear.frame(width: 0, height: 0)
            }
            Divider().frame(height: 16)
            zoomControls
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private func hint(_ text: String) -> some View {
        Label(text, systemImage: "arrow.left.and.right")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// «+0:30 к плану тренера» and «Как у тренера».
    private func deviation(from original: TrainingPlan) -> some View {
        let delta = plan.estimatedDuration - original.estimatedDuration
        return HStack(spacing: 8) {
            Text(delta == 0 ? "изменён" : "\(MacPlanFormat.signed(delta)) к плану тренера")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(MacPalette.pink)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(MacPalette.pink.opacity(0.16), in: Capsule())
                .fixedSize()
            Button("Как у тренера", systemImage: "arrow.uturn.backward") {
                withAnimation(.snappy) {
                    plan.exits = original.exits
                    plan.defaultBreak = original.defaultBreak
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Вернуть выходы и перерывы из текста тренера: \(MacPlanFormat.approx(original.estimatedDuration))")
        }
    }

    /// Exits, their order and the effective breaks differ from the trainer's plan (title edits don't count).
    private func differs(from original: TrainingPlan) -> Bool {
        struct Slot: Equatable {
            let id: UUID
            let duration: TimeInterval
            let pause: TimeInterval
            let untilStanding: Bool
        }
        func schedule(_ plan: TrainingPlan) -> [Slot] {
            plan.exits.indices.map { i in
                Slot(id: plan.exits[i].id, duration: plan.exits[i].duration,
                     pause: i < plan.exits.count - 1 ? plan.breakAfter(exitAt: i) : 0,
                     untilStanding: plan.exits[i].untilStanding)
            }
        }
        return schedule(plan) != schedule(original)
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            ControlGroup {
                Button { step(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(zoom <= 1.001)
                    .help("Уменьшить · ⌘−, щипок или ⌥-прокрутка")
                Button { step(1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(zoom >= Self.zoomSteps.last! - 0.001)
                    .help("Увеличить · ⌘+, щипок или ⌥-прокрутка")
            }
            .fixedSize()
            Button("По ширине") { setZoom(1) }
                .buttonStyle(.bordered)
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom <= 1.001)
                .help("Вся тренировка по ширине · ⌘0")
        }
        .controlSize(.small)
    }

    // MARK: Footer

    /// Zoomed in: the whole plan in miniature with the visible part framed (click or drag to scroll).
    /// At 100 %: what the colours mean.
    @ViewBuilder
    private var footer: some View {
        if zoom > 1.001, viewport > 0 {
            overview
        } else {
            HStack(spacing: 14) {
                legend(MacPalette.pink.opacity(0.85), "выход")
                legend(MacPalette.blue.opacity(0.35), "перерыв")
                legend(MacPalette.blue.opacity(0.5), "свой перерыв", stroke: true)
                if original != nil {
                    HStack(spacing: 5) {
                        Circle().fill(.white).frame(width: 5, height: 5)
                        Text("изменено относительно тренера")
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, inset)
            .padding(.bottom, 4)
        }
    }

    private func legend(_ color: Color, _ text: String, stroke: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .strokeBorder(stroke ? MacPalette.blue.opacity(0.9) : .clear, lineWidth: 1)
                .frame(width: 12, height: 8)
            Text(text)
        }
    }

    private var overview: some View {
        GeometryReader { geo in
            let pps = pointsPerSecond(viewport)
            let extent = max(1, (contentWidth(viewport) - inset * 2) / pps)
            let width = max(1, geo.size.width - inset * 2)
            let scale = width / extent
            let from = max(0, (offset - inset) / pps)
            let to = min(extent, (offset + viewport - inset) / pps)
            ZStack(alignment: .leading) {
                ForEach(blocks) { block in
                    let tint = block.edge.kind == .exit
                        ? MacPalette.pink.opacity(0.8)
                        : MacPalette.blue.opacity(block.own ? 0.6 : 0.3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tint)
                        .frame(width: max(1, block.duration * scale - 0.5), height: 6)
                        .offset(x: inset + block.start * scale)
                }
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .strokeBorder(.white.opacity(0.75), lineWidth: 1.5)
                    .frame(width: max(12, (to - from) * scale + 4), height: 16)
                    .offset(x: inset + from * scale - 2)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = (value.location.x - inset) / scale
                        scroll(to: inset + t * pps - viewport / 2)
                    }
            )
            .help("Вся тренировка — щёлкните или тяните, чтобы прокрутить")
        }
        .padding(.bottom, 4)
    }

    // MARK: Lanes

    private var laneTitles: some View {
        ZStack(alignment: .topLeading) {
            laneTitle("План", top: planTop, height: planHeight)
            laneTitle("Факт", top: factTop, height: factHeight)
            laneTitle("Запись", top: recordTop, height: recordHeight)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 14)
    }

    private func laneTitle(_ text: String, top: CGFloat, height: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: height)
            .offset(y: top)
    }

    private func lanes(width: CGFloat, height: CGFloat) -> some View {
        let pps = drag?.pps ?? pointsPerSecond(width)
        let blocks = blocks
        let total = plan.estimatedDuration
        let active = drag?.edge ?? staged
        let full = contentWidth(width)
        let record = model.settings.autoRecord
        // Captions in the empty lanes stay at the visible left edge while scrolling.
        let sticky = min(max(0, offset - inset), max(0, total * pps - 210))
        return ZStack(alignment: .topLeading) {
            ruler(pps: pps, total: total)
            ForEach(blocks) { block in
                blockView(block, pps: pps, active: active == block.edge, hovered: hovered == block.edge)
                    .offset(x: inset + block.start * pps, y: planTop)
            }
            emptyLane(text: "появится после старта", tint: .secondary, width: total * pps,
                      height: factHeight, sticky: sticky)
                .offset(x: inset, y: factTop)
            emptyLane(text: record ? "REC · начнётся со стартом" : "без записи — включите «Записывать видео»",
                      tint: record ? MacPalette.red : .secondary,
                      width: total * pps, height: recordHeight, sticky: sticky, filled: record)
                .offset(x: inset, y: recordTop)
            ForEach(blocks) { block in
                handle(block, pps: pps, active: active == block.edge)
                    .offset(x: inset + block.end * pps - 7, y: planTop)
            }
            if let active, let block = blocks.first(where: { $0.edge == active }) {
                editGuide(block, pps: pps, contentWidth: full)
            }
        }
        .frame(width: full, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    /// Ruler with time from the start (the clock time is unknown until then), grid lines and the finish flag.
    private func ruler(pps: CGFloat, total: TimeInterval) -> some View {
        Canvas { context, size in
            let label = Self.labelStep(pps)
            let minor = Self.minorStep(pps, label: label)
            let end = inset + total * pps
            var t: TimeInterval = 0
            while inset + t * pps <= size.width {
                let x = inset + t * pps
                let major = Int(t) % Int(label) == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: major ? 14 : 19))
                tick.addLine(to: CGPoint(x: x, y: 24))
                context.stroke(tick, with: .color(.secondary.opacity(major ? 0.7 : 0.35)), lineWidth: 1)
                if major {
                    var grid = Path()
                    grid.move(to: CGPoint(x: x, y: 26))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(grid, with: .color(.white.opacity(0.05)), lineWidth: 1)
                    // «+12:40» as in the review table — a bare «17:00» would read as a clock time.
                    // The finish time wins where the two would overlap.
                    if x < end - 46 || x > end + 64 {
                        let text = t == 0 ? "старт" : "+" + DurationText.clock(t)
                        context.draw(Text(text).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                                     at: CGPoint(x: x + 3, y: 7), anchor: .leading)
                    }
                }
                t += minor
            }
            // Finish: where the plan ends if nothing drifts.
            var flag = Path()
            flag.move(to: CGPoint(x: end, y: 2))
            flag.addLine(to: CGPoint(x: end, y: recordTop + recordHeight))
            context.stroke(flag, with: .color(MacPalette.green.opacity(0.9)), lineWidth: 1.5)
            context.draw(Text("\(Image(systemName: "flag.checkered")) \(DurationText.clock(total))")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(MacPalette.green),
                         at: CGPoint(x: end + 4, y: 8), anchor: .leading)
        }
        .allowsHitTesting(false)
    }

    private func blockView(_ block: Block, pps: CGFloat, active: Bool, hovered: Bool) -> some View {
        let width = max(2, block.duration * pps - 1)
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let lit = active || hovered
        return Group {
            switch block.edge.kind {
            case .exit:
                shape.fill(MacPalette.pink.opacity(lit ? 1 : 0.85))
                    .overlay { exitLabel(block, width: width) }
            case .pause:
                shape.fill(MacPalette.blue.opacity((block.own ? 0.38 : 0.2) + (lit ? 0.1 : 0)))
                    .overlay {
                        if block.own { shape.strokeBorder(MacPalette.blue.opacity(0.9), lineWidth: 1) }
                    }
                    .overlay { pauseLabel(block, width: width) }
            }
        }
        .overlay {
            if active { shape.strokeBorder(.white.opacity(0.55), lineWidth: 1) }
        }
        .overlay(alignment: .topLeading) {
            // Changed against the trainer's text.
            if block.changed, width > 18 {
                Circle().fill(.white).frame(width: 5, height: 5).padding(4)
            }
        }
        .frame(width: width, height: planHeight)
        .help(block.help)
        .contextMenu { blockMenu(block) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.help)
        .accessibilityAdjustableAction { direction in
            let value = currentValue(block.edge)
            switch direction {
            case .increment: set(block.edge, to: min(3600, value + Self.snap))
            case .decrement: set(block.edge, to: max(0, value - Self.snap))
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func blockMenu(_ block: Block) -> some View {
        if let value = block.original, block.changed {
            Button("Как у тренера — \(DurationText.short(value))") {
                withAnimation(.snappy) { set(block.edge, to: value) }
            }
        }
        switch block.edge.kind {
        case .exit:
            if plan.exits.indices.contains(block.edge.index) {
                Toggle("Или до вставания", isOn: Binding(
                    get: { plan.exits[block.edge.index].untilStanding },
                    set: { plan.exits[block.edge.index].untilStanding = $0 }))
            }
        case .pause:
            if block.own {
                Button("Как у всех — \(DurationText.short(plan.defaultBreak))") {
                    withAnimation(.snappy) { plan.exits[block.edge.index].breakAfter = nil }
                }
            }
        }
    }

    private func exitLabel(_ block: Block, width: CGFloat) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                Text("\(block.number)").font(.system(size: 11, weight: .bold).monospacedDigit())
                if block.untilStanding, width >= 46 {
                    Image(systemName: "figure.stand").font(.system(size: 9, weight: .bold))
                }
            }
            if width >= 34 {
                Text(DurationText.clock(block.duration)).font(.system(size: 10, weight: .medium).monospacedDigit())
            }
        }
        .foregroundStyle(.black.opacity(0.75))
        .fixedSize()
        .opacity(width >= 11 ? 1 : 0)
    }

    private func pauseLabel(_ block: Block, width: CGFloat) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "pause.fill").font(.system(size: 7))
            Text(MacPlanFormat.cell(block.duration))
            if block.own, width >= 96 { Text("· свой").fontWeight(.regular) }
        }
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .foregroundStyle(block.own ? AnyShapeStyle(MacPalette.blue) : AnyShapeStyle(.secondary))
        .fixedSize()
        .opacity(width >= 48 ? 1 : 0)
    }

    private func emptyLane(text: String, tint: Color, width: CGFloat, height: CGFloat, sticky: CGFloat,
                           filled: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return shape
            .fill(tint.opacity(filled ? 0.12 : 0))
            .overlay { shape.strokeBorder(tint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
            .overlay(alignment: .leading) {
                Text(text)
                    .font(.system(size: height < 20 ? 9 : 10, weight: .medium))
                    .foregroundStyle(tint.opacity(0.85))
                    .fixedSize()
                    .padding(.leading, 8)
                    .offset(x: sticky)
            }
            .frame(width: max(2, width), height: height)
            .clipped()
            .allowsHitTesting(false)
    }

    /// 14 pt grab zone on the right edge: a white grip on hover, resize pointer, drag to change the duration.
    private func handle(_ block: Block, pps: CGFloat, active: Bool) -> some View {
        let lit = active || hovered == block.edge
        return Color.clear
            .frame(width: 14, height: planHeight)
            .overlay {
                if lit {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(.white.opacity(active ? 1 : 0.8))
                        .frame(width: 5, height: 28)
                        .overlay {
                            VStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Capsule().fill(.black.opacity(0.35)).frame(width: 3, height: 1)
                                }
                            }
                        }
                        .shadow(color: .black.opacity(0.5), radius: 2.5)
                        .offset(x: -0.5)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if hovered != block.edge { hovered = block.edge }
                    if staged != nil { staged = nil }
                case .ended:
                    if hovered == block.edge { hovered = nil }
                }
            }
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in resize(block, by: value.translation.width, pps: pps) }
                    .onEnded { _ in withAnimation(.snappy) { drag = nil } }
            )
            .accessibilityHidden(true)
    }

    /// Vertical guide through the lanes plus the live tooltip «Выход 6 · 2:30 (+0:30)».
    private func editGuide(_ block: Block, pps: CGFloat, contentWidth: CGFloat) -> some View {
        let x = inset + block.end * pps
        let tipWidth: CGFloat = 220
        let tipX = min(max(x - tipWidth / 2, 4), contentWidth - tipWidth - 4)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.white.opacity(0.85))
                .frame(width: 1, height: recordTop + recordHeight + 4 - 24)
                .offset(x: x - 0.5, y: 24)
            tooltip(block)
                .frame(width: tipWidth)
                .offset(x: tipX, y: 3)
        }
        .allowsHitTesting(false)
    }

    private func tooltip(_ block: Block) -> some View {
        let name = block.edge.kind == .exit ? "Выход \(block.number)" : "Перерыв после \(block.number)"
        let reference = block.original ?? (drag?.edge == block.edge ? drag?.startValue : nil)
        let delta = reference.map { block.duration - $0 } ?? 0
        let value = Text(DurationText.clock(block.duration)).fontWeight(.bold)
        let change = Text(delta == 0 ? "" : " (\(MacPlanFormat.signed(delta)))").foregroundStyle(.black.opacity(0.55))
        let own = Text(block.edge.kind == .pause && block.own ? " · свой" : "").foregroundStyle(.black.opacity(0.55))
        return Text("\(name) · \(value)\(change)\(own)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.black)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
    }

    // MARK: Editing

    private func resize(_ block: Block, by dx: CGFloat, pps: CGFloat) {
        staged = nil
        if drag?.edge != block.edge {
            drag = EdgeDrag(edge: block.edge, startValue: block.duration, span: span, pps: pps)
        }
        guard let drag else { return }
        let raw = drag.startValue + dx / drag.pps
        let snapped = (raw / Self.snap).rounded() * Self.snap
        // Exits from 5 s, breaks from 30 s (unless the trainer wrote less), up to an hour.
        let minimum = min(block.edge.kind == .exit ? 5 : 30, drag.startValue)
        let value = min(max(snapped, minimum), 60 * 60)
        guard value != currentValue(block.edge) else { return }
        set(block.edge, to: value)
        // A detent on whole half-minutes and on the trainer's value.
        if value.truncatingRemainder(dividingBy: 30) == 0 || value == block.original {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func currentValue(_ edge: BlockEdge) -> TimeInterval {
        guard plan.exits.indices.contains(edge.index) else { return 0 }
        switch edge.kind {
        case .exit: return plan.exits[edge.index].duration
        case .pause: return plan.breakAfter(exitAt: edge.index)
        }
    }

    private func set(_ edge: BlockEdge, to value: TimeInterval) {
        guard plan.exits.indices.contains(edge.index) else { return }
        switch edge.kind {
        case .exit:
            plan.exits[edge.index].duration = value
        case .pause:
            // Back at the common break → «как у всех» again (if the trainer had it so), otherwise an own break.
            let id = plan.exits[edge.index].id
            let wasCommon = original?.exits.first { $0.id == id }.map { $0.breakAfter == nil } ?? true
            plan.exits[edge.index].breakAfter = value == plan.defaultBreak && wasCommon ? nil : value
        }
    }

    // MARK: Zoom & scroll

    private func scroll(to x: CGFloat) {
        let clamped = min(max(0, x), max(0, contentWidth(viewport) - viewport))
        offset = clamped
        position.scrollTo(x: clamped)
    }

    private func step(_ direction: Int) {
        let steps = Self.zoomSteps
        let next = direction > 0 ? steps.first { $0 > zoom + 0.01 } : steps.last { $0 < zoom - 0.01 }
        setZoom(next ?? zoom)
    }

    /// Changes the zoom keeping the moment under `anchor` (x in the visible area) where it was.
    private func setZoom(_ value: CGFloat, anchor: CGFloat? = nil, time: TimeInterval? = nil) {
        guard viewport > 0, drag == nil else { return }
        staged = nil
        let newZoom = min(max(value, 1), Self.zoomSteps.last!)
        let a = anchor ?? viewport / 2
        let t = time ?? (offset + a - inset) / pointsPerSecond(viewport)
        zoom = newZoom
        let maxOffset = max(0, contentWidth(viewport, zoom: newZoom) - viewport)
        let x = min(max(0, inset + t * pointsPerSecond(viewport, zoom: newZoom) - a), maxOffset)
        offset = x
        position.scrollTo(x: x)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinch == nil {
                    let anchor = value.startLocation.x
                    pinch = Pinch(zoom: zoom, anchor: anchor, time: (offset + anchor - inset) / pointsPerSecond(viewport))
                }
                guard let pinch else { return }
                setZoom(pinch.zoom * value.magnification, anchor: pinch.anchor, time: pinch.time)
            }
            .onEnded { _ in pinch = nil }
    }

    /// Ruler labels at least ~64 pt apart.
    private static func labelStep(_ pps: CGFloat) -> TimeInterval {
        [10, 15, 30, 60, 120, 300, 600, 900].first { CGFloat($0) * pps >= 64 } ?? 900
    }

    private static func minorStep(_ pps: CGFloat, label: TimeInterval) -> TimeInterval {
        [5, 10, 15, 30, 60, 120, 300].first { Int(label) % Int($0) == 0 && CGFloat($0) * pps >= 12 } ?? label
    }

    #if DEBUG
    /// `--demo-timeline-edit`: exit 6 stretched to 2:30 at 150 %, its edge shown as if dragged (screenshots).
    private func debugStage() async {
        guard CommandLine.arguments.contains("--demo-timeline-edit"), plan.exits.count > 5 else { return }
        try? await Task.sleep(for: .milliseconds(400))
        plan.exits[5].duration = 150
        setZoom(1.5, anchor: 0, time: 5 * 60)
        staged = BlockEdge(index: 5, kind: .exit)
    }
    #endif

    // MARK: Blocks

    private struct Block: Identifiable {
        let edge: BlockEdge
        let start: TimeInterval
        let duration: TimeInterval
        /// Value in the trainer's text.
        let original: TimeInterval?
        let number: Int
        let own: Bool
        let untilStanding: Bool

        var id: BlockEdge { edge }
        var end: TimeInterval { start + duration }
        var changed: Bool { original.map { $0 != duration } ?? false }

        var help: String {
            var text: String
            switch edge.kind {
            case .exit:
                text = "Выход \(number) · \(DurationText.short(duration))"
                if untilStanding { text += " или до вставания" }
            case .pause:
                text = "Перерыв после выхода \(number) · \(DurationText.short(duration))" + (own ? ", свой" : "")
            }
            if changed, let original { text += " · у тренера \(DurationText.short(original))" }
            return text
        }
    }

    private var blocks: [Block] {
        var t: TimeInterval = 0
        var result: [Block] = []
        for (index, exit) in plan.exits.enumerated() {
            let source = original?.exits.firstIndex { $0.id == exit.id }
            result.append(Block(edge: BlockEdge(index: index, kind: .exit), start: t, duration: exit.duration,
                                original: source.map { original!.exits[$0].duration }, number: exit.number,
                                own: false, untilStanding: exit.untilStanding))
            t += exit.duration
            if index < plan.exits.count - 1 {
                let pause = plan.breakAfter(exitAt: index)
                result.append(Block(edge: BlockEdge(index: index, kind: .pause), start: t, duration: pause,
                                    original: source.map { original!.breakAfter(exitAt: $0) }, number: exit.number,
                                    own: exit.breakAfter != nil, untilStanding: false))
                t += pause
            }
        }
        return result
    }
}

/// ⌥ + scroll over the timeline zooms instead of scrolling (Logic, Final Cut). A local event monitor,
/// so the scroll view underneath never sees those events.
private struct OptionScrollZoom: NSViewRepresentable {
    var onZoom: (_ factor: CGFloat, _ x: CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onZoom = onZoom
    }

    final class MonitorView: NSView {
        var onZoom: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard event.modifierFlags.contains(.option) else { return event }
                let windowNumber = event.windowNumber
                let location = event.locationInWindow
                // Trackpads give pixel deltas, mouse wheels give lines.
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, window.windowNumber == windowNumber else { return false }
                    let point = self.convert(location, from: nil)
                    guard self.bounds.contains(point) else { return false }
                    if delta != 0 { self.onZoom?(exp(delta * 0.01), point.x) }
                    return true
                }
                return handled ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
#endif
