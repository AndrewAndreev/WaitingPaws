#if os(macOS)
import Charts
import SwiftUI
import WaitingPawsCore

/// Range of the progress chart and of the numbers next to it.
enum MacHistoryPeriod: String, CaseIterable, Identifiable {
    case fourWeeks, threeMonths, all

    var id: Self { self }

    var title: String {
        switch self {
        case .fourWeeks: String(localized: "4 недели")
        case .threeMonths: String(localized: "3 месяца")
        case .all: String(localized: "Всё время")
        }
    }

    /// Title of the gain figure when the period starts after the first training.
    var gainTitle: String {
        switch self {
        case .fourWeeks: String(localized: "За четыре недели")
        case .threeMonths: String(localized: "За три месяца")
        case .all: String(localized: "С первой тренировки")
        }
    }

    var days: Int? {
        switch self {
        case .fourWeeks: 28
        case .threeMonths: 91
        case .all: nil
        }
    }
}

/// Numbers behind the panel: trainings of the period (oldest first) and the all-time record.
struct MacHistoryProgress {
    let sessions: [TrainingRecord]
    let record: TrainingRecord?
    let domain: ClosedRange<Date>
    let includesFirstTraining: Bool

    init(records: [TrainingRecord], period: MacHistoryPeriod) {
        let all = records.sorted { $0.startedAt < $1.startedAt }
        record = all.filter { $0.longestStayBehindDoor > 0 }.max { $0.longestStayBehindDoor < $1.longestStayBehindDoor }
        let calendar = Calendar.current
        let newest = all.last?.startedAt ?? Date()
        let end = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: newest)).map { max($0, newest) } ?? newest
        let start: Date
        if let days = period.days {
            start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: newest)) ?? newest
        } else {
            start = calendar.date(byAdding: .hour, value: -12, to: calendar.startOfDay(for: all.first?.startedAt ?? newest)) ?? newest
        }
        sessions = all.filter { $0.startedAt >= start }
        includesFirstTraining = sessions.first?.id == all.first?.id
        domain = start...end.addingTimeInterval(12 * 3600)
    }

    var first: TrainingRecord? { sessions.first }
    var best: TrainingRecord? { sessions.max { $0.longestStayBehindDoor < $1.longestStayBehindDoor } }
    var cleanCount: Int { sessions.filter { $0.falseStarts == 0 }.count }
    var falseStartTotal: Int { sessions.reduce(0) { $0 + $1.falseStarts } }

    /// How much longer the dog stays behind the door now than at the start of the period.
    var gain: TimeInterval? {
        guard sessions.count > 1, let first, let best else { return nil }
        return best.longestStayBehindDoor.rounded(.down) - first.longestStayBehindDoor.rounded(.down)
    }

    /// Top of the y axis and the step of its labels: round clock values, at most six of them.
    var yAxis: (max: TimeInterval, step: TimeInterval) {
        let top = sessions.map { max($0.longestStayBehindDoor, $0.longestPlannedExit) }.max() ?? 0
        let steps: [TimeInterval] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { top * 1.08 / $0 <= 6 } ?? 7200
        return (max(step * 2, (top * 1.08 / step).rounded(.up) * step), step)
    }
}

/// Top of the window: key numbers on the left, «Дольше всего за дверью» per training on the right.
struct MacHistoryProgressPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(MacHistoryController.self) private var controller
    let records: [TrainingRecord]
    let selected: TrainingRecord?

    @State private var hovered: TrainingRecord?

    var body: some View {
        let progress = MacHistoryProgress(records: records, period: controller.period)
        HStack(alignment: .top, spacing: 28) {
            figures(progress)
                .frame(width: 176, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                // The legend steps aside in a narrow window.
                ViewThatFits(in: .horizontal) {
                    header(showsLegend: true)
                    header(showsLegend: false)
                }
                chart(progress)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(height: 280)
    }

    private func header(showsLegend: Bool) -> some View {
        @Bindable var controller = controller
        return HStack(alignment: .center, spacing: 16) {
            Text("Дольше всего за дверью").font(.headline).fixedSize()
            Spacer(minLength: 8)
            if showsLegend { legend.fixedSize() }
            Picker("Период", selection: $controller.period) {
                ForEach(MacHistoryPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Период графика и цифр слева")
        }
    }

    // MARK: Figures

    private func figures(_ progress: MacHistoryProgress) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let record = progress.record {
                figure(String(localized: "Рекорд за дверью"), DurationText.clock(record.longestStayBehindDoor),
                       note: String(localized: "\(MacHistoryFormat.dayMonth(record.startedAt)) · план \(DurationText.clock(record.longestPlannedExit))"))
            } else {
                figure(String(localized: "Рекорд за дверью"), "—", note: String(localized: "пока ни одного выхода"))
            }

            let gainTitle = progress.includesFirstTraining ? String(localized: "С первой тренировки") : controller.period.gainTitle
            if let gain = progress.gain, let first = progress.first {
                figure(gainTitle, (gain < 0 ? "−" : "+") + DurationText.clock(abs(gain)),
                       note: String(localized: "было \(DurationText.clock(first.longestStayBehindDoor)) \(MacHistoryFormat.dayMonth(first.startedAt))"),
                       tint: gain > 0 ? MacHistoryInk.green : gain < 0 ? MacHistoryInk.orange : .primary)
            } else {
                figure(gainTitle, "—", note: String(localized: "нужно хотя бы две тренировки"))
            }

            figure(String(localized: "Без фальстартов"),
                   String(localized: "\(progress.cleanCount) из \(progress.sessions.count)"), digits: false,
                   note: progress.falseStartTotal == 0
                       ? String(localized: "ни одного фальстарта")
                       : String(localized: "фальстартов всего: \(progress.falseStartTotal)"))
        }
    }

    private func figure(_ title: String, _ value: String, digits: Bool = true, note: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value)
                .font(digits ? MacPalette.digits(26) : .system(size: 24, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(MacPalette.accent).frame(width: 14, height: 3)
                Text("дольше всего")
            }
            HStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(.secondary).frame(width: 3.5, height: 1.5) }
                }
                Text("план")
            }
            HStack(spacing: 5) {
                Circle().fill(MacPalette.orange).frame(width: 7, height: 7)
                Text("был фальстарт")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Chart

    private func chart(_ progress: MacHistoryProgress) -> some View {
        let axis = progress.yAxis
        let accent = MacPalette.accent
        return Chart {
            ForEach(progress.sessions) { record in
                AreaMark(x: .value("Дата", record.startedAt), y: .value("За дверью", record.longestStayBehindDoor))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.24), accent.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Дата", record.startedAt), y: .value("За дверью", record.longestStayBehindDoor),
                         series: .value("Ряд", String(localized: "Факт")))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                LineMark(x: .value("Дата", record.startedAt), y: .value("План", record.longestPlannedExit),
                         series: .value("Ряд", String(localized: "План")))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
            if let selected, progress.sessions.contains(where: { $0.id == selected.id }) {
                RuleMark(x: .value("Дата", selected.startedAt))
                    .foregroundStyle(accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(progress.sessions) { record in
                let isSelected = record.id == selected?.id
                let showsLabel = isSelected || (record.id == hovered?.id)
                PointMark(x: .value("Дата", record.startedAt), y: .value("За дверью", record.longestStayBehindDoor))
                    .symbolSize(isSelected ? 70 : record.id == hovered?.id ? 50 : 26)
                    .foregroundStyle(record.falseStarts > 0 ? MacPalette.orange : accent)
                    .annotation(position: .top, alignment: .center, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        if showsLabel { label(for: record) }
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
            AxisMarks(values: xAxisValues(progress.domain)) { value in
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

    private func label(for record: TrainingRecord) -> some View {
        Text("\(MacHistoryFormat.dayMonth(record.startedAt)) · \(DurationText.clock(record.longestStayBehindDoor))")
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

    /// Date labels (left-aligned to their day): every few days for a month, every two weeks for a quarter,
    /// monthly beyond; none so close to the right edge that it would be cut off.
    private func xAxisValues(_ domain: ClosedRange<Date>) -> [Date] {
        let calendar = Calendar.current
        let days = domain.upperBound.timeIntervalSince(domain.lowerBound) / 86_400
        let first = calendar.startOfDay(for: domain.lowerBound.addingTimeInterval(86_400 - 1))
        let step: DateComponents = days <= 40 ? DateComponents(day: max(1, Int((days / 7).rounded())))
            : days <= 120 ? DateComponents(day: 14)
            : DateComponents(month: max(1, Int((days / 30 / 7).rounded(.up))))
        let lastAllowed = domain.upperBound.addingTimeInterval(-days * 86_400 * 0.06)
        var values: [Date] = []
        var date = first
        while date <= lastAllowed {
            values.append(date)
            guard let next = calendar.date(byAdding: step, to: date) else { break }
            date = next
        }
        return values
    }
}
#endif
