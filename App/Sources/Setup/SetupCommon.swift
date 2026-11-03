import SwiftUI
import WaitingPawsCore
#if os(macOS)
import AppKit
/// An image on either platform (stills of cameras and streams).
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

// Setup pieces shared by the Mac welcome window / Settings and the iPhone camera picker: whether go2rtc can be
// asked, readable texts about cameras and regions, DEBUG demo data for UI checks.

// MARK: - go2rtc state

extension AppModel {
    /// Whether the go2rtc API may be queried right now. The `--ui-preview` instance never talks to a server:
    /// the embedded port belongs to the user's own running copy of the app.
    var setupServerReady: Bool {
        if AppModel.isUIPreview { return false }
        switch settings.connectionMode {
        case .embedded: return embedded.status.isRunning
        case .external: return settings.server != nil
        }
    }

    /// Same, but DEBUG demo data counts as a running server (screens of signed-in states without a camera).
    var setupServerReadyOrDemo: Bool { setupServerReady || SetupDemo.isOn }

    /// Restarts the embedded go2rtc after a failure (with the iPhone link password, as at launch).
    func setupRetryEmbedded() {
        startEmbeddedIfNeeded()
    }
}


enum SetupText {
    /// "Версия 1.6.10 (9a8e796)" (the version and its commit, see AppInfo), "Версия dev" for a build from Xcode.
    static var appVersion: String {
        guard let release = AppInfo.release else { return String(localized: "Версия") + " dev" }
        return String(localized: "Версия \(release.version) (\(release.commit))")
    }

    /// "1920×1080". H.265 streams report the coded height (1088 for 1080p): within a macroblock of 16:9 it is rounded.
    static func pixels(_ size: CGSize) -> String {
        let width = Int(size.width.rounded())
        var height = Int(size.height.rounded())
        if width % 16 == 0, abs(height - width * 9 / 16) <= 8 { height = width * 9 / 16 }
        return "\(width)×\(height)"
    }

    /// Mi account regions in the order people in Russia look for them.
    static let regions: [XiaomiRegion] = [.ru, .de, .cn, .us, .sg, .i2]

    static func regionTitle(_ region: XiaomiRegion) -> String {
        switch region {
        case .ru: return String(localized: "Россия")
        case .de: return String(localized: "Европа")
        case .cn: return String(localized: "Китай")
        case .us: return String(localized: "США")
        case .sg: return String(localized: "Сингапур")
        case .i2: return String(localized: "Индия")
        }
    }

    /// "chuangmi.camera.039a01" → «Камера Xiaomi»: the device type and the maker from the Mi Home model id.
    /// Only makers that are certain; anything else is «Камера Mi Home». The raw id is for tooltips only.
    static func cameraKind(model: String?) -> String {
        let parts = (model ?? "").lowercased().split(separator: ".").map(String.init)
        let peephole = parts.count > 1 && parts[1] == "cateye"
        guard let vendor = parts.first.flatMap({ cameraVendors[$0] }) else {
            return peephole ? String(localized: "Видеоглазок Mi Home") : String(localized: "Камера Mi Home")
        }
        return peephole ? String(localized: "Видеоглазок \(vendor)") : String(localized: "Камера \(vendor)")
    }

    private static let cameraVendors = [
        "xiaomi": "Xiaomi", "mijia": "Xiaomi", "chuangmi": "Xiaomi", "isa": "Xiaomi",
        "xiaovv": "Xiaovv", "lumi": "Aqara",
    ]

    /// "rtsp://192.168.1.20:554/live" → "RTSP"; Mi Home sources → "Mi Home".
    static func sourceBadge(_ source: String?) -> String? {
        guard let source, let scheme = source.split(separator: ":").first.map(String.init), !scheme.isEmpty,
              source.contains(":") else { return nil }
        switch scheme.lowercased() {
        case "xiaomi": return "Mi Home"
        case "rtsp", "rtsps", "rtspx": return "RTSP"
        case "onvif": return "ONVIF"
        case "http", "https": return "HTTP"
        case "ffmpeg": return "FFmpeg"
        case "exec": return "exec"
        case "homekit": return "HomeKit"
        default: return scheme.uppercased()
        }
    }
}


// MARK: - DEBUG demo data

/// DEBUG launch arguments for UI checks of the setup screens without a server or a Xiaomi account:
/// `--demo-cameras` fills the lists with a signed-in Mi Home account, cameras and an RTSP stream
/// (nothing is sent anywhere and nothing is saved); with `--demo-catalog no-xiaomi` there is no Xiaomi account
/// and only the RTSP stream (also the Settings camera), with `--demo-catalog empty` neither.
/// `--demo-welcome-sheet signin|captcha|verify|server|streams|picker` and `--demo-settings-sheet signin|picker`
/// open a sheet; `--demo-pane <pane>` selects a Settings pane.
enum SetupDemo {
    static var isOn: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--demo-cameras")
        #else
        return false
        #endif
    }

    static func argument(after flag: String) -> String? {
        #if DEBUG
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
        #else
        return nil
        #endif
    }

    /// `--demo-appearance light|dark`: check both appearances without touching the system setting.
    static var colorScheme: ColorScheme? {
        switch argument(after: "--demo-appearance") {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    static let go2rtcVersion = "1.9.14"
    static let serverHost = "192.168.1.10:1984"
    static let login = "tanya.k@example.com"
    static let accountID = "6218440137"
    static let maskedPhone = "+7 *** ***-**-42"
    static let cameraStream = "prihozhaya"
    static var cameraName: String { CoreLanguage.current == .ru ? "Прихожая" : "Hallway" }
    static let cameraModel = "chuangmi.camera.069a01"
    static let cameraSize = CGSize(width: 2304, height: 1296)
    static let rtspStream = "testcam"
    static let rtspSize = CGSize(width: 1280, height: 720)

    /// `--demo-catalog no-xiaomi|empty`: go2rtc without a Xiaomi account (and without streams).
    static var hasXiaomi: Bool { argument(after: "--demo-catalog") == nil }
    static var hasStreams: Bool { argument(after: "--demo-catalog") != "empty" }

    #if DEBUG
    /// Demo names in the app's language (screenshots for both App Store languages).
    private static func tr(_ ru: String, _ en: String) -> String { CoreLanguage.current == .ru ? ru : en }
    private static let kitchenDID = "1093845577"
    private static let nurseryDID = "1093845604"

    static var accounts: [SetupCameraCatalog.Account] {
        guard hasXiaomi else { return [] }
        let region = XiaomiRegion.ru
        func camera(_ name: String, did: String, model: String, ip: String, stream: String?) -> SetupCameraCatalog.Camera {
            let source = Go2RTCSource(name: name, info: "ip: \(ip), mac: 64:90:C1:00:00:00",
                                      url: "xiaomi://\(accountID):ru@\(ip)?did=\(did)&model=\(model)")
            return .init(source: source, accountID: accountID, region: region, streamName: stream)
        }
        return [SetupCameraCatalog.Account(id: accountID, region: region, cameras: [
            camera(cameraName, did: "1093845561", model: cameraModel, ip: "192.168.1.34", stream: cameraStream),
            // Not a stream yet: a preview that came through, one still on its way, one offline (no address).
            camera(tr("Кухня", "Kitchen"), did: kitchenDID, model: "chuangmi.camera.039a01", ip: "192.168.1.35", stream: nil),
            camera(tr("Балкон", "Balcony"), did: "1093845590", model: "isa.camera.hlc7", ip: "192.168.1.36", stream: "balkon"),
            camera(tr("Детская", "Nursery"), did: nurseryDID, model: "chuangmi.camera.ipc019", ip: "192.168.1.37", stream: nil),
            camera(tr("Дача", "Cottage"), did: "1093845618", model: "mijia.camera.v3", ip: "", stream: nil),
        ], error: nil)]
    }

    static var streams: [Go2RTCStream] {
        guard hasStreams else { return [] }
        let rtsp = Go2RTCStream(name: rtspStream, sources: ["rtsp://192.168.1.20:554/live"])
        guard let cameras = accounts.first?.cameras else { return [rtsp] }
        return [
            Go2RTCStream(name: cameraStream, sources: [cameras[0].source.url]),
            Go2RTCStream(name: "balkon", sources: [cameras[2].source.url]),
            rtsp,
        ]
    }

    /// Stills: the `--demo-camera` picture for the hall (and, mirrored, the kitchen preview), colour bars for
    /// the RTSP stream, a preview on its way for the nursery, nothing (offline) for the balcony and the dacha.
    @MainActor
    static func still(for source: SetupStillSource) -> SetupStillStore.State {
        switch source {
        case .stream(cameraStream):
            guard let image = DemoData.cameraImage else { return .failed }
            return .loaded(image, cameraSize)
        case .stream(rtspStream):
            return .loaded(testPattern, rtspSize)
        case .camera(let camera) where camera.deviceID == kitchenDID && camera.host != nil:
            guard let image = kitchenPreview else { return .failed }
            return .loaded(image, CGSize(width: 1920, height: 1080))
        case .camera(let camera) where camera.deviceID == nurseryDID:
            return .loading
        default:
            return .failed
        }
    }

    @MainActor
    static func still(for stream: String) -> SetupStillStore.State { still(for: .stream(stream)) }

    /// The demo camera picture mirrored and closer: looks like another room.
    @MainActor
    private static let kitchenPreview: PlatformImage? = {
        guard let image = DemoData.cameraImage else { return nil }
        #if os(macOS)
        let size = NSSize(width: 960, height: 540)
        return NSImage(size: size, flipped: false) { rect in
            let flip = NSAffineTransform()
            flip.translateX(by: rect.width, yBy: 0)
            flip.scaleX(by: -1, yBy: 1)
            flip.concat()
            image.draw(in: rect.insetBy(dx: -rect.width * 0.4, dy: -rect.height * 0.4).offsetBy(dx: rect.width * 0.3, dy: rect.height * 0.12),
                       from: .zero, operation: .copy, fraction: 1)
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.6, alpha: 0.12).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        #else
        let size = CGSize(width: 960, height: 540)
        return UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size)
            context.cgContext.translateBy(x: rect.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            image.draw(in: rect.insetBy(dx: -rect.width * 0.4, dy: -rect.height * 0.4).offsetBy(dx: rect.width * 0.3, dy: -rect.height * 0.12))
            UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 0.12).setFill()
            context.fill(rect, blendMode: .sourceAtop)
        }
        #endif
    }()

    @MainActor
    static let testPattern: PlatformImage = {
        let renderer = ImageRenderer(content: SetupDemoTestPattern().frame(width: 320, height: 180))
        renderer.scale = 2
        #if os(macOS)
        return renderer.nsImage ?? NSImage()
        #else
        return renderer.uiImage ?? UIImage()
        #endif
    }()

    /// A Xiaomi-style captcha drawn in code, as PNG bytes (goes through the same path as the real picture).
    @MainActor
    static var captchaPNG: Data {
        let renderer = ImageRenderer(content: SetupDemoCaptcha().frame(width: 210, height: 64))
        renderer.scale = 2
        #if os(macOS)
        guard let cgImage = renderer.cgImage else { return Data() }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) ?? Data()
        #else
        return renderer.uiImage?.pngData() ?? Data()
        #endif
    }
    #endif
}

#if DEBUG
/// Deterministic generator, so the drawn captcha is the same in every screenshot.
private struct SetupSeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Xiaomi-style captcha: pale noisy background, warped coloured glyphs, two interference curves.
private struct SetupDemoCaptcha: View {
    var text = "x7Kp4"
    var seed: UInt64 = 11

    var body: some View {
        Canvas { context, size in
            var rng = SetupSeededRandom(seed)
            func r(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &rng) }

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.96, green: 0.95, blue: 0.90), Color(red: 0.88, green: 0.93, blue: 0.95)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            for i in stride(from: -size.height, to: size.width, by: 9) {
                var hatch = Path()
                hatch.move(to: CGPoint(x: i, y: size.height))
                hatch.addLine(to: CGPoint(x: i + size.height * 0.8, y: 0))
                context.stroke(hatch, with: .color(.black.opacity(0.045)), lineWidth: 1)
            }
            let speckle: [Color] = [.black, Color(red: 0.2, green: 0.3, blue: 0.7), Color(red: 0.6, green: 0.2, blue: 0.2)]
            for _ in 0..<420 {
                let d = r(0.6...1.8)
                let dot = CGRect(x: r(0...Double(size.width)), y: r(0...Double(size.height)), width: d, height: d)
                context.fill(Path(ellipseIn: dot), with: .color(speckle[Int(r(0...2.99))].opacity(r(0.12...0.4))))
            }
            for _ in 0..<4 {
                var arc = Path()
                arc.move(to: CGPoint(x: r(-10...30), y: r(0...Double(size.height))))
                arc.addCurve(to: CGPoint(x: size.width + 10, y: r(0...Double(size.height))),
                             control1: CGPoint(x: size.width * 0.3, y: r(-20...Double(size.height) + 20)),
                             control2: CGPoint(x: size.width * 0.7, y: r(-20...Double(size.height) + 20)))
                context.stroke(arc, with: .color(Color(hue: r(0...1), saturation: 0.5, brightness: 0.55).opacity(0.35)),
                               lineWidth: r(0.8...1.6))
            }
            let designs: [Font.Design] = [.serif, .rounded, .default, .monospaced, .serif]
            let inks: [Color] = [
                Color(red: 0.12, green: 0.20, blue: 0.55), Color(red: 0.45, green: 0.10, blue: 0.18),
                Color(red: 0.10, green: 0.38, blue: 0.22), Color(red: 0.35, green: 0.16, blue: 0.50),
                Color(red: 0.50, green: 0.30, blue: 0.08),
            ]
            let chars = Array(text)
            let step = size.width / CGFloat(chars.count + 1)
            for (i, ch) in chars.enumerated() {
                let fontSize = r(30...40) * Double(size.height) / 64
                let font = Font.system(size: fontSize, weight: [.heavy, .bold, .black][Int(r(0...2.99))],
                                       design: designs[i % designs.count])
                let ink = inks[(i * 3 + 1) % inks.count]
                let center = CGPoint(x: step * (CGFloat(i) + 1) + r(-5...5), y: size.height / 2 + r(-7...7))
                let angle = Angle.degrees(r(-24...24))
                let skew = CGAffineTransform(a: 1, b: r(-0.12...0.12), c: r(-0.45...0.45), d: 1, tx: 0, ty: 0)
                let scale = CGSize(width: r(0.8...1.15), height: r(0.95...1.3))

                var ghost = context
                ghost.translateBy(x: center.x + 2.5, y: center.y + 1.5)
                ghost.rotate(by: angle + .degrees(8))
                ghost.concatenate(skew)
                ghost.draw(Text(String(ch)).font(font).foregroundStyle(ink.opacity(0.22)), at: .zero)

                var glyph = context
                glyph.translateBy(x: center.x, y: center.y)
                glyph.rotate(by: angle)
                glyph.scaleBy(x: scale.width, y: scale.height)
                glyph.concatenate(skew)
                glyph.draw(Text(String(ch)).font(font).foregroundStyle(ink), at: .zero)
            }
            for (k, width) in [2.2, 1.2].enumerated() {
                var wave = Path()
                let phase = r(0...6.28)
                let amplitude = Double(size.height) * r(0.12...0.2)
                let baseline = Double(size.height) * (k == 0 ? 0.55 : 0.4)
                wave.move(to: CGPoint(x: 0, y: baseline + sin(phase) * amplitude))
                for x in stride(from: 0.0, through: Double(size.width), by: 3) {
                    wave.addLine(to: CGPoint(x: x, y: baseline + sin(phase + x / Double(size.width) * 2 * .pi * 1.3) * amplitude))
                }
                context.stroke(wave, with: .color(inks[k == 0 ? 0 : 1].opacity(0.85)), lineWidth: width)
            }
        }
    }
}

/// SMPTE colour bars: what go2rtc shows for an ffmpeg test source.
private struct SetupDemoTestPattern: View {
    private let top: [Color] = [
        Color(white: 0.75), Color(red: 0.75, green: 0.75, blue: 0), Color(red: 0, green: 0.75, blue: 0.75),
        Color(red: 0, green: 0.75, blue: 0), Color(red: 0.75, green: 0, blue: 0.75), Color(red: 0.75, green: 0, blue: 0),
        Color(red: 0, green: 0, blue: 0.75),
    ]
    private let middle: [Color] = [
        Color(red: 0, green: 0, blue: 0.75), Color(white: 0.07), Color(red: 0.75, green: 0, blue: 0.75), Color(white: 0.07),
        Color(red: 0, green: 0.75, blue: 0.75), Color(white: 0.07), Color(white: 0.75),
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 0) { ForEach(top.indices, id: \.self) { top[$0] } }
                    .frame(height: geo.size.height * 0.67)
                HStack(spacing: 0) { ForEach(middle.indices, id: \.self) { middle[$0] } }
                    .frame(height: geo.size.height * 0.08)
                HStack(spacing: 0) {
                    Color(red: 0, green: 0.13, blue: 0.3).frame(width: geo.size.width * 0.18)
                    Color.white.frame(width: geo.size.width * 0.18)
                    Color(red: 0.2, green: 0, blue: 0.42).frame(width: geo.size.width * 0.18)
                    Color(white: 0.07)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("18:29:13")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .padding(6)
        }
    }
}
#endif
