#if os(macOS)
import AppKit
import AVFoundation
import SwiftUI
import WaitingPawsCore

/// What go2rtc already knows: signed-in Mi Home accounts with their cameras and the registered streams.
/// Shared by the welcome window and the camera picker; choosing a camera registers its stream and saves it.
@MainActor
@Observable
final class SetupCameraCatalog {
    enum Phase: Equatable {
        case idle
        /// go2rtc is not running (or this is the UI preview instance).
        case waiting
        case loading
        case ready
        case failed(String)
    }

    struct Camera: Identifiable, Hashable {
        let source: Go2RTCSource
        let accountID: String
        let region: XiaomiRegion
        /// go2rtc stream that already plays this camera.
        var streamName: String?

        var id: String { "camera|\(accountID)|\(source.url)" }
        var name: String { source.name }
        /// Mi Home model id from the source URL ("chuangmi.camera.069a01").
        var model: String? { SetupCameraCatalog.query("model", in: source.url) }
        var deviceID: String? { SetupCameraCatalog.query("did", in: source.url) }
    }

    struct Account: Identifiable, Hashable {
        let id: String
        let region: XiaomiRegion
        var cameras: [Camera]
        /// The camera list could not be fetched (token expired, wrong region…).
        var error: String?
    }

    enum Choice: Hashable {
        case camera(Camera)
        case stream(Go2RTCStream)

        var id: String {
            switch self {
            case .camera(let camera): return camera.id
            case .stream(let stream): return SetupCameraCatalog.streamID(stream.name)
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var accounts: [Account] = []
    private(set) var streams: [Go2RTCStream] = []
    /// Version of the server, once it answered.
    private(set) var serverVersion: String?
    /// A refresh is running while the old content stays on screen.
    private(set) var refreshing = false

    nonisolated static func streamID(_ name: String) -> String { "stream|\(name)" }

    /// Streams that are not one of the listed Mi Home cameras.
    var otherStreams: [Go2RTCStream] {
        let deviceIDs = Set(accounts.flatMap(\.cameras).compactMap(\.deviceID))
        return streams.filter { stream in
            !stream.sources.contains { source in
                Self.query("did", in: source).map { deviceIDs.contains($0) } ?? false
            }
        }
    }

    var isEmpty: Bool { accounts.isEmpty && otherStreams.isEmpty }

    func choice(for id: String?) -> Choice? {
        guard let id else { return nil }
        if let camera = accounts.lazy.flatMap(\.cameras).first(where: { $0.id == id }) { return .camera(camera) }
        if let stream = streams.first(where: { Self.streamID($0.name) == id }) { return .stream(stream) }
        return nil
    }

    /// Selection id of the camera the app uses now.
    func currentID(_ model: AppModel) -> String? {
        let name = model.settings.streamName
        guard !name.isEmpty else { return nil }
        if let camera = accounts.lazy.flatMap(\.cameras).first(where: { $0.streamName == name }) { return camera.id }
        return streams.contains { $0.name == name } ? Self.streamID(name) : nil
    }

    // MARK: Loading

    /// Reads accounts, cameras and streams. `account` limits the Mi Home part to one account (right after a sign-in).
    func load(_ model: AppModel, account: String? = nil) async {
        #if DEBUG
        if SetupDemo.isOn {
            accounts = SetupDemo.accounts
            streams = SetupDemo.streams
            serverVersion = SetupDemo.go2rtcVersion
            phase = .ready
            return
        }
        #endif
        guard model.setupServerReady, let client = model.client else {
            phase = .waiting
            return
        }
        if phase == .ready { refreshing = true } else { phase = .loading }
        defer { refreshing = false }

        do {
            serverVersion = try await client.version()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let region = model.settings.xiaomiRegion
        async let loadedStreams = Self.loadStreams(client)
        // A server without the xiaomi module answers 404 here: simply no accounts.
        let ids = (try? await client.xiaomiAccounts()) ?? []
        let wanted = account.map { [$0] } ?? ids
        var loaded: [Account] = []
        await withTaskGroup(of: (Int, Account).self) { group in
            for (index, id) in wanted.enumerated() {
                group.addTask {
                    do {
                        let sources = try await client.xiaomiCameras(accountID: id, region: region)
                        let cameras = sources.map { Camera(source: $0, accountID: id, region: region, streamName: nil) }
                        return (index, Account(id: id, region: region, cameras: cameras, error: nil))
                    } catch Go2RTCError.noSources {
                        return (index, Account(id: id, region: region, cameras: [], error: nil))
                    } catch {
                        return (index, Account(id: id, region: region, cameras: [], error: error.localizedDescription))
                    }
                }
            }
            var results: [(Int, Account)] = []
            for await result in group { results.append(result) }
            loaded = results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let allStreams = await loadedStreams
        streams = allStreams
        accounts = loaded.map { account in
            var account = account
            account.cameras = account.cameras.map { camera in
                var camera = camera
                camera.streamName = Self.stream(for: camera, in: allStreams)?.name
                return camera
            }
            return account
        }
        phase = .ready
    }

    /// `/api/streams` describes a live stream by its connection, without the source URL:
    /// those sources come from the config file instead (needed to match Mi Home cameras to streams).
    nonisolated private static func loadStreams(_ client: Go2RTCClient) async -> [Go2RTCStream] {
        guard let streams = try? await client.streams() else { return [] }
        return await withTaskGroup(of: Go2RTCStream.self) { group in
            for stream in streams {
                group.addTask {
                    guard stream.sources.isEmpty,
                          let configured = try? await client.configuredSources(stream: stream.name),
                          !configured.isEmpty else { return stream }
                    return Go2RTCStream(name: stream.name, sources: configured)
                }
            }
            var result: [Go2RTCStream] = []
            for await stream in group { result.append(stream) }
            return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// go2rtc stream whose source is this Mi Home camera (same device id).
    private static func stream(for camera: Camera, in streams: [Go2RTCStream]) -> Go2RTCStream? {
        guard let did = camera.deviceID else { return streams.first { $0.sources.contains(camera.source.url) } }
        return streams.first { $0.sources.contains { query("did", in: $0) == did } }
    }

    nonisolated static func query(_ name: String, in source: String) -> String? {
        URLComponents(string: source)?.queryItems?.first { $0.name == name }?.value
    }

    // MARK: Choosing

    /// Registers the camera's stream in go2rtc when needed and makes it the app's camera.
    func choose(_ choice: Choice, model: AppModel) async throws {
        if AppModel.isUIPreview {
            // The preview instance shares the user's settings: never write them.
            print("[setup] preview: would choose \(choice.id)")
            return
        }
        switch choice {
        case .stream(let stream):
            model.settings.cameraTitle = stream.name
            model.settings.streamName = stream.name
        case .camera(let camera):
            var name = camera.streamName
            if name == nil {
                guard let client = model.client else { throw Go2RTCError.invalidURL }
                let fresh = uniqueStreamName(Go2RTCClient.streamName(for: camera.name))
                try await client.addStream(name: fresh, source: camera.source.url)
                streams.append(Go2RTCStream(name: fresh, sources: [camera.source.url]))
                name = fresh
            }
            model.settings.xiaomiAccountID = camera.accountID
            model.settings.xiaomiRegion = camera.region
            model.settings.cameraTitle = camera.name
            model.settings.streamName = name ?? ""
        }
        model.videoSize = nil
        Task { await model.refreshXiaomiQuality() }
        print("[setup] camera \(model.settings.streamName) (\(model.settings.cameraTitle))")
    }

    /// Adds any go2rtc source by URL (`rtsp://…`, `onvif://…`) as a new stream.
    func addStream(name: String, source: String, model: AppModel) async throws -> Go2RTCStream {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let stream = Go2RTCStream(name: name, sources: [source])
        if SetupDemo.isOn || AppModel.isUIPreview {
            streams.append(stream)
            return stream
        }
        guard let client = model.client else { throw Go2RTCError.invalidURL }
        try await client.addStream(name: name, source: source)
        streams.removeAll { $0.name == name }
        streams.append(stream)
        streams.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return stream
    }

    /// "gostinaya", or "gostinaya-2" when another source already uses that name.
    private func uniqueStreamName(_ base: String) -> String {
        let taken = Set(streams.map(\.name))
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}

// MARK: - Stills

/// Stills of go2rtc streams for tiles, rows and the Settings sidebar, cached for the app's lifetime.
@MainActor
@Observable
final class SetupStillStore {
    static let shared = SetupStillStore()

    enum State: Equatable {
        case loading
        case loaded(NSImage, CGSize)
        case failed
    }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// A camera that was offline is tried again after a while, not on every redraw.
    @ObservationIgnored private var failedAt: [String: Date] = [:]

    private func key(_ stream: String, _ model: AppModel) -> String {
        "\(model.settings.server?.baseURL.absoluteString ?? "-")|\(stream)"
    }

    func state(for stream: String, model: AppModel) -> State? {
        #if DEBUG
        if SetupDemo.isOn { return SetupDemo.still(for: stream) }
        #endif
        return states[key(stream, model)]
    }

    /// Starts loading a still unless one is cached (or loading); `force` refreshes it.
    func request(_ stream: String, model: AppModel, force: Bool = false) {
        guard !SetupDemo.isOn, model.setupServerReady, let server = model.settings.server else { return }
        let key = key(stream, model)
        if !force, let state = states[key] {
            guard state == .failed, Date().timeIntervalSince(failedAt[key] ?? .distantPast) > 60 else { return }
        }
        if tasks[key] != nil { return }
        if states[key] == nil || states[key] == .failed { states[key] = .loading }
        let embedded = model.settings.connectionMode == .embedded
        tasks[key] = Task {
            let still = await SetupFrameGrabber.grab(stream: stream, server: server, embedded: embedded)
            if let still {
                states[key] = .loaded(still.image, still.pixelSize)
            } else if case .loaded = states[key] {
                // Keep the old picture when a refresh fails.
            } else {
                states[key] = .failed
                failedAt[key] = Date()
            }
            tasks[key] = nil
        }
    }
}

/// One frame of a go2rtc stream: `/api/frame.jpeg` when the server can make JPEGs (it needs ffmpeg),
/// otherwise the first keyframe of a short `/api/stream.mp4` decoded with AVFoundation — the embedded
/// go2rtc is built without ffmpeg.
enum SetupFrameGrabber {
    struct Still {
        let image: NSImage
        let pixelSize: CGSize
    }

    static func grab(stream: String, server: Go2RTCServer, embedded: Bool) async -> Still? {
        let client = Go2RTCClient(server: server)
        if !embedded, let still = await jpeg(client: client, stream: stream) { return still }
        return await mp4Keyframe(client: client, stream: stream)
    }

    private static func request(_ url: URL, server: Go2RTCServer, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let header = server.authorizationHeader { request.setValue(header, forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func jpeg(client: Go2RTCClient, stream: String) async -> Still? {
        let request = request(client.snapshotURL(stream: stream), server: client.server, timeout: 10)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), let rep = image.representations.first else { return nil }
        return Still(image: image, pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    }

    private static func mp4Keyframe(client: Go2RTCClient, stream: String) async -> Still? {
        let url = client.url(path: "api/stream.mp4", query: ["src": stream, "video": "h264,h265"])
        let request = request(url, server: client.server, timeout: 12)
        let data: Data? = await withTaskGroup(of: Data?.self) { group in
            group.addTask { await download(request) }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let data else { return nil }
        return await decode(data)
    }

    /// Reads the fragmented MP4 until the init segment and two complete fragments have arrived.
    private static func download(_ request: URLRequest) async -> Data? {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            var data = Data()
            data.reserveCapacity(512 * 1024)
            var checked = 0
            for try await byte in bytes {
                data.append(byte)
                guard data.count - checked >= 16 * 1024 else { continue }
                checked = data.count
                if let end = completeFragmentsEnd(data, fragments: 2) { return data.prefix(end) }
                if data.count > 12_000_000 { break }
            }
            return completeFragmentsEnd(data, fragments: 1).map { data.prefix($0) }
        } catch {
            return nil
        }
    }

    /// End offset of the first `fragments` complete `mdat` boxes after the `moov`, if they have arrived.
    static func completeFragmentsEnd(_ data: Data, fragments: Int) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            func be32(_ at: Int) -> Int {
                (Int(raw[at]) << 24) | (Int(raw[at + 1]) << 16) | (Int(raw[at + 2]) << 8) | Int(raw[at + 3])
            }
            var offset = 0
            var sawMovie = false
            var found = 0
            while offset + 8 <= raw.count {
                var size = be32(offset)
                let type = String(bytes: raw[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
                if size == 1 {
                    guard offset + 16 <= raw.count else { return nil }
                    size = (be32(offset + 8) << 32) | be32(offset + 12)
                }
                guard size >= 8, offset + size <= raw.count else { return nil }
                if type == "moov" { sawMovie = true }
                if type == "mdat", sawMovie {
                    found += 1
                    if found >= fragments { return offset + size }
                }
                offset += size
            }
            return nil
        }
    }

    private static func decode(_ data: Data) async -> Still? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wp-still-\(UUID().uuidString).mp4")
        guard (try? data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        generator.maximumSize = CGSize(width: 960, height: 960)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        var size = CGSize(width: image.width, height: image.height)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize), natural.width > 0 {
            size = CGSize(width: abs(natural.width), height: abs(natural.height))
        }
        return Still(image: NSImage(cgImage: image, size: .zero), pixelSize: size)
    }
}

/// A still of a go2rtc stream (16:9), or a quiet camera glyph while there is none.
struct SetupStill: View {
    @Environment(AppModel.self) private var model
    /// Registered stream; `nil` for a Mi Home camera that is not a go2rtc stream yet.
    let stream: String?
    var width: CGFloat
    var cornerRadius: CGFloat = 6
    var symbol = "video.fill"

    var body: some View {
        let state = stream.flatMap { SetupStillStore.shared.state(for: $0, model: model) }
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            Image(systemName: state == .failed ? "video.slash.fill" : symbol)
                .font(.system(size: max(11, width * 0.1), weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            if case .loaded(let image, _) = state {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: width * 9 / 16)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .animation(.easeOut(duration: 0.25), value: state)
        .task(id: "\(stream ?? "-")|\(model.setupServerReady)") {
            if let stream { SetupStillStore.shared.request(stream, model: model) }
        }
    }
}
#endif
