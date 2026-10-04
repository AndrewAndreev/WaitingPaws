#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Plan vs actual on one time axis.
struct SessionTimelineView: View {
    let model: LiveSessionModel

    private let labelWidth: CGFloat = 86
    private let laneHeight: CGFloat = 34

    private struct Segment: Identifiable {
        let id = UUID()
        let start: Date
        let end: Date
        let color: Color
        var label: String? = nil
        var dashed = false
        var strong = false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                let width = geo.size.width - labelWidth - 16
                let axis = axisRange
                ZStack(alignment: .topLeading) {
                    ruler(width: width, axis: axis)
                    VStack(alignment: .leading, spacing: 10) {
                        lane(String(localized: "План"), segments: planSegments, width: width, axis: axis)
                        lane(String(localized: "Факт"), segments: factSegments, width: width, axis: axis)
                        lane(String(localized: "Запись"), segments: recordSegments, width: width, axis: axis, height: 14)
                    }
                    .padding(.top, 30)
                    playhead(width: width, axis: axis, height: geo.size.height)
                }
            }
            .padding(.horizontal, 8)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Таймлайн").font(.headline)
            legend(MacPalette.pink, String(localized: "выход по плану"))
            legend(MacPalette.green, String(localized: "за дверью"))
            legend(MacPalette.orange, String(localized: "фальстарт / сверх плана"))
            legend(MacPalette.blue.opacity(0.55), String(localized: "перерыв"))
            legend(.gray, String(localized: "к двери"))
            Spacer()
            Text(driftText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    /// How far the session is behind the ideal schedule (door walks and long breaks add up).
    private var driftText: String {
        guard let index = model.session.currentExitIndex else { return "" }
        var planned: TimeInterval = 0
        for i in 0..<index { planned += model.plan.exits[i].duration + model.plan.breakAfter(exitAt: i) }
        let actual = (currentStart ?? model.now).timeIntervalSince(model.session.startedAt)
        let drift = actual - planned
        return drift >= 0 ? String(localized: "отстаём от плана на \(DurationText.clock(drift))")
                          : String(localized: "опережаем план на \(DurationText.clock(-drift))")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Data

    private var axisRange: ClosedRange<Date> {
        let start = model.session.startedAt
        let planEnd = start.addingTimeInterval(model.plan.estimatedDuration)
        let end = max(planEnd, model.eta).addingTimeInterval(120)
        return start...end
    }

    private var planSegments: [Segment] {
        var t = model.session.startedAt
        var segments: [Segment] = []
        for (index, exit) in model.plan.exits.enumerated() {
            let end = t.addingTimeInterval(max(exit.duration, 4))
            segments.append(Segment(start: t, end: end, color: MacPalette.pink.opacity(0.85), label: "\(exit.number)"))
            t = t.addingTimeInterval(exit.duration)
            if index < model.plan.exits.count - 1 {
                let b = model.plan.breakAfter(exitAt: index)
                segments.append(Segment(start: t, end: t.addingTimeInterval(b), color: MacPalette.blue.opacity(exit.breakAfter != nil ? 0.38 : 0.2),
                                        label: exit.breakAfter != nil ? DurationText.short(b) : nil))
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
                segments.append(Segment(start: r.startedAt, end: left, color: .gray.opacity(0.7)))
                segments.append(Segment(start: left, end: max(r.endedAt, left.addingTimeInterval(4)),
                                        color: r.falseStart ? MacPalette.orange : MacPalette.green,
                                        label: r.falseStart ? "↺" : "\(r.number)", strong: true))
            }
            let next = i + 1 < results.count ? results[i + 1].startedAt : (currentStart ?? model.now)
            segments.append(Segment(start: r.endedAt, end: next, color: MacPalette.blue.opacity(0.2)))
        }
        switch model.phase {
        case .leaving(_, let since):
            segments.append(Segment(start: since, end: model.now, color: .gray.opacity(0.7)))
        case .away(let index, let since, let leftAt):
            segments.append(Segment(start: since, end: leftAt, color: .gray.opacity(0.7)))
            let planned = leftAt.addingTimeInterval(model.plan.exits[index].duration)
            segments.append(Segment(start: leftAt, end: min(planned, model.now), color: MacPalette.pink, label: "\(model.plan.exits[index].number)", strong: true))
            if model.now > planned {
                segments.append(Segment(start: planned, end: model.now, color: MacPalette.orange, strong: true))
            }
        default: break
        }
        // What is left, projected from now.
        if let index = model.session.currentExitIndex {
            var t = model.now
            for i in index..<model.plan.exits.count {
                if i > index {
                    let e = t.addingTimeInterval(max(model.plan.exits[i].duration, 4))
                    segments.append(Segment(start: t, end: e, color: MacPalette.pink.opacity(0.5), label: "\(model.plan.exits[i].number)", dashed: true))
                    t = t.addingTimeInterval(model.plan.exits[i].duration)
                }
                if i < model.plan.exits.count - 1 {
                    let b = model.plan.breakAfter(exitAt: i)
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

    private func ruler(width: CGFloat, axis: ClosedRange<Date>) -> some View {
        Canvas { context, size in
            let cal = Calendar.current
            var tick = cal.date(bySetting: .second, value: 0, of: axis.lowerBound) ?? axis.lowerBound
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
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth - 10, height: h, alignment: .leading)
            ForEach(segments) { s in
                let x0 = x(s.start, width: width, axis: axis)
                let x1 = x(s.end, width: width, axis: axis)
                let w = max(2, x1 - x0)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(s.dashed ? AnyShapeStyle(s.color.opacity(0.25)) : AnyShapeStyle(s.color))
                    .overlay {
                        if s.dashed {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(s.color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                    }
                    .overlay {
                        if let label = s.label, w > 12 || s.strong || h < 20 {
                            Text(label)
                                .font(.system(size: h < 20 ? 9 : 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(s.strong ? Color.black.opacity(0.75) : .primary.opacity(0.85))
                                .fixedSize()
                        }
                    }
                    .frame(width: w, height: h)
                    .offset(x: x0)
            }
        }
        .frame(height: h)
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
    }
}
#endif
