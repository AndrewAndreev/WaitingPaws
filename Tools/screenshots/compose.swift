// Composes App Store and showcase images from raw screenshots (see Tools/screenshots/make.sh).
//
//   swift compose.swift mac-store <out.png> <window.png> [sheet.png]
//       2880×1800 (Mac App Store): the window, scaled to fit, on the app's night background; a sheet goes on top
//       of the window like macOS shows it.
//   swift compose.swift showcase-ios <out.png> <title> <subtitle> <shot1.png> <shot2.png> <shot3.png>
//       3200×1800: three iPhones in device frames under a headline.
//   swift compose.swift showcase-mac <out.png> <title> <subtitle> <window.png> <iphone.png>
//       3200×1800: the Mac window with an iPhone in front of it under a headline.
import AppKit

// The app icon's "night" palette (Design/logos-v2/logos.js).
let ink = NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)
let plum = NSColor(srgbRed: 0x1E / 255, green: 0x14 / 255, blue: 0x1C / 255, alpha: 1)
let pink = NSColor(srgbRed: 0xFF / 255, green: 0xB8 / 255, blue: 0xCC / 255, alpha: 1)
let rose = NSColor(srgbRed: 0xE8 / 255, green: 0x79 / 255, blue: 0x9C / 255, alpha: 1)
let blush = NSColor(srgbRed: 0xFF / 255, green: 0xE6 / 255, blue: 0xEE / 255, alpha: 1)

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

/// Dark plum-to-black with a soft pink glow, like the app icon's night palette.
func background(_ cg: CGContext, _ size: CGSize, glow: CGPoint) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let linear = CGGradient(colorsSpace: space, colors: [plum.cgColor, ink.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(linear, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    let radial = CGGradient(colorsSpace: space,
                            colors: [rose.withAlphaComponent(0.28).cgColor, rose.withAlphaComponent(0).cgColor] as CFArray,
                            locations: [0, 1])!
    cg.drawRadialGradient(radial, startCenter: glow, startRadius: 0, endCenter: glow,
                          endRadius: max(size.width, size.height) * 0.55, options: [])
}

func shadowed(_ cg: CGContext, blur: CGFloat, offset: CGFloat, alpha: CGFloat = 0.65, _ draw: () -> Void) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: offset), blur: blur, color: NSColor.black.withAlphaComponent(alpha).cgColor)
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
    let titleText = text(title, size: 104, weight: .bold, color: blush, rounded: true)
    let subtitleText = text(subtitle, size: 50, weight: .medium, color: pink.withAlphaComponent(0.85))
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
            shadowed(cg, blur: 70, offset: 24, alpha: 0.55) {
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
        let rect = fit(window.size, in: CGRect(x: 170, y: 420, width: 2450, height: 1300))
        shadowed(cg, blur: 110, offset: 44) {
            window.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        _ = iPhone(cg, phone, origin: CGPoint(x: 2440, y: 640), height: 1080)
    }
default:
    fatalError("unknown command \(args[1])")
}
