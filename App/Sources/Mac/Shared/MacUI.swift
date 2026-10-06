#if os(macOS)
import AppKit
import SwiftUI
import WaitingPawsCore

/// Mac palette: the iOS pink stays the accent on dark surfaces, a deeper pink keeps contrast on light ones.
enum MacPalette {
    static let pink = Theme.accent
    static let pinkDeep = Color(red: 0.89, green: 0.33, blue: 0.53)
    /// Accent that follows the window appearance.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.00, green: 0.72, blue: 0.80, alpha: 1)
            : NSColor(red: 0.89, green: 0.33, blue: 0.53, alpha: 1)
    })
    static let blue = Theme.info
    static let orange = Color(red: 1.00, green: 0.70, blue: 0.30)
    static let green = Color(red: 0.42, green: 0.86, blue: 0.56)
    static let red = Color(red: 1.00, green: 0.33, blue: 0.33)
    /// Breaks on the timelines: the blue of «Вернулись», dimmed so the exits stay the main thing.
    static let breakFill = blue.opacity(0.4)
    /// A break of its own (not the common one).
    static let breakOwn = blue.opacity(0.55)

    /// Rounded digits — only for time readouts.
    static func digits(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// Keyboard shortcut hint ("Пробел", "⌫", "⌘R").
struct KeyCap: View {
    let key: String
    var prominent = false

    init(_ key: String, prominent: Bool = false) {
        self.key = key
        self.prominent = prominent
    }

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(prominent ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(prominent ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.quaternary)))
    }
}

/// Button label with a trailing shortcut hint.
struct ShortcutLabel: View {
    let title: String
    let symbol: String
    let key: String?
    var prominent = false
    var expand = false

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
            if expand { Spacer(minLength: 4) }
            if let key { KeyCap(key, prominent: prominent) }
        }
        .frame(maxWidth: expand ? .infinity : nil)
    }
}

/// "● REC 16:52".
struct RecBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(MacPalette.red).frame(width: 7, height: 7)
            Text("REC").font(.system(size: 10, weight: .bold)).foregroundStyle(MacPalette.red)
            Text(text).font(.system(size: 11.5, weight: .medium).monospacedDigit())
        }
    }
}

struct StatusDot: View {
    var color: Color = MacPalette.green
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

struct ThinProgress: View {
    var value: Double
    var tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(height, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

struct ProgressRing: View {
    var value: Double
    var tint: Color
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(1, max(0, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Small-caps section title with a trailing accessory (inspectors, panels).
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            trailing
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// Glass capsule button for HUDs (keeps its colour in non-key panels, ignores the window tint).
struct HUDButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var height: CGFloat = 32
    var circle = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(Capsule())
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .fixedSize()
            .foregroundStyle(tint == nil ? Color.primary : Color.black.opacity(0.85))
            .padding(.horizontal, circle ? 0 : 14)
            .frame(width: circle ? height : nil, height: height)
            .background {
                if let tint { shape.fill(tint) }
            }
            .glassEffect(tint == nil ? Glass.regular.interactive() : Glass.clear.interactive(), in: shape)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension String {
    /// "воскресенье, 4 октября" → "Воскресенье, 4 октября".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Formats in the app's language (day and month in its order), 24-hour regardless of the system 12/24-hour setting.
enum MacFormat {
    static let time: DateFormatter = make("HHmm")
    static let timeSeconds: DateFormatter = make("HHmmss")
    static let shortDate: DateFormatter = make("ddMMyyyy")
    static let dayMonth: DateFormatter = make("dMMMM")
    static let weekdayDay: DateFormatter = make("EEdMMM")
    static let fullDay: DateFormatter = make("EEEEdMMMM")
    static let month: DateFormatter = make("LLLLyyyy")

    private static func make(_ template: String) -> DateFormatter {
        CoreLanguage.current.dateFormatter(template)
    }
}
#endif
