import Foundation
import Observation
import WaitingPawsCore

/// Night mode, image flip and the other settings the selected Mi Home camera declares in its MIoT spec.
/// The values live in the camera and change through Mi Cloud (go2rtc `/api/xiaomi/miot`), as in Mi Home,
/// so they work from the iPhone linked to a Mac as well.
@MainActor
@Observable
final class CameraModesModel {
    enum State: Equatable {
        /// Not a Mi Home camera, a model without settings, or a go2rtc that cannot change them.
        case none
        case loading
        case ready
        /// Settings are known but the camera did not answer: shown disabled with the reason.
        case unavailable(String)
    }

    private(set) var state: State = .none
    private(set) var options: [CameraModeOption] = []
    private(set) var values: [MiotPropertyID: MiotValue] = [:]
    /// Settings being written right now.
    private(set) var pending: Set<MiotPropertyID> = []
    /// The last failed change, shown next to the settings.
    var changeError: String?

    private var client: Go2RTCClient?
    private var source: String?
    private var generation = 0
    private var isDemo = false

    private let specs = MiotSpecProvider(cacheDirectory:
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MiotSpec", isDirectory: true))

    /// Whether there is anything to show for this camera.
    var hasOptions: Bool { !options.isEmpty }
    var isReady: Bool { state == .ready }

    var pictureOptions: [CameraModeOption] { options.filter { $0.setting.isPicture } }
    var behaviourOptions: [CameraModeOption] { options.filter { !$0.setting.isPicture } }
    var nightMode: CameraModeOption? { options.first { $0.setting == .nightShot } }

    /// Reads which settings the camera has and their current values. `source` is the stream's
    /// `xiaomi://` URL (nil for other cameras).
    func load(server: Go2RTCServer?, source: String?) async {
        generation += 1
        let current = generation
        guard !isDemo else { return }
        changeError = nil
        guard let server, let source, let model = URLComponents(string: source)?.queryItems?
            .first(where: { $0.name == "model" })?.value, !model.isEmpty else {
            reset()
            return
        }
        let client = Go2RTCClient(server: server)
        if self.source != source {
            options = []
            values = [:]
        }
        self.client = client
        self.source = source
        state = .loading

        let found: [CameraModeOption]
        do {
            found = try await specs.cameraModes(model: model)
        } catch {
            guard current == generation else { return }
            print("[camera-modes] spec for \(model): \(error.localizedDescription)")
            reset()
            return
        }
        guard current == generation else { return }
        guard !found.isEmpty else {
            print("[camera-modes] \(model): no settings in its spec")
            reset()
            return
        }
        options = found

        do {
            let read = try await client.xiaomiProperties(source: source, found.map(\.property))
            guard current == generation else { return }
            values = read
            // Settings the camera did not report are not shown (e.g. tracking on a fixed camera).
            options = found.filter { read[$0.property] != nil }
            state = options.isEmpty ? .none : .ready
        } catch Go2RTCError.http(let status, _) where status == 404 {
            // A go2rtc without the Waiting Paws addition (an external server).
            guard current == generation else { return }
            reset()
        } catch {
            guard current == generation else { return }
            print("[camera-modes] read \(model): \(error.localizedDescription)")
            state = .unavailable(Self.message(error))
        }
    }

    func set(_ option: CameraModeOption, to value: MiotValue) async {
        guard values[option.property] != value, !pending.contains(option.property) else { return }
        let previous = values[option.property]
        values[option.property] = value
        changeError = nil
        guard !isDemo else { return }
        guard let client, let source else { return }
        pending.insert(option.property)
        defer { pending.remove(option.property) }
        do {
            try await client.setXiaomiProperty(source: source, option.property, to: value)
            print("[camera-modes] \(option.setting.rawValue) = \(option.text(for: value))")
        } catch {
            values[option.property] = previous
            changeError = "\(option.title): \(Self.message(error))"
        }
    }

    func value(_ option: CameraModeOption) -> MiotValue? { values[option.property] }

    func isOn(_ option: CameraModeOption) -> Bool { values[option.property]?.isOn ?? false }

    func choice(_ option: CameraModeOption) -> Int { values[option.property]?.number ?? option.choices.first?.value ?? 0 }

    func canChange(_ option: CameraModeOption) -> Bool { isReady && !pending.contains(option.property) }

    private func reset() {
        state = .none
        options = []
        values = [:]
        client = nil
        source = nil
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? XiaomiCameraError { return error.localizedDescription }
        if case .http(502, let text)? = error as? Go2RTCError {
            // go2rtc could not reach Mi Cloud or the account token expired.
            return text.contains("401") ? "вход в Xiaomi истёк — войдите заново" : "облако Xiaomi недоступно"
        }
        return error.localizedDescription
    }

    #if DEBUG
    /// `--demo-camera-modes`: the C302's settings with sample values; changes stay in memory.
    func loadDemo() {
        isDemo = true
        options = (try? MiotSpec.cameraModes(fromSpec: Data(DemoData.c302Spec.utf8))) ?? []
        values = Dictionary(uniqueKeysWithValues: options.map { option in
            switch option.kind {
            case .toggle: return (option.property, MiotValue.bool(option.setting == .indicatorLight || option.setting == .timeWatermark))
            case .choice(let choices): return (option.property, MiotValue.int(choices.first?.value ?? 0))
            }
        })
        state = .ready
    }
    #endif
}
