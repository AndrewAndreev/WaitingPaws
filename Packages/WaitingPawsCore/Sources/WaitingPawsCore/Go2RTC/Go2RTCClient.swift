import Foundation

/// Connection parameters of a go2rtc server.
public struct Go2RTCServer: Codable, Equatable, Hashable, Sendable {
    public var baseURL: URL
    public var username: String
    public var password: String

    public init(baseURL: URL, username: String = "", password: String = "") {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    public var hasCredentials: Bool { !username.isEmpty }

    /// `Authorization: Basic …` value, when credentials are configured.
    public var authorizationHeader: String? {
        guard hasCredentials else { return nil }
        let raw = "\(username):\(password)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    /// Base URL with the credentials embedded (`http://user:pass@host:1984/`) for the web player.
    public var urlWithCredentials: URL {
        guard hasCredentials, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        components.user = username
        components.password = password
        return components.url ?? baseURL
    }

    public static func parse(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        if !trimmed.hasSuffix("/") { trimmed += "/" }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }
}

public struct Go2RTCStream: Identifiable, Equatable, Hashable {
    public var name: String
    public var sources: [String]
    public var id: String { name }

    public init(name: String, sources: [String]) {
        self.name = name
        self.sources = sources
    }

    public var isXiaomi: Bool { sources.contains { $0.hasPrefix("xiaomi://") } }
}

/// A discoverable source returned by go2rtc (`/api/xiaomi?id=…`).
public struct Go2RTCSource: Codable, Identifiable, Equatable, Hashable {
    public var name: String
    public var info: String?
    public var url: String
    public var id: String { url }

    public init(name: String, info: String? = nil, url: String) {
        self.name = name
        self.info = info
        self.url = url
    }
}

public enum XiaomiLoginStep: Equatable {
    case success
    /// A captcha image (PNG/JPEG bytes) must be solved and sent back via `xiaomiSubmitCaptcha`.
    case captcha(Data)
    /// A verification code was sent to the masked phone/email; send it back via `xiaomiSubmitVerify`.
    case verify(phone: String?, email: String?)
}

public enum XiaomiRegion: String, CaseIterable, Codable, Identifiable {
    case cn, ru, de, us, sg, i2
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cn: return tr("Китай (по умолчанию)", "China (default)")
        case .ru: return tr("Россия", "Russia")
        case .de: return tr("Европа (de)", "Europe (de)")
        case .us: return tr("США", "United States")
        case .sg: return tr("Сингапур", "Singapore")
        case .i2: return tr("Индия", "India")
        }
    }

    /// The Mi Home server region most likely for this device's region (the user can change it).
    public static var suggested: XiaomiRegion {
        guard let region = Locale.current.region?.identifier else { return CoreLanguage.current == .ru ? .ru : .de }
        switch region {
        case "RU", "BY", "KZ", "KG", "AM", "UZ", "TJ": return .ru
        case "CN", "HK", "MO", "TW": return .cn
        case "US", "CA", "MX", "BR", "AR", "CL", "CO", "PE": return .us
        case "IN": return .i2
        case "SG", "MY", "ID", "TH", "VN", "PH", "AU", "NZ", "JP", "KR": return .sg
        default: return .de
        }
    }
}

public enum Go2RTCError: LocalizedError, Equatable {
    case invalidURL
    case http(status: Int, message: String)
    case decoding(String)
    case noSources

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return tr("Некорректный адрес сервера", "Invalid server address")
        case .http(let status, let message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? tr("Сервер ответил HTTP \(status)", "The server answered HTTP \(status)") : "HTTP \(status): \(text)"
        case .decoding(let what): return tr("Не удалось разобрать ответ сервера (\(what))", "Couldn't read the server's response (\(what))")
        case .noSources: return tr("Камеры не найдены", "No cameras found")
        }
    }
}

/// Thin async client for the go2rtc HTTP API.
public final class Go2RTCClient: Sendable {
    public let server: Go2RTCServer
    private let session: URLSession

    public init(server: Go2RTCServer, session: URLSession? = nil) {
        self.server = server
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - URLs

    public func url(path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: server.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    /// WebSocket endpoint used by go2rtc's `video-rtc.js` player.
    public func playerSocketURL(stream: String) -> URL {
        var components = URLComponents(url: server.urlWithCredentials.appendingPathComponent("api/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "src", value: stream)]
        return components.url!
    }

    public func playerScriptURL() -> URL {
        server.urlWithCredentials.appendingPathComponent("video-rtc.js")
    }

    /// Progressive MP4 stream suitable for saving straight to a file.
    /// The camera's sound is taken as is: go2rtc cannot transcode without ffmpeg, but it stores
    /// Opus untouched and turns PCMA/PCMU into FLAC. The app converts that audio to AAC after
    /// recording (Photos and most players only accept AAC in MP4).
    public func mp4URL(stream: String) -> URL {
        url(path: "api/stream.mp4", query: ["src": stream, "video": "h264,h265", "audio": "aac,opus,pcma,pcmu"])
    }

    public func hlsURL(stream: String) -> URL {
        url(path: "api/stream.m3u8", query: ["src": stream])
    }

    public func snapshotURL(stream: String) -> URL {
        url(path: "api/frame.jpeg", query: ["src": stream])
    }

    // MARK: - Server

    /// Returns the server version (or an empty string for very old builds). Throws when unreachable.
    public func version() async throws -> String {
        let data = try await request("GET", path: "api")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["version"] as? String ?? ""
    }

    // MARK: - Streams

    public func streams() async throws -> [Go2RTCStream] {
        let data = try await request("GET", path: "api/streams")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Go2RTCError.decoding("streams")
        }
        var result: [Go2RTCStream] = []
        for (name, value) in object {
            var sources: [String] = []
            if let dictionary = value as? [String: Any],
               let producers = dictionary["producers"] as? [[String: Any]] {
                sources = producers.compactMap { $0["url"] as? String }
            }
            result.append(Go2RTCStream(name: name, sources: sources))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func addStream(name: String, source: String) async throws {
        _ = try await request("PUT", path: "api/streams", query: ["name": name, "src": source])
    }

    public func deleteStream(name: String) async throws {
        _ = try await request("DELETE", path: "api/streams", query: ["src": name])
    }

    /// Sources of `stream` as written in the server's config file (`GET /api/config`).
    /// Needed while the stream is live: `/api/streams` then describes the running connection
    /// instead of the configured source URL.
    public func configuredSources(stream: String) async throws -> [String] {
        let data = try await request("GET", path: "api/config")
        return Self.streamSources(inConfig: String(decoding: data, as: UTF8.self), stream: stream)
    }

    /// Reads one stream from the `streams:` section of a go2rtc YAML config. Handles the forms
    /// go2rtc itself writes (`name: url`, a block list under `name:`) and a flow list `[a, b]`.
    /// Sources of several streams from one read of the config file.
    public func configuredSources(streams names: [String]) async throws -> [String: [String]] {
        let yaml = String(decoding: try await request("GET", path: "api/config"), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: names.map { ($0, Self.streamSources(inConfig: yaml, stream: $0)) })
    }

    static func streamSources(inConfig yaml: String, stream: String) -> [String] {
        func unquote<S: StringProtocol>(_ text: S) -> String {
            var value = text.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }

        var inStreams = false
        var currentKey: String?
        var sources: [String] = []
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only whole-line comments: `#` is legal inside source URLs (`ffmpeg:…#video=h264`).
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inStreams = trimmed == "streams:"
                currentKey = nil
                continue
            }
            guard inStreams else { continue }
            if trimmed == "-" || trimmed.hasPrefix("- ") {
                let item = unquote(trimmed.dropFirst())
                if currentKey == stream, !item.isEmpty { sources.append(item) }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = unquote(trimmed[..<colon])
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            currentKey = key
            guard key == stream, !value.isEmpty else { continue }
            if value.hasPrefix("["), value.hasSuffix("]") {
                sources += value.dropFirst().dropLast().split(separator: ",").map { unquote($0) }.filter { !$0.isEmpty }
            } else {
                sources.append(unquote(value))
            }
        }
        return sources
    }

    // MARK: - Xiaomi

    /// Xiaomi account IDs already authorised on the server.
    public func xiaomiAccounts() async throws -> [String] {
        let data = try await request("GET", path: "api/xiaomi")
        guard let list = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw Go2RTCError.decoding("xiaomi accounts")
        }
        return list.sorted()
    }

    public func xiaomiLogin(username: String, password: String) async throws -> XiaomiLoginStep {
        try await xiaomiAuth(form: ["username": username, "password": password])
    }

    public func xiaomiSubmitCaptcha(_ code: String) async throws -> XiaomiLoginStep {
        try await xiaomiAuth(form: ["captcha": code])
    }

    public func xiaomiSubmitVerify(_ code: String) async throws -> XiaomiLoginStep {
        try await xiaomiAuth(form: ["verify": code])
    }

    /// Forgets a Mi Home account: go2rtc drops its token from memory and from its config
    /// (`POST /api/xiaomi/logout`, a Waiting Paws addition — another go2rtc answers 404).
    public func xiaomiLogout(accountID: String) async throws {
        var request = URLRequest(url: url(path: "api/xiaomi/logout"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(["id": accountID]).data(using: .utf8)
        applyAuth(&request)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Go2RTCError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
    }

    /// Cameras of the given account, as ready-to-use `xiaomi://` sources.
    public func xiaomiCameras(accountID: String, region: XiaomiRegion) async throws -> [Go2RTCSource] {
        let data: Data
        do {
            data = try await request("GET", path: "api/xiaomi", query: ["id": accountID, "region": region.rawValue])
        } catch Go2RTCError.http(let status, _) where status == 404 {
            throw Go2RTCError.noSources
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = object["sources"] as? [[String: Any]] else {
            throw Go2RTCError.decoding("xiaomi sources")
        }
        let cameras = sources.compactMap { item -> Go2RTCSource? in
            guard let url = item["url"] as? String else { return nil }
            return Go2RTCSource(name: item["name"] as? String ?? url, info: item["info"] as? String, url: url)
        }
        if cameras.isEmpty { throw Go2RTCError.noSources }
        return cameras
    }

    // MARK: - Xiaomi camera settings

    /// Current values of camera settings, through the app's go2rtc (`POST /api/xiaomi/miot`, a Waiting Paws
    /// addition — another go2rtc answers 404). Properties the camera did not report are left out;
    /// when it reported none, the camera's error is thrown.
    public func xiaomiProperties(source: String, _ ids: [MiotPropertyID]) async throws -> [MiotPropertyID: MiotValue] {
        guard !ids.isEmpty else { return [:] }
        let params = ids.map { ["siid": $0.siid, "piid": $0.piid] }
        let results = try await miot(source: source, method: "get", params: params)
        var values: [MiotPropertyID: MiotValue] = [:]
        var firstError: Error?
        for result in results {
            do {
                try XiaomiCameraError.check(result.code)
                if let value = result.value { values[MiotPropertyID(siid: result.siid, piid: result.piid)] = value }
            } catch {
                firstError = firstError ?? error
            }
        }
        if values.isEmpty, let firstError { throw firstError }
        return values
    }

    /// Changes one camera setting (night mode, image flip…).
    public func setXiaomiProperty(source: String, _ id: MiotPropertyID, to value: MiotValue) async throws {
        let results = try await miot(source: source, method: "set",
                                     params: [["siid": id.siid, "piid": id.piid, "value": value.jsonObject]])
        guard let result = results.first else { throw Go2RTCError.decoding("xiaomi miot") }
        try XiaomiCameraError.check(result.code)
    }

    private struct MiotResult: Decodable {
        var siid: Int
        var piid: Int
        var code: Int
        var value: MiotValue?

        enum CodingKeys: String, CodingKey { case siid, piid, code, value }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            siid = try container.decode(Int.self, forKey: .siid)
            piid = try container.decode(Int.self, forKey: .piid)
            code = (try? container.decode(Int.self, forKey: .code)) ?? 0
            // String properties (time ranges…) are not settings the app shows.
            value = try? container.decode(MiotValue.self, forKey: .value)
        }
    }

    private func miot(source: String, method: String, params: [[String: Any]]) async throws -> [MiotResult] {
        let json = try JSONSerialization.data(withJSONObject: params)
        var request = URLRequest(url: url(path: "api/xiaomi/miot"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(["src": source, "method": method, "params": String(decoding: json, as: UTF8.self)])
            .data(using: .utf8)
        applyAuth(&request)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Go2RTCError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode([MiotResult].self, from: data)
        } catch {
            throw Go2RTCError.decoding("xiaomi miot")
        }
    }

    private func xiaomiAuth(form: [String: String]) async throws -> XiaomiLoginStep {
        var request = URLRequest(url: url(path: "api/xiaomi"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)
        applyAuth(&request)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return .success
        case 401:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Go2RTCError.http(status: status, message: String(decoding: data, as: UTF8.self))
            }
            if let captcha = object["captcha"] as? String, let image = Data(base64Encoded: captcha) {
                return .captcha(image)
            }
            let phone = object["verify_phone"] as? String
            let email = object["verify_email"] as? String
            if phone != nil || email != nil {
                return .verify(phone: phone?.isEmpty == false ? phone : nil, email: email?.isEmpty == false ? email : nil)
            }
            throw Go2RTCError.http(status: status, message: tr("Xiaomi отклонил вход: проверьте логин и пароль",
                                                               "Xiaomi rejected the sign-in: check the login and password"))
        default:
            throw Go2RTCError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Plumbing

    private func request(_ method: String, path: String, query: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url(path: path, query: query))
        request.httpMethod = method
        applyAuth(&request)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Go2RTCError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func applyAuth(_ request: inout URLRequest) {
        if let header = server.authorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    /// Stream name for a camera: "Гостиная" → "gostinaya" style ASCII slug.
    public static func streamName(for cameraName: String) -> String {
        let latin = cameraName.applyingTransform(.toLatin, reverse: false) ?? cameraName
        let ascii = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        var slug = ""
        var lastWasDash = false
        for scalar in ascii.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug += "-"
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "camera" : slug
    }
}
