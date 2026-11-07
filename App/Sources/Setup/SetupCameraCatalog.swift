import AVFoundation
import SwiftUI
import WaitingPawsCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
        /// Mi Home model id from the source URL ("chuangmi.camera.069a01"): for tooltips only.
        var model: String? { SetupCameraCatalog.query("model", in: source.url) }
        var deviceID: String? { SetupCameraCatalog.query("did", in: source.url) }
        /// The camera's address in the home network, which go2rtc dials. Mi Home gives none for a camera
        /// that is offline: no preview is tried then.
        var host: String? {
            guard let host = URLComponents(string: source.url)?.host, !host.isEmpty else { return nil }
            return host
        }
        /// "Камера Xiaomi" instead of "chuangmi.camera.039a01".
        var kind: String { SetupText.cameraKind(model: model) }
        /// Tooltip with what the readable text leaves out: the Mi Home model id and the address.
        var technicalDetails: String {
            [model.map { String(localized: "Модель Mi Home: \($0)") }, host.map { "IP \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        /// What its still shows: the go2rtc stream, or a preview of the camera itself.
        var stillSource: SetupStillSource { streamName.map { .stream($0) } ?? .camera(self) }
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

    /// Prefix of the short-lived go2rtc streams that fetch a preview of a Mi Home camera go2rtc does not
    /// play yet (`SetupStillStore`). They are left out of every list and never saved as the app's camera.
    nonisolated static let previewPrefix = "__wp_preview_"

    nonisolated static func isPreviewStream(_ name: String) -> Bool { name.hasPrefix(previewPrefix) }

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

    /// Which of the app's cameras a choice goes to: the one shown and recorded, or the second one only to look at.
    enum Target {
        case main, second
    }

    /// Selection id of the camera the app uses now (as `target`).
    func currentID(_ model: AppModel, target: Target = .main) -> String? {
        let name = target == .main ? model.settings.streamName : model.settings.secondStreamName
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
        #if WP_NO_XIAOMI
        // A build without Xiaomi (`NoXiaomiText`) lists streams only.
        let ids: [String] = []
        #else
        // A server without the xiaomi module answers 404 here: simply no accounts.
        let ids = (try? await client.xiaomiAccounts()) ?? []
        #endif
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
        let loadedAll = await loadedStreams
        // Preview streams of a quit or crashed preview: not the user's, removed quietly.
        SetupStillStore.shared.removeLeftoverPreviews(loadedAll.map(\.name), model: model)
        let allStreams = loadedAll.filter { !Self.isPreviewStream($0.name) }
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
                    guard stream.sources.isEmpty, !SetupCameraCatalog.isPreviewStream(stream.name),
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

    /// Registers the camera's stream in go2rtc when needed and makes it the app's camera (or its second one).
    func choose(_ choice: Choice, model: AppModel, target: Target = .main) async throws {
        if AppModel.isUIPreview {
            // The preview instance shares the user's settings: never write them.
            print("[setup] preview: would choose \(choice.id)")
            return
        }
        if target == .second {
            try await chooseSecond(choice, model: model)
            return
        }
        switch choice {
        case .stream(let stream):
            guard !Self.isPreviewStream(stream.name) else { throw SetupError(String(localized: "Это временный поток превью, его нельзя выбрать")) }
            model.settings.cameraTitle = stream.name
            model.settings.streamName = stream.name
        case .camera(let camera):
            var name = camera.streamName.flatMap { Self.isPreviewStream($0) ? nil : $0 }
            if name == nil {
                guard let client = model.client else { throw Go2RTCError.invalidURL }
                // One connection to the camera at a time: a preview still running gives way first.
                await SetupStillStore.shared.cancelPreview(of: camera, model: model)
                let fresh = uniqueStreamName(Go2RTCClient.streamName(for: camera.name))
                try await client.addStream(name: fresh, source: camera.source.url)
                streams.append(Go2RTCStream(name: fresh, sources: [camera.source.url]))
                SetupStillStore.shared.adoptPreview(of: camera, as: fresh, model: model)
                name = fresh
            }
            model.settings.xiaomiAccountID = camera.accountID
            model.settings.xiaomiRegion = camera.region
            model.settings.cameraTitle = camera.name
            model.settings.streamName = name ?? ""
        }
        // The second camera made the first one: no second one left.
        if model.settings.secondStreamName == model.settings.streamName { model.removeSecondCamera() }
        model.videoSize = nil
        model.followShownCameraInRecording()
        Task { await model.refreshXiaomiQuality() }
        print("[setup] camera \(model.settings.streamName) (\(model.settings.cameraTitle))")
    }

    /// The second camera: its stream registered like the first one's, the app's settings of the first one untouched.
    private func chooseSecond(_ choice: Choice, model: AppModel) async throws {
        let name: String
        let title: String
        switch choice {
        case .stream(let stream):
            guard !Self.isPreviewStream(stream.name) else { throw SetupError(String(localized: "Это временный поток превью, его нельзя выбрать")) }
            name = stream.name
            title = stream.name
        case .camera(let camera):
            if let existing = camera.streamName.flatMap({ Self.isPreviewStream($0) ? nil : $0 }) {
                name = existing
            } else {
                guard let client = model.client else { throw Go2RTCError.invalidURL }
                await SetupStillStore.shared.cancelPreview(of: camera, model: model)
                let fresh = uniqueStreamName(Go2RTCClient.streamName(for: camera.name))
                try await client.addStream(name: fresh, source: camera.source.url)
                streams.append(Go2RTCStream(name: fresh, sources: [camera.source.url]))
                SetupStillStore.shared.adoptPreview(of: camera, as: fresh, model: model)
                name = fresh
            }
            title = camera.name
        }
        guard name != model.settings.streamName else {
            throw SetupError(String(localized: "Эта камера уже основная — выберите другую"))
        }
        model.settings.secondCameraTitle = title
        model.settings.secondStreamName = name
        model.secondVideoSize = nil
        model.followShownCameraInRecording()
        print("[setup] second camera \(name) (\(title))")
    }

    /// Adds any go2rtc source by URL (`rtsp://…`, `onvif://…`) as a new stream.
    func addStream(name: String, source: String, model: AppModel) async throws -> Go2RTCStream {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isPreviewStream(name) else {
            throw SetupError(String(localized: "Имена на «\(Self.previewPrefix)» заняты Waiting Paws"))
        }
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

/// A message for the user, shown as is.
struct SetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Stills

/// What a still shows: a go2rtc stream, or a Mi Home camera go2rtc does not play yet (a preview).
enum SetupStillSource: Hashable {
    case stream(String)
    case camera(SetupCameraCatalog.Camera)

    var id: String {
        switch self {
        case .stream(let name): return SetupCameraCatalog.streamID(name)
        case .camera(let camera): return camera.id
        }
    }
}

/// Stills for tiles, rows and the Settings sidebar, cached for the app's lifetime: frames of go2rtc streams
/// and previews of Mi Home cameras that are not streams yet.
///
/// A preview registers a temporary stream `__wp_preview_<did>` with the camera's `xiaomi://` source, takes one
/// keyframe from it and deletes it again — also after a failure, a timeout or a cancel. At most two previews
/// run at a time (each is a P2P session to a camera) and each gets 12 s. The user's own streams are never touched.
@MainActor
@Observable
final class SetupStillStore {
    static let shared = SetupStillStore()

    enum State: Equatable {
        case loading
        case loaded(PlatformImage, CGSize)
        case failed
    }

    static let previewTimeout: Duration = .seconds(12)

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// A camera that was offline is tried again after a while, not on every redraw.
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private let previewSlots = SetupPreviewSlots(limit: 2)
    /// Temporary streams that exist in go2rtc right now: the leftovers cleanup keeps away from them.
    @ObservationIgnored private var livePreviewStreams: Set<String> = []

    private func key(_ stream: String, _ model: AppModel) -> String {
        "\(model.settings.server?.baseURL.absoluteString ?? "-")|\(stream)"
    }

    private func previewKey(_ camera: SetupCameraCatalog.Camera, _ model: AppModel) -> String {
        key(Self.previewStreamName(camera), model)
    }

    /// `__wp_preview_1093845577`: one per camera, so two windows asking for the same preview share it.
    nonisolated static func previewStreamName(_ camera: SetupCameraCatalog.Camera) -> String {
        let raw = camera.deviceID ?? camera.source.url
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var safe = String(String.UnicodeScalarView(raw.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        if camera.deviceID == nil || safe.count > 40 { safe = String(safe.suffix(40)) }
        return SetupCameraCatalog.previewPrefix + safe
    }

    func state(for stream: String, model: AppModel) -> State? {
        state(for: .stream(stream), model: model)
    }

    func state(for source: SetupStillSource, model: AppModel) -> State? {
        #if DEBUG
        if SetupDemo.isOn { return SetupDemo.still(for: source) }
        #endif
        switch source {
        case .stream(let name):
            return states[key(name, model)]
        case .camera(let camera):
            // No address in the home network: Mi Home sees the camera offline.
            if camera.host == nil { return .failed }
            return states[previewKey(camera, model)]
        }
    }

    /// Starts loading a still unless one is cached (or loading). `force` refreshes a stream's still and
    /// retries a failed preview; a preview that came through stays for the session.
    func request(_ source: SetupStillSource, model: AppModel, force: Bool = false) {
        switch source {
        case .stream(let name): request(name, model: model, force: force)
        case .camera(let camera): requestPreview(camera, model: model, force: force)
        }
    }

    func request(_ stream: String, model: AppModel, force: Bool = false) {
        guard !SetupDemo.isOn, model.setupServerReady, let server = model.settings.server,
              !SetupCameraCatalog.isPreviewStream(stream) else { return }
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

    // MARK: Mi Home previews

    private func requestPreview(_ camera: SetupCameraCatalog.Camera, model: AppModel, force: Bool) {
        guard !SetupDemo.isOn, camera.streamName == nil, camera.host != nil,
              model.setupServerReady, let server = model.settings.server else { return }
        let key = previewKey(camera, model)
        switch states[key] {
        case .loading, .loaded: return
        case .failed:
            guard force || Date().timeIntervalSince(failedAt[key] ?? .distantPast) > 120 else { return }
        case nil: break
        }
        if tasks[key] != nil { return }
        states[key] = .loading
        let stream = Self.previewStreamName(camera)
        let source = camera.source.url
        let embedded = model.settings.connectionMode == .embedded
        tasks[key] = Task {
            let still = await preview(source: source, stream: stream, server: server, embedded: embedded)
            if Task.isCancelled {
                // Cancelled for a real stream of the same camera (`cancelPreview`): nothing is known.
                if states[key] == .loading { states[key] = nil }
            } else if let still {
                states[key] = .loaded(still.image, still.pixelSize)
            } else {
                states[key] = .failed
                failedAt[key] = Date()
            }
            tasks[key] = nil
        }
    }

    /// Waits for a free slot, registers the temporary stream, grabs a keyframe within the time budget and
    /// removes the stream whatever happened.
    private func preview(source: String, stream: String, server: Go2RTCServer, embedded: Bool) async -> SetupFrameGrabber.Still? {
        guard await previewSlots.acquire() else { return nil }
        defer { previewSlots.release() }
        guard !Task.isCancelled else { return nil }
        let client = Go2RTCClient(server: server)
        livePreviewStreams.insert(stream)
        let still = await SetupFrameGrabber.withDeadline(Self.previewTimeout) { () async -> SetupFrameGrabber.Still? in
            do {
                try await client.addStream(name: stream, source: source)
            } catch {
                print("[setup] preview \(stream): \(error.localizedDescription)")
                return nil
            }
            return await SetupFrameGrabber.grab(stream: stream, server: server, embedded: embedded)
        }
        // A fresh task: the delete has to go out even when this one was cancelled.
        await Task { await Self.deletePreviewStream(stream, client: client) }.value
        livePreviewStreams.remove(stream)
        return still
    }

    nonisolated private static func deletePreviewStream(_ stream: String, client: Go2RTCClient) async {
        guard SetupCameraCatalog.isPreviewStream(stream) else { return }
        for attempt in 0..<2 {
            do {
                try await client.deleteStream(name: stream)
                return
            } catch {
                print("[setup] preview \(stream) not removed (\(attempt + 1)): \(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Stops a preview of `camera` (and waits until its temporary stream is gone).
    func cancelPreview(of camera: SetupCameraCatalog.Camera, model: AppModel) async {
        guard let task = tasks[previewKey(camera, model)] else { return }
        task.cancel()
        await task.value
    }

    /// The camera became the go2rtc stream `stream`: its preview serves as that stream's still until a real one comes.
    func adoptPreview(of camera: SetupCameraCatalog.Camera, as stream: String, model: AppModel) {
        guard case .loaded = states[previewKey(camera, model)], states[key(stream, model)] == nil else { return }
        states[key(stream, model)] = states[previewKey(camera, model)]
    }

    /// Removes temporary preview streams that outlived their preview (the app quit in the middle of one).
    func removeLeftoverPreviews(_ streams: [String], model: AppModel) {
        guard !AppModel.isUIPreview, let client = model.client else { return }
        for stream in streams where SetupCameraCatalog.isPreviewStream(stream) && !livePreviewStreams.contains(stream) {
            print("[setup] removing leftover preview stream \(stream)")
            Task { await Self.deletePreviewStream(stream, client: client) }
        }
    }
}

/// At most `limit` previews at once; the rest wait in order. A waiting preview that is cancelled leaves the queue.
@MainActor
private final class SetupPreviewSlots {
    private let limit: Int
    private var busy = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { self.limit = limit }

    /// `false` when cancelled while waiting (no slot is held then).
    func acquire() async -> Bool {
        if busy < limit {
            busy += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.leave(id) }
        }
    }

    /// Hands the slot to the next preview in line, or frees it.
    func release() {
        if waiting.isEmpty {
            busy -= 1
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    private func leave(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}

/// One frame of a go2rtc stream: `/api/frame.jpeg` when the server can make JPEGs (it needs ffmpeg),
/// otherwise the first keyframe of a short `/api/stream.mp4` decoded with AVFoundation — the embedded
/// go2rtc is built without ffmpeg.
enum SetupFrameGrabber {
    /// Made once and only read afterwards.
    struct Still: @unchecked Sendable {
        let image: PlatformImage
        let pixelSize: CGSize
    }

    /// `operation`'s result, or `nil` once `timeout` has passed — the operation is cancelled then.
    static func withDeadline<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
              let image = PlatformImage(data: data) else { return nil }
        #if os(macOS)
        guard let rep = image.representations.first else { return nil }
        return Still(image: image, pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        #else
        guard let cgImage = image.cgImage else { return nil }
        return Still(image: image, pixelSize: CGSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    private static func mp4Keyframe(client: Go2RTCClient, stream: String) async -> Still? {
        let url = client.url(path: "api/stream.mp4", query: ["src": stream, "video": "h264,h265"])
        let request = request(url, server: client.server, timeout: 12)
        guard let data = await withDeadline(.seconds(15), { await download(request) }) else { return nil }
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
        #if os(macOS)
        return Still(image: NSImage(cgImage: image, size: .zero), pixelSize: size)
        #else
        return Still(image: UIImage(cgImage: image), pixelSize: size)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// A still (16:9) of a go2rtc stream or a Mi Home camera, or a quiet camera glyph while there is none.
struct SetupStill: View {
    @Environment(AppModel.self) private var model
    let source: SetupStillSource?
    var width: CGFloat
    var cornerRadius: CGFloat = 6
    var symbol = "video.fill"

    init(source: SetupStillSource?, width: CGFloat, cornerRadius: CGFloat = 6, symbol: String = "video.fill") {
        self.source = source
        self.width = width
        self.cornerRadius = cornerRadius
        self.symbol = symbol
    }

    init(stream: String?, width: CGFloat, cornerRadius: CGFloat = 6, symbol: String = "video.fill") {
        self.init(source: stream.map { .stream($0) }, width: width, cornerRadius: cornerRadius, symbol: symbol)
    }

    var body: some View {
        let state = source.flatMap { SetupStillStore.shared.state(for: $0, model: model) }
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            Image(systemName: state == .failed ? "video.slash.fill" : symbol)
                .font(.system(size: max(11, width * 0.1), weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            if case .loaded(let image, _) = state {
                Image(platformImage: image)
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
        .task(id: "\(source?.id ?? "-")|\(model.setupServerReady)") {
            if let source { SetupStillStore.shared.request(source, model: model) }
        }
    }
}
