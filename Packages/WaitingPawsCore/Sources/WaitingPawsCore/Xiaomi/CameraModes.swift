import Foundation

/// A MIoT property value. Camera switches are bools, modes are small integers.
public enum MiotValue: Codable, Equatable, Hashable, Sendable {
    case bool(Bool)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .int(number)
        } else if let number = try? container.decode(Double.self) {
            self = .int(Int(number))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a bool or a number")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let flag): try container.encode(flag)
        case .int(let number): try container.encode(number)
        }
    }

    /// Some firmwares answer 0/1 for bool properties.
    public var isOn: Bool {
        switch self {
        case .bool(let flag): return flag
        case .int(let number): return number != 0
        }
    }

    public var number: Int {
        switch self {
        case .bool(let flag): return flag ? 1 : 0
        case .int(let number): return number
        }
    }

    var jsonObject: Any {
        switch self {
        case .bool(let flag): return flag
        case .int(let number): return number
        }
    }
}

/// Service and property instance ids of a MIoT property (they differ from model to model).
public struct MiotPropertyID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var siid: Int
    public var piid: Int

    public init(siid: Int, piid: Int) {
        self.siid = siid
        self.piid = piid
    }

    public var description: String { "\(siid).\(piid)" }
}

/// Camera settings the app knows how to present, in display order.
public enum CameraSetting: String, CaseIterable, Sendable {
    case nightShot, glimmerFullColor, wdr, distortionCorrection, imageRollover, timeWatermark, powerFrequency
    case motionTracking, humanTracking, petTracking, indicatorLight

    /// Names from the spec URNs (`urn:miot-spec-v2:service:camera-control:…`, `…:property:night-shot:…`).
    var specNames: (service: String, property: String) {
        switch self {
        case .nightShot: return ("camera-control", "night-shot")
        case .glimmerFullColor: return ("camera-control", "glimmer-full-color")
        case .wdr: return ("camera-control", "wdr-mode")
        case .distortionCorrection: return ("camera-control", "image-distortion-correction")
        case .imageRollover: return ("camera-control", "image-rollover")
        case .timeWatermark: return ("camera-control", "time-watermark")
        case .powerFrequency: return ("camera-control", "power-frequency")
        case .motionTracking: return ("camera-control", "motion-tracking")
        case .humanTracking: return ("camera-control", "human-tracking")
        case .petTracking: return ("ai-detection", "pet-tracking")
        case .indicatorLight: return ("indicator-light", "on")
        }
    }

    public var title: String {
        switch self {
        case .nightShot: return tr("Режим съёмки", "Night vision")
        case .glimmerFullColor: return tr("Цветная ночная съёмка", "Full-color night vision")
        case .wdr: return tr("WDR (широкий диапазон)", "WDR (wide dynamic range)")
        case .distortionCorrection: return tr("Коррекция искажений", "Lens distortion correction")
        case .imageRollover: return tr("Поворот изображения", "Rotate image")
        case .timeWatermark: return tr("Время на изображении", "Time stamp on video")
        case .powerFrequency: return tr("Частота сети", "Power line frequency")
        case .motionTracking: return tr("Следить за движением", "Motion tracking")
        case .humanTracking: return tr("Следить за человеком", "Human tracking")
        case .petTracking: return tr("Следить за питомцем", "Pet tracking")
        case .indicatorLight: return tr("Индикатор на камере", "Status light")
        }
    }

    /// One line under the title where the name alone is not obvious.
    public var hint: String? {
        switch self {
        case .nightShot: return tr("Ночной — ИК-подсветка, чёрно-белая картинка.", "Night uses infrared light and a black-and-white picture.")
        case .glimmerFullColor: return tr("Цвет при слабом свете вместо ИК.", "Color in low light instead of infrared.")
        case .powerFrequency: return tr("Убирает мерцание от ламп.", "Removes flicker from lamps.")
        case .motionTracking, .humanTracking, .petTracking: return tr("Поворотная камера сама ведёт объектив.", "A pan-tilt camera follows on its own.")
        default: return nil
        }
    }

    public var systemImage: String {
        switch self {
        case .nightShot: return "moon.stars"
        case .glimmerFullColor: return "moon.haze"
        case .wdr: return "camera.aperture"
        case .distortionCorrection: return "camera.viewfinder"
        case .imageRollover: return "rotate.right"
        case .timeWatermark: return "clock"
        case .powerFrequency: return "bolt"
        case .motionTracking: return "figure.walk.motion"
        case .humanTracking: return "figure.walk"
        case .petTracking: return "pawprint"
        case .indicatorLight: return "lightbulb"
        }
    }

    /// Picture settings first, then what the camera does by itself.
    public var isPicture: Bool {
        switch self {
        case .motionTracking, .humanTracking, .petTracking, .indicatorLight: return false
        default: return true
        }
    }
}

/// One camera setting as a particular model declares it.
public struct CameraModeOption: Identifiable, Equatable, Hashable, Sendable {
    public struct Choice: Identifiable, Equatable, Hashable, Sendable {
        public var value: Int
        public var title: String
        public var id: Int { value }

        public init(value: Int, title: String) {
            self.value = value
            self.title = title
        }
    }

    public enum Kind: Equatable, Hashable, Sendable {
        case toggle
        case choice([Choice])
    }

    public var setting: CameraSetting
    public var property: MiotPropertyID
    public var kind: Kind

    public init(setting: CameraSetting, property: MiotPropertyID, kind: Kind) {
        self.setting = setting
        self.property = property
        self.kind = kind
    }

    public var id: MiotPropertyID { property }
    public var title: String { setting.title }
    public var hint: String? { setting.hint }
    public var systemImage: String { setting.systemImage }

    public var choices: [Choice] {
        if case .choice(let choices) = kind { return choices }
        return []
    }

    /// The value to write: switches are bools, modes are integers.
    public func value(on: Bool) -> MiotValue { .bool(on) }
    public func value(choice: Int) -> MiotValue { .int(choice) }

    /// Title of the current value ("Авто", "Включено").
    public func text(for value: MiotValue?) -> String {
        guard let value else { return "—" }
        switch kind {
        case .toggle: return value.isOn ? tr("Включено", "On") : tr("Выключено", "Off")
        case .choice(let choices): return choices.first { $0.value == value.number }?.title ?? "\(value.number)"
        }
    }
}

/// One step of a pan/tilt camera: the motor operation Mi Home sends over the camera's P2P session
/// (go2rtc `/api/xiaomi/motor`). A step turns the camera by about a tenth of the frame.
public enum PanTiltDirection: Int, CaseIterable, Sendable {
    case left = 1, right, up, down
}

/// What the app reads from a camera's spec: the settings it shows and whether the camera turns.
public struct CameraSpec: Equatable, Sendable {
    public var modes: [CameraModeOption]
    /// A pan/tilt camera. The spec has no commands for turning (that goes over the P2P session), so this is read from
    /// what only such cameras declare: `ptz-camera`, a PTZ action (`ptz-calibrate`) or a tracking switch.
    public var panTilt: Bool

    public init(modes: [CameraModeOption], panTilt: Bool) {
        self.modes = modes
        self.panTilt = panTilt
    }
}

/// Reads device specs published on miot-spec.org (the same ones Mi Home uses).
public enum MiotSpec {
    public enum SpecError: LocalizedError {
        case unreadable
        public var errorDescription: String? { tr("Не удалось разобрать описание камеры (MIoT spec)", "Couldn't read the camera's description (MIoT spec)") }
    }

    /// The settings from `CameraSetting` that the spec (`/miot-spec-v2/instance?type=…`) declares as readable
    /// and writable, with their choices translated. Value meanings come from the spec: night-shot 0 is
    /// "Off" on some models and "On" on others.
    public static func cameraModes(fromSpec data: Data) throws -> [CameraModeOption] {
        try cameraSpec(fromSpec: data).modes
    }

    /// The settings (see `cameraModes(fromSpec:)`) and whether the camera turns.
    public static func cameraSpec(fromSpec data: Data) throws -> CameraSpec {
        guard let document = try? JSONDecoder().decode(SpecDocument.self, from: data) else { throw SpecError.unreadable }
        return CameraSpec(modes: modes(in: document), panTilt: isPanTilt(document))
    }

    /// `ptz-camera`, `ptz-calibrate`, a `ptz`/`motor` service, or motion / human / pet tracking (the camera follows by
    /// turning). Fixed cameras (Xiaofang, the Basic 1080p) declare none of these.
    private static func isPanTilt(_ document: SpecDocument) -> Bool {
        document.services.contains { service in
            let serviceName = urnName(service.type)
            if serviceName.contains("ptz") || serviceName.contains("motor") { return true }
            if (service.properties ?? []).contains(where: {
                let name = urnName($0.type)
                return name.hasPrefix("ptz") || name.hasSuffix("tracking")
            }) { return true }
            return (service.actions ?? []).contains {
                let name = urnName($0.type)
                return name.hasPrefix("ptz") || name.contains("motor")
            }
        }
    }

    private static func modes(in document: SpecDocument) -> [CameraModeOption] {
        var found: [CameraSetting: CameraModeOption] = [:]
        for service in document.services {
            let serviceName = urnName(service.type)
            for property in service.properties ?? [] {
                let access = Set(property.access ?? [])
                guard access.contains("read"), access.contains("write") else { continue }
                let propertyName = urnName(property.type)
                guard let setting = CameraSetting.allCases.first(where: {
                    $0.specNames == (serviceName, propertyName)
                }), found[setting] == nil else { continue }
                let id = MiotPropertyID(siid: service.iid, piid: property.iid)
                if let kind = kind(for: setting, property) {
                    found[setting] = CameraModeOption(setting: setting, property: id, kind: kind)
                }
            }
        }
        return CameraSetting.allCases.compactMap { found[$0] }
    }

    /// Type URN of the newest spec for `model` in the instance list (`/miot-spec-v2/instances?status=released`).
    public static func specType(forModel model: String, inIndex data: Data) throws -> String? {
        guard let index = try? JSONDecoder().decode(SpecIndex.self, from: data) else { throw SpecError.unreadable }
        return index.instances
            .filter { $0.model == model }
            .max { ($0.version ?? 0) < ($1.version ?? 0) }?
            .type
    }

    /// `urn:miot-spec-v2:property:night-shot:00000…:xiaomi-c302n:1` → `night-shot`.
    static func urnName(_ urn: String) -> String {
        let parts = urn.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count > 3 ? String(parts[3]) : ""
    }

    private static func kind(for setting: CameraSetting, _ property: SpecProperty) -> CameraModeOption.Kind? {
        if property.format == "bool" { return .toggle }
        let choices: [CameraModeOption.Choice]
        switch setting {
        case .nightShot:
            choices = (property.valueList ?? [])
                .compactMap { item in nightTitle(item.description).map { (item.value, $0) } }
                .sorted { $0.1.order < $1.1.order }
                .map { .init(value: $0.0, title: $0.1.title) }
        case .powerFrequency:
            choices = (property.valueList ?? []).map { item in
                let text = item.description.trimmingCharacters(in: .whitespaces)
                if text.lowercased().contains("auto") { return .init(value: item.value, title: tr("Авто", "Auto")) }
                let digits = text.filter(\.isNumber)
                return .init(value: item.value, title: digits.isEmpty ? text : tr("\(digits) Гц", "\(digits) Hz"))
            }
        case .imageRollover:
            if let list = property.valueList, !list.isEmpty {
                choices = list.map { .init(value: $0.value, title: rolloverTitle($0.value)) }
            } else if let range = property.valueRange, range.count >= 3, Int(range[2]) > 0 {
                // [0, 180, 180] → 0°, 180°; some specs declare 360, which is 0° again.
                let values = stride(from: Int(range[0]), through: Int(range[1]), by: Int(range[2])).filter { $0 < 360 }
                choices = values.prefix(8).map { .init(value: $0, title: rolloverTitle($0)) }
            } else {
                choices = []
            }
        default:
            choices = (property.valueList ?? []).map { .init(value: $0.value, title: $0.description) }
        }
        return choices.count >= 2 ? .choice(choices) : nil
    }

    /// Spec descriptions are English: "Auto", "On", "Off", sometimes "Open"/"Close".
    private static func nightTitle(_ description: String) -> (order: Int, title: String)? {
        let text = description.lowercased().trimmingCharacters(in: .whitespaces)
        if text.contains("auto") { return (0, tr("Авто", "Auto")) }
        if text == "on" || text.contains("open") || text.hasSuffix(" on") { return (1, tr("Ночной", "Night")) }
        if text == "off" || text.contains("close") || text.hasSuffix(" off") { return (2, tr("Обычный", "Day")) }
        return nil
    }

    private static func rolloverTitle(_ degrees: Int) -> String {
        degrees == 0 ? tr("Без поворота", "Not rotated") : "\(degrees)°"
    }

    // MARK: - Spec JSON

    private struct SpecDocument: Decodable {
        var services: [SpecService]
    }

    private struct SpecService: Decodable {
        var iid: Int
        var type: String
        var properties: [SpecProperty]?
        var actions: [SpecAction]?
    }

    private struct SpecAction: Decodable {
        var type: String
    }

    private struct SpecProperty: Decodable {
        var iid: Int
        var type: String
        var format: String?
        var access: [String]?
        var valueList: [SpecValue]?
        var valueRange: [Double]?

        enum CodingKeys: String, CodingKey {
            case iid, type, format, access
            case valueList = "value-list"
            case valueRange = "value-range"
        }
    }

    private struct SpecValue: Decodable {
        var value: Int
        var description: String

        enum CodingKeys: String, CodingKey { case value, description }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = Int(try container.decode(Double.self, forKey: .value))
            description = (try? container.decode(String.self, forKey: .description)) ?? ""
        }
    }

    private struct SpecIndex: Decodable {
        struct Instance: Decodable {
            var model: String
            var version: Int?
            var type: String
        }
        var instances: [Instance]
    }
}

/// Downloads device specs from miot-spec.org (public, no account) and keeps them on disk:
/// a model's settings never change, the 2 MB model index is refreshed monthly.
public actor MiotSpecProvider {
    private let cacheDirectory: URL
    private let session: URLSession
    private var memory: [String: CameraSpec] = [:]
    private static let maxAge: TimeInterval = 30 * 24 * 3600
    private static let base = URL(string: "https://miot-spec.org/miot-spec-v2/")!

    public init(cacheDirectory: URL, session: URLSession = .shared) {
        self.cacheDirectory = cacheDirectory
        self.session = session
    }

    /// Camera settings `model` (e.g. `xiaomi.camera.c302n`) declares; empty when the model has no published spec.
    public func cameraModes(model: String) async throws -> [CameraModeOption] {
        try await cameraSpec(model: model).modes
    }

    /// Settings and pan/tilt of `model`; no settings and no turning when the model has no published spec.
    public func cameraSpec(model: String) async throws -> CameraSpec {
        if let cached = memory[model] { return cached }
        let file = cacheDirectory.appendingPathComponent(Self.fileName(model) + ".json")
        if let data = try? Data(contentsOf: file), let spec = try? MiotSpec.cameraSpec(fromSpec: data) {
            memory[model] = spec
            return spec
        }
        guard let type = try await specType(model: model) else {
            let none = CameraSpec(modes: [], panTilt: false)
            memory[model] = none
            return none
        }
        var components = URLComponents(url: Self.base.appendingPathComponent("instance"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "type", value: type)]
        let data = try await fetch(components.url!)
        let spec = try MiotSpec.cameraSpec(fromSpec: data)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: file)
        memory[model] = spec
        return spec
    }

    private func specType(model: String) async throws -> String? {
        let file = cacheDirectory.appendingPathComponent("instances.json")
        let cached = try? Data(contentsOf: file)
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            .map { Date().timeIntervalSince($0) } ?? .infinity
        // A fresh index that knows the model; a new model may need a newer index, but not more than daily.
        if let cached, age < Self.maxAge, let type = try? MiotSpec.specType(forModel: model, inIndex: cached) {
            return type
        }
        if cached != nil, age < 24 * 3600 { return nil }
        var components = URLComponents(url: Self.base.appendingPathComponent("instances"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "status", value: "released")]
        do {
            let data = try await fetch(components.url!)
            let type = try MiotSpec.specType(forModel: model, inIndex: data)
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: file)
            return type
        } catch {
            if let cached, let type = try? MiotSpec.specType(forModel: model, inIndex: cached) { return type }
            throw error
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Go2RTCError.http(status: status, message: "miot-spec.org")
        }
        return data
    }

    private static func fileName(_ model: String) -> String {
        String(model.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }
}

/// A camera setting change or read that Mi Cloud refused.
public enum XiaomiCameraError: LocalizedError, Equatable {
    case offline
    case failed(code: Int)

    /// MIoT result codes: 0 done, 1 accepted (applied asynchronously).
    static func check(_ code: Int) throws {
        switch code {
        case 0, 1: return
        case -704042011, -704083036: throw XiaomiCameraError.offline
        default: throw XiaomiCameraError.failed(code: code)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .offline: return tr("Камера не ответила облаку Xiaomi — она выключена или без интернета", "The camera didn't answer the Xiaomi cloud: it is off or offline")
        case .failed(let code): return tr("Xiaomi не применил настройку (код \(code))", "Xiaomi didn't apply the setting (code \(code))")
        }
    }
}
