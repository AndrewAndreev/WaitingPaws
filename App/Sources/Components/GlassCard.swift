import SwiftUI

/// Dark rounded panel. Deliberately opaque: blur over live video is expensive on iPhone.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Small rounded label used for status (camera name, "выход 3 из 7", REC).
struct Pill: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color = .white
    /// `true` keeps the pill at its natural width; `false` lets the text truncate when space is tight.
    var fixed: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .fixedSize(horizontal: fixed, vertical: false)
        .font(.system(.footnote, design: .rounded, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.control, in: Capsule())
    }
}

enum BigButtonStyle {
    /// Pink: toward an exit. `rest`: blue, toward a break («Вернулись»).
    case primary, rest, secondary, destructive

    var background: Color {
        switch self {
        case .primary: return Theme.accent
        case .rest: return Theme.info
        case .secondary, .destructive: return Theme.control
        }
    }

    var foreground: Color {
        switch self {
        case .primary, .rest: return .black
        case .secondary: return .white
        case .destructive: return Theme.danger
        }
    }

    var isPrimary: Bool { self == .primary || self == .rest }
}

/// Main training actions. Primary ones are filled with the accent, the rest use the shared control fill.
struct BigButton: View {
    var title: String
    var systemImage: String? = nil
    /// Instead of `systemImage`: a training step's icon (the door for «Вышли» / «Вернулись»).
    var icon: StepIcon.Kind? = nil
    var style: BigButtonStyle = .primary
    var height: CGFloat = 52
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .foregroundStyle(style.foreground)
                .background(style.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var label: some View {
        HStack(spacing: 8) {
            if let icon {
                StepIcon(kind: icon, size: style.isPrimary ? 17 : 15)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: style.isPrimary ? 17 : 15, weight: .semibold))
            }
            Text(title)
                .font(.system(size: style.isPrimary ? 17 : 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Round icon button for the HUD corners. `label` is what VoiceOver says: the icon alone says nothing useful.
struct IconButton: View {
    var systemImage: String
    var label: String? = nil
    var tint: Color = .white
    var action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Theme.control, in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        if let label {
            button.accessibilityLabel(label)
        } else {
            button
        }
    }
}
