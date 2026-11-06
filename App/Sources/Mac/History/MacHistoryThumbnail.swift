#if os(macOS)
import AppKit
import AVFoundation
import SwiftUI

/// Small 16:9 still at the start of a table row (Finder-style): a frame of the video. A training without a video
/// gets no tile, only its room, so the column stays aligned and a tile always means a video.
struct MacHistoryThumbnail: View {
    let video: MacHistoryVideo?
    /// The file is being remuxed right now: its frame is made once that is done.
    let preparing: Bool
    let isClip: Bool

    static let size = CGSize(width: 46, height: 26)

    @Environment(\.backgroundProminence) private var prominence
    /// Result of this view's own request (the shared cache is not observable): image, or `nil` after a failure.
    @State private var loaded: (key: String, image: NSImage?)?

    private var key: String? { video.map(MacHistoryThumbnails.key) }

    private var selected: Bool { prominence == .increased }

    var body: some View {
        if video == nil && !isClip {
            Color.clear
                .frame(width: Self.size.width, height: Self.size.height)
                .accessibilityHidden(true)
        } else {
            tile
        }
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return ZStack {
            shape.fill(selected ? AnyShapeStyle(.white.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.75)))
            content
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? Color.white.opacity(0.3) : Color.primary.opacity(0.13), lineWidth: 0.5))
        .help(isClip ? "Запись без тренировки" : "Тренировка")
        .accessibilityHidden(true)
        .task(id: preparing ? nil : key) {
            guard !preparing, let video, let key, MacHistoryThumbnails.shared.cached(video) == nil else { return }
            let image = await MacHistoryThumbnails.shared.image(for: video)
            withAnimation(.easeOut(duration: 0.18)) { loaded = (key, image) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let video {
            if let image = MacHistoryThumbnails.shared.cached(video) ?? loaded.flatMap({ $0.key == key ? $0.image : nil }) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .transition(.opacity)
            } else if loaded?.key == key || MacHistoryThumbnails.shared.hasFailed(video) {
                glyph("film")
            }
        } else {
            glyph("film")
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// Frames of the history videos, made off the main thread once per file version and kept in memory, so
/// scrolling and sorting the table never regenerates them.
@MainActor
final class MacHistoryThumbnails {
    static let shared = MacHistoryThumbnails()

    private let cache = NSCache<NSString, NSImage>()
    /// Versions of files that could not be read (tried again once the file changes).
    private var failed: Set<String> = []
    private var running: [String: Task<NSImage?, Never>] = [:]
    /// At most a few files are opened at once (an older, not yet remuxed recording is read through to index it).
    private var slots = 3
    private var queue: [CheckedContinuation<Void, Never>] = []

    private init() { cache.countLimit = 500 }

    /// File + modification date: a rewritten file (remuxed after recording) gets a fresh frame.
    nonisolated static func key(_ video: MacHistoryVideo) -> String {
        "\(video.url.path)|\(video.modified?.timeIntervalSinceReferenceDate ?? 0)"
    }

    func cached(_ video: MacHistoryVideo) -> NSImage? {
        cache.object(forKey: Self.key(video) as NSString)
    }

    func hasFailed(_ video: MacHistoryVideo) -> Bool { failed.contains(Self.key(video)) }

    /// The frame of `video` (`nil` if it cannot be made); concurrent requests for one file share the work.
    func image(for video: MacHistoryVideo) async -> NSImage? {
        let key = Self.key(video)
        if let image = cache.object(forKey: key as NSString) { return image }
        if failed.contains(key) { return nil }
        if let task = running[key] { return await task.value }
        let url = video.url
        let task = Task<NSImage?, Never> {
            await acquire()
            let image = await Self.frame(of: url)
            release()
            if let image { cache.setObject(image, forKey: key as NSString) } else { failed.insert(key) }
            running[key] = nil
            return image
        }
        running[key] = task
        return await task.value
    }

    private func acquire() async {
        if slots > 0 {
            slots -= 1
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty { slots += 1 } else { queue.removeFirst().resume() }
    }

    /// A frame about a second in (past a camera's first, sometimes grey picture), at twice the cell's size.
    private nonisolated static func frame(of url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 92, height: 52)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let length = (try? await asset.load(.duration)).map(\.seconds) ?? 0
        let time = length > 2 ? CMTime(seconds: 1, preferredTimescale: 600) : .zero
        guard let image = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
#endif
