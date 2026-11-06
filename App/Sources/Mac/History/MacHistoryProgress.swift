#if os(macOS)
import Charts
import SwiftUI
import WaitingPawsCore

/// The period menu of the window; the type is shared with the iPhone history (`HistoryView.swift`).
typealias MacHistoryPeriod = HistoryPeriod

/// Top of the window: two numbers on the left — the longest exit and how much it grew — and «Дольше всего за
/// дверью» per training on the right: one line, the selected training's point larger, a point's words on hover. The
/// plans and the false starts are in the table under it.
struct MacHistoryProgressPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(MacHistoryController.self) private var controller
    let records: [TrainingRecord]
    let selected: TrainingRecord?

    @State private var hovered: TrainingRecord?

    var body: some View {
        let progress = HistoryProgress(records: records, period: controller.period(for: records))
        HStack(alignment: .top, spacing: 28) {
            figures(progress)
                .frame(width: 176, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                header
                chart(progress)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(height: 280)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Дольше всего за дверью").font(.headline).fixedSize()
            Spacer(minLength: 8)
            // The iPhone card's three periods; the pick is kept.
            Picker("Период", selection: Binding(get: { controller.period(for: records) }, set: { controller.pick($0) })) {
                ForEach(MacHistoryPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Период графика и цифр слева")
        }
    }

    // MARK: Figures

    /// The longest exit and one number of growth, titled by what it counts from («С первой тренировки», «С 6 сент.»),
    /// as on the iPhone; no notes under them, the chart has the rest.
    private func figures(_ progress: HistoryProgress) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // «Самый длинный выход», not «рекорд»: a longer exit is a fact about the dog, not a score.
            figure(String(localized: "Самый длинный выход"),
                   progress.longestEver.map { DurationText.clock($0.longestStayBehindDoor) } ?? "—")
            // The change keeps the plain text colour: longer is not automatically better (a calmer dog is).
            if let gain = progress.gainText {
                figure(progress.gainSince, gain)
            }
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value)
                .font(MacPalette.digits(26))
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private func chart(_ progress: HistoryProgress) -> some View {
        let axis = progress.yAxis(labels: 6)
        let accent = MacPalette.accent
        return Chart {
            ForEach(progress.sessions) { record in
                // Straight lines between the trainings: a curve drew values between them that no training had.
                AreaMark(x: .value("Дата", record.startedAt), yStart: .value("За дверью", 0),
                         yEnd: .value("За дверью", record.longestStayBehindDoor))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.24), accent.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Дата", record.startedAt), y: .value("За дверью", record.longestStayBehindDoor),
                         series: .value("Ряд", String(localized: "Факт")))
                    .interpolationMethod(.linear)
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
            if let selected, progress.sessions.contains(where: { $0.id == selected.id }) {
                RuleMark(x: .value("Дата", selected.startedAt))
                    .foregroundStyle(accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(progress.sessions) { record in
                let isSelected = record.id == selected?.id
                let isHovered = record.id == hovered?.id
                PointMark(x: .value("Дата", record.startedAt), y: .value("За дверью", record.longestStayBehindDoor))
                    .symbolSize(isSelected ? 70 : isHovered ? 50 : 26)
                    .foregroundStyle(accent)
                    .annotation(position: .top, alignment: .center, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        if isHovered { label(for: record) }
                    }
            }
        }
        .chartYScale(domain: 0...axis.max)
        .chartXScale(domain: progress.domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: 0, through: axis.max, by: axis.step))) { value in
                AxisGridLine()
                AxisValueLabel {
                    Text(DurationText.clock(value.as(Double.self) ?? 0)).monospacedDigit()
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: progress.xAxisValues(labels: 7)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(MacHistoryFormat.dayMonth(date)) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = nearest(to: location, proxy: proxy, geo: geo, in: progress.sessions)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let record = nearest(to: location, proxy: proxy, geo: geo, in: progress.sessions) else { return }
                        controller.reveal(.session(record.id), model: model)
                    }
            }
        }
        .accessibilityLabel("График: дольше всего за дверью по тренировкам")
    }

    /// "2 окт. · 2:32" over the point under the pointer.
    private func label(for record: TrainingRecord) -> some View {
        Text(verbatim: "\(MacHistoryFormat.dayMonth(record.startedAt)) · \(DurationText.clock(record.longestStayBehindDoor))")
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(.background).shadow(color: .black.opacity(0.15), radius: 2, y: 1))
            .overlay(Capsule().strokeBorder(MacPalette.accent.opacity(0.4)))
    }

    /// The training whose point is closest to the pointer horizontally (within 24 pt).
    private func nearest(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy,
                         in sessions: [TrainingRecord]) -> TrainingRecord? {
        guard let plot = proxy.plotFrame else { return nil }
        let origin = geo[plot].origin
        let x = location.x - origin.x
        let candidates = sessions.compactMap { record -> (TrainingRecord, CGFloat)? in
            guard let position = proxy.position(forX: record.startedAt) else { return nil }
            return (record, abs(position - x))
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 <= 24 else { return nil }
        return best.0
    }
}
#endif
