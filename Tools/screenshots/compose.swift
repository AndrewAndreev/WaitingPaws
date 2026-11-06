// Composes App Store and showcase images from raw screenshots (see Tools/screenshots/make.sh).
//
//   swift compose.swift mac-store <out.png> <window.png> [sheet.png]
//       2880×1800 (Mac App Store): the window, scaled to fit, on the app's night background; a sheet goes on top
//       of the window like macOS shows it.
//   swift compose.swift showcase-ios <out.png> <title> <subtitle> <shot1.png> <shot2.png> <shot3.png>
//       3200×1800: three iPhones in device frames under a headline.
//   swift compose.swift showcase-mac <out.png> <title> <subtitle> <window.png> <iphone.png>
//       3200×1800: the Mac window with an iPhone in front of it under a headline.
//
// WP_BG=<name> picks the background palette (see `palettes` below); the default is `defaultPalette`.
import AppKit

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// A background: a vertical gradient with a soft glow behind the devices, and the headline colours that read on it.
struct Palette {
    var top: NSColor, bottom: NSColor
    var glow: NSColor, glowAlpha: CGFloat
    var title: NSColor, subtitle: NSColor
    /// Light backgrounds take a softer device shadow.
    var shadow: CGFloat = 0.65
}

let palettes: [String: Palette] = [
    // The app icon's "night" palette (Design/logos-v2/logos.js): plum to black with a rose glow. Used up to 1.7.15.
    "night": Palette(top: hex(0x1E141C), bottom: hex(0x0B0B0C), glow: hex(0xE8799C), glowAlpha: 0.28,
                     title: hex(0xFFE6EE), subtitle: hex(0xFFB8CC, 0.85)),
    // Keynote black: no colour cast, a faint warm spotlight, white and grey type.
    "black": Palette(top: hex(0x000000), bottom: hex(0x000000), glow: hex(0x8A7F86), glowAlpha: 0.22,
                     title: hex(0xF5F5F7), subtitle: hex(0xA1A1A6)),
    // Apple's light grey page: the dark screens stand out most. The default since 1.7.15 (Design/showcase-lab).
    "paper": Palette(top: hex(0xFBFBFD), bottom: hex(0xE8E8ED), glow: hex(0xFFFFFF), glowAlpha: 0.9,
                     title: hex(0x1D1D1F), subtitle: hex(0x6E6E73), shadow: 0.30),
    // Light pink from the app's accent, plum type.
    "blush": Palette(top: hex(0xFFF5F8), bottom: hex(0xFFDCE7), glow: hex(0xFFFFFF), glowAlpha: 0.85,
                     title: hex(0x2A1620), subtitle: hex(0x9A4462), shadow: 0.32),
    // Warm sand, brown type.
    "sand": Palette(top: hex(0xF8F2EA), bottom: hex(0xE9DAC6), glow: hex(0xFFFBF5), glowAlpha: 0.9,
                    title: hex(0x33251B), subtitle: hex(0x8A6A50), shadow: 0.32),
    // Sage, the complement of the pink accent.
    "sage": Palette(top: hex(0xEEF5F0), bottom: hex(0xCFE2D6), glow: hex(0xFFFFFF), glowAlpha: 0.8,
                    title: hex(0x15362B), subtitle: hex(0x3F6A58), shadow: 0.32),
    // The icon's "night sky": navy with pink type.
    "midnight": Palette(top: hex(0x1F2A52), bottom: hex(0x0A0E1F), glow: hex(0x6F8FE8), glowAlpha: 0.30,
                        title: hex(0xFFE6EE), subtitle: hex(0xFFB8CC, 0.9)),
    // The accent itself, saturated: pink to rose, dark plum type.
    "rose": Palette(top: hex(0xFFD3DF), bottom: hex(0xEE8DAB), glow: hex(0xFFF0F4), glowAlpha: 0.7,
                    title: hex(0x2A0F1A), subtitle: hex(0x5C2236), shadow: 0.38),
]
let defaultPalette = "paper"
let paletteName = ProcessInfo.processInfo.environment["WP_BG"] ?? defaultPalette
guard let palette = palettes[paletteName] else { fatalError("unknown WP_BG \(paletteName): \(palettes.keys.sorted())") }

func image(_ path: String) -> NSImage {
    guard let rep = NSImageRep(contentsOfFile: path) else { fatalError("cannot read \(path)") }
    let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    rep.size = image.size
    image.addRepresentation(rep)
    return image
}

/// A top-left-origin canvas of `width`×`height` pixels, written as PNG to `path`.
func render(_ path: String, _ width: Int, _ height: Int, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    cg.translateBy(x: 0, y: CGFloat(height))
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// The palette's vertical gradient with a soft glow around `glow`.
func background(_ cg: CGContext, _ size: CGSize, glow: CGPoint) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let linear = CGGradient(colorsSpace: space, colors: [palette.top.cgColor, palette.bottom.cgColor] as CFArray,
                            locations: [0, 1])!
    cg.drawLinearGradient(linear, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    let glowColor = palette.glow
    let radial = CGGradient(colorsSpace: space,
                            colors: [glowColor.withAlphaComponent(palette.glowAlpha).cgColor,
                                     glowColor.withAlphaComponent(0).cgColor] as CFArray,
                            locations: [0, 1])!
    cg.drawRadialGradient(radial, startCenter: glow, startRadius: 0, endCenter: glow,
                          endRadius: max(size.width, size.height) * 0.55, options: [])
}

/// Draws with a drop shadow; `alpha` is relative to the palette's shadow strength (1 = the palette's own).
func shadowed(_ cg: CGContext, blur: CGFloat, offset: CGFloat, alpha: CGFloat = 1, _ draw: () -> Void) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: offset), blur: blur,
                 color: NSColor.black.withAlphaComponent(palette.shadow * alpha).cgColor)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    draw()
    cg.endTransparencyLayer()
    cg.restoreGState()
}

func fit(_ size: NSSize, in box: CGRect) -> CGRect {
    let scale = min(box.width / size.width, box.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, rounded: Bool = false) -> NSAttributedString {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: descriptor, size: size) ?? font }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                                                           .kern: -size * 0.01])
}

/// Headline and subtitle centred at the top.
func headline(_ title: String, _ subtitle: String, width: CGFloat, top: CGFloat) {
    let titleText = text(title, size: 104, weight: .bold, color: palette.title, rounded: true)
    let subtitleText = text(subtitle, size: 50, weight: .medium, color: palette.subtitle)
    titleText.draw(in: CGRect(x: 160, y: top, width: width - 320, height: 140))
    subtitleText.draw(in: CGRect(x: 240, y: top + 150, width: width - 480, height: 140))
}

/// An iPhone 17 Pro Max-like frame around a 1320×2868 screenshot, fitting `height`.
func iPhone(_ cg: CGContext, _ shot: NSImage, origin: CGPoint, height: CGFloat) -> CGRect {
    let screenHeight = height * 0.965
    let screenWidth = screenHeight * shot.size.width / shot.size.height
    let bezel = (height - screenHeight) / 2
    let frame = CGRect(x: origin.x, y: origin.y, width: screenWidth + bezel * 2, height: height)
    let radius = frame.width * 0.145
    shadowed(cg, blur: 90, offset: 40) {
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1).setFill()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
    }
    NSColor(srgbRed: 0.30, green: 0.29, blue: 0.31, alpha: 1).setStroke()
    let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 3), xRadius: radius - 3, yRadius: radius - 3)
    edge.lineWidth = 6
    edge.stroke()
    let screen = frame.insetBy(dx: bezel, dy: bezel)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screen, xRadius: radius - bezel, yRadius: radius - bezel).addClip()
    shot.draw(in: screen, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    // The Dynamic Island (simulator screenshots leave it out).
    let island = CGRect(x: screen.midX - screen.width * 0.155, y: screen.minY + screen.height * 0.0125,
                        width: screen.width * 0.31, height: screen.height * 0.0305)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: island, xRadius: island.height / 2, yRadius: island.height / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    return frame
}

let args = CommandLine.arguments
guard args.count > 2 else { fatalError("usage: see the header of compose.swift") }

switch args[1] {
case "mac-store":
    let window = image(args[3])
    let sheet = args.count > 4 ? image(args[4]) : nil
    render(args[2], 2880, 1800) { cg in
        background(cg, CGSize(width: 2880, height: 1800), glow: CGPoint(x: 600, y: 200))
        let rect = fit(window.size, in: CGRect(x: 110, y: 100, width: 2660, height: 1600))
        let scale = rect.width / window.size.width
        shadowed(cg, blur: 100, offset: 40) {
            window.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let sheet {
            let size = CGSize(width: sheet.size.width * scale, height: sheet.size.height * scale)
            let sheetRect = CGRect(x: rect.midX - size.width / 2, y: rect.minY + 104 * scale, width: size.width, height: size.height)
            shadowed(cg, blur: 70, offset: 24, alpha: 0.85) {
                sheet.draw(in: sheetRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
case "showcase-ios":
    let shots = args[5...7].map(image)
    render(args[2], 3200, 1800) { cg in
        background(cg, CGSize(width: 3200, height: 1800), glow: CGPoint(x: 1600, y: 1100))
        headline(args[3], args[4], width: 3200, top: 90)
        let height: CGFloat = 1250
        let width = height * 0.965 * 1320 / 2868 + height * 0.035
        let gap: CGFloat = 160
        let left = 1600 - width * 1.5 - gap
        for (index, shot) in shots.enumerated() {
            // The middle phone a little higher than the two beside it; all of them inside the canvas.
            let lift: CGFloat = index == 1 ? 0 : 60
            _ = iPhone(cg, shot, origin: CGPoint(x: left + CGFloat(index) * (width + gap), y: 420 + lift), height: height)
        }
    }
case "showcase-mac":
    let window = image(args[5])
    let phone = image(args[6])
    render(args[2], 3200, 1800) { cg in
        background(cg, CGSize(width: 3200, height: 1800), glow: CGPoint(x: 1100, y: 1000))
        headline(args[3], args[4], width: 3200, top: 80)
        // The iPhone overlaps only the window's edge, so the panel's buttons and text stay in sight.
        let rect = fit(window.size, in: CGRect(x: 195, y: 420, width: 2330, height: 1300))
        shadowed(cg, blur: 110, offset: 44) {
            window.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        _ = iPhone(cg, phone, origin: CGPoint(x: rect.maxX - 40, y: 640), height: 1080)
    }
default:
    fatalError("unknown command \(args[1])")
}
