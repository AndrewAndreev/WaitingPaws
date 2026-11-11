#if os(macOS)
import AVKit
import SwiftUI
import WaitingPawsCore

/// The inspector's player: one `AVPlayer` for whatever row is selected, with its time published for the exit strip.
@MainActor
@Observable
final class MacHistoryPlayer {
    let player = AVPlayer()
    private(set) var url: URL?
    /// Seconds into the loaded video.
    private(set) var time: TimeInterval = 0
    private(set) var isPlaying = false
    /// «Воспроизвести» asked for a file that is still loading (or being finalised).
    private var playWhenLoaded: URL?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.time = time.seconds
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
    }

    /// Shows `url` (or nothing); keeps playing only if this is the file «Воспроизвести» asked for.
    func load(_ url: URL?) {
        guard url != self.url else {
            if let url, playWhenLoaded == url { start() }
            return
        }
        player.pause()
        self.url = url
        time = 0
        player.replaceCurrentItem(with: url.map { AVPlayerItem(url: $0) })
        if let url, playWhenLoaded == url { start() }
    }

    /// Plays `url` once the inspector has loaded it (right away if it is already there).
    func play(_ url: URL) {
        playWhenLoaded = url
        if self.url == url { start() }
    }

    func toggle() {
        if isPlaying { player.pause() } else { player.play() }
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, seconds)
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func start() {
        playWhenLoaded = nil
        player.play()
    }
}

/// `AVPlayerView` with the standard floating controls (play, scrubber, volume, full screen).
struct MacHistoryPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - Exit strip

/// The training laid along its recording: walks to the door, time behind it (numbered), false starts, breaks, and
/// what the owner marked from behind the door as dots on it (the console's «Факт» lane: a condition in its trainer's
/// colour, the barking and the quiet after it red). The white bar follows the video; a click or drag seeks, a click on
/// a dot goes to that moment.
struct MacHistoryExitStrip: View {
    let record: TrainingRecord
    /// Clock time of offset 0 (the start of the recording, or of the training without a video).
    let base: Date
    /// Length of the strip in seconds (the video's, or the training's).
    let total: TimeInterval
    /// Drives the playhead and seeking; `nil` without a video.
    var player: MacHistoryPlayer?

    private struct Segment: Identifiable {
        enum Kind { case walk, away, falseStart, rest }
        let id: String
        let start: TimeInterval
        let end: TimeInterval
        let kind: Kind
        let exit: Int
    }

    /// «Выход 3 · легла на 0:43» at `offset` (from `base`).
    private struct Mark: Identifiable {
        let id: UUID
        let offset: TimeInterval
        let color: Color
        let text: String
    }

    private let trackHeight: CGFloat = 6

    /// The marks of each attempt, worded as the log words them (`SessionLogFormatter.observations`, in that order).
    private var marks: [Mark] {
        record.results.flatMap { result -> [Mark] in
            let events = record.events.filter {
                $0.kind == .note && $0.observed == true && $0.exitNumber == result.number && $0.attempt == result.attempt
                    && !($0.detail ?? "").isEmpty
            }
            let words = SessionLogFormatter.observations(of: result, in: record)
            let exit = result.attempt > 1 ? String(localized: "Exit \(result.number), attempt \(result.attempt)")
                                          : String(localized: "Exit \(result.number)")
            return events.enumerated().map { index, event in
                let said = words.indices.contains(index) ? words[index] : event.detail ?? ""
                return Mark(id: event.id, offset: event.time.timeIntervalSince(base),
                            color: SessionTimelineView.color(of: event.detail ?? "", exit: result.number, in: record.plan),
                            text: "\(exit) · \(said)")
            }
        }
        .filter { $0.offset >= 0 && $0.offset <= total }
    }

    private var segments: [Segment] {
        var segments: [Segment] = []
        for result in record.results {
            let start = result.startedAt.timeIntervalSince(base)
            let left = (result.leftAt ?? result.endedAt).timeIntervalSince(base)
            let end = result.endedAt.timeIntervalSince(base)
            let id = result.id.uuidString
            segments.append(Segment(id: id + "w", start: start, end: left, kind: .walk, exit: result.number))
            if result.leftAt != nil || result.falseStart {
                segments.append(Segment(id: id + "a", start: left, end: end, kind: result.falseStart ? .falseStart : .away,
                                        exit: result.number))
            }
            if let rest = result.actualBreak {
                segments.append(Segment(id: id + "r", start: end, end: end + rest, kind: .rest, exit: result.number))
            }
        }
        return segments.filter { $0.end > 0 && $0.start < total }
    }

    var body: some View {
        let segments = segments
        VStack(spacing: 3) {
            GeometryReader { geo in
                ForEach(segments.filter { $0.kind == .away || $0.kind == .falseStart }) { segment in
                    marker(segment)
                        .position(x: min(max(6, x((segment.start + segment.end) / 2, geo.size.width)), geo.size.width - 6), y: 7)
                }
            }
            .frame(height: 14)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    ForEach(segments) { segment in
                        let start = x(segment.start, geo.size.width)
                        Rectangle()
                            .fill(color(segment.kind))
                            .frame(width: max(segment.kind == .rest ? 1 : 2.5, x(segment.end, geo.size.width) - start),
                                   height: trackHeight)
                            .offset(x: start)
                    }
                }
                .frame(height: trackHeight)
                .clipShape(Capsule())
                .frame(maxHeight: .infinity)
                .overlay { markDots(width: geo.size.width) }
                .overlay(alignment: .leading) {
                    if let player, player.url != nil {
                        Playhead(player: player, total: total, width: geo.size.width, trackHeight: trackHeight)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard let player, player.url != nil else { return }
                    player.seek(to: total * min(1, max(0, value.location.x / geo.size.width)))
                })
            }
            .frame(height: trackHeight + 10)

            GeometryReader { geo in
                ForEach(ticks(width: geo.size.width), id: \.self) { offset in
                    Text(MacFormat.time.string(from: base.addingTimeInterval(offset)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(14, x(offset, geo.size.width)), geo.size.width - 14), y: 6)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exits over time")
    }

    @ViewBuilder
    private func marker(_ segment: Segment) -> some View {
        if segment.kind == .falseStart {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 7.5, weight: .heavy))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 13, height: 13)
                .background(Circle().fill(MacPalette.orange))
                .help("Exit \(segment.exit): false start")
        } else {
            Text("\(segment.exit)")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Exit \(segment.exit)")
        }
    }

    /// The marks on the track, a dark ring keeping them apart from the pink under them; their words under the pointer.
    private func markDots(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(marks) { mark in
                Circle()
                    .fill(mark.color)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .frame(width: 14, height: trackHeight + 10)
                    .contentShape(Rectangle())
                    .help(mark.text)
                    .onTapGesture {
                        guard let player, player.url != nil else { return }
                        player.seek(to: mark.offset)
                    }
                    .position(x: min(max(4.5, x(mark.offset, width)), width - 4.5), y: (trackHeight + 10) / 2)
            }
        }
        .frame(width: width, height: trackHeight + 10, alignment: .topLeading)
    }

    private func x(_ offset: TimeInterval, _ width: CGFloat) -> CGFloat {
        width * CGFloat(min(1, max(0, offset / max(1, total))))
    }

    private func color(_ kind: Segment.Kind) -> Color {
        switch kind {
        case .walk: MacPalette.accent.opacity(0.4)
        case .away: MacPalette.accent
        case .falseStart: MacPalette.orange
        case .rest: MacPalette.blue.opacity(0.35)
        }
    }

    /// Clock labels on round minutes, at least 56 pt apart.
    private func ticks(width: CGFloat) -> [TimeInterval] {
        let steps: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { width * CGFloat($0 / max(1, total)) >= 56 } ?? 7200
        let first = (base.timeIntervalSince1970 / step).rounded(.up) * step - base.timeIntervalSince1970
        return stride(from: first, through: total, by: step).filter { $0 > step * 0.3 && total - $0 > step * 0.3 }
    }

    /// Separate view so the 5-per-second time updates redraw only the bar.
    private struct Playhead: View {
        let player: MacHistoryPlayer
        let total: TimeInterval
        let width: CGFloat
        let trackHeight: CGFloat

        var body: some View {
            Capsule()
                .fill(.primary)
                .frame(width: 3, height: trackHeight + 10)
                .shadow(color: .black.opacity(0.35), radius: 1.5)
                .offset(x: width * CGFloat(min(1, max(0, player.time / max(1, total)))) - 1.5)
                .allowsHitTesting(false)
        }
    }
}
#endif
