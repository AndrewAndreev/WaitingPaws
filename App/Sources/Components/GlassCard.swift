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
    /// Only the icon where the bar has no room for the words (small iPhones); the words are what VoiceOver says.
    var iconOnly: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            if !iconOnly || systemImage == nil {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .fixedSize(horizontal: fixed, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .font(.system(.footnote, design: .rounded, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.control, in: Capsule())
    }
}

enum BigButtonStyle {
    /// Pink: toward an exit. `rest`: blue, toward a break («Вернулись»). `go`: green «Вернулись» once the trainer's
    /// condition says it is time («Можно входить»). `held`: the same step while the trainer says to wait («Ждите
    /// тишины»): not inviting, but plainly a button — white words at full size and a rim, not a dimmed one.
    /// `caution`: orange words, «Фальстарт» (orange like a false start everywhere else; red is the rule's).
    case primary, rest, go, held, secondary, caution, destructive

    var background: Color {
        switch self {
        case .primary: return Theme.accent
        case .rest: return Theme.info
        case .go: return Theme.go
        // A step lighter than the other grey buttons, with its rim: the button to press when it is time, not a
        // disabled one (design council, round 8).
        case .held: return Color(white: 0.24)
        case .secondary, .caution, .destructive: return Theme.control
        }
    }

    var foreground: Color {
        switch self {
        case .primary, .rest, .go: return .black
        case .held, .secondary: return .white
        case .caution: return Theme.warning
        case .destructive: return Theme.danger
        }
    }

    /// The step button's size of words (a held step is still the step).
    var isPrimary: Bool { self == .primary || self == .rest || self == .go || self == .held }
}

/// Main training actions. Primary ones are filled with the accent, the rest use the shared control fill. The words and
/// the icon grow with larger system text up to 1.24× (`TypeScale.capped`): «Вернулись» and «Фальстарт» side by side
/// still fit a small iPhone's row, and the button keeps its height (there is room in it for the larger words). A
/// button on a row of its own (`growsWithText`: the training's buttons one under the other at the accessibility
/// sizes) grows on, and so does its height.
struct BigButton: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var title: String
    /// Said instead of `title` where that doesn't fit: «Фальстарт 4» for «Фальстарт выхода 4».
    var compactTitle: String? = nil
    /// A second, smaller line under the title: what a press does, said before it is pressed — «Начать перерыв
    /// заново» under «Фальстарт выхода 4».
    var subtitle: String? = nil
    var systemImage: String? = nil
    /// Instead of `systemImage`: a training step's icon (the door for «Вышли» / «Вернулись»).
    var icon: StepIcon.Kind? = nil
    var style: BigButtonStyle = .primary
    var height: CGFloat = 52
    /// The whole row is the button's: past the cap its words grow with the system text.
    var growsWithText = false
    var action: () -> Void

    var body: some View {
        let size = (style.isPrimary ? 17 : 15) * scale
        Button(action: action) {
            label(size: size)
                .frame(maxWidth: .infinity)
                .frame(height: growsWithText ? max(height, size * (subtitle == nil ? 2.0 : 2.7)) : height)
                .foregroundStyle(style.foreground)
                .background(style.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if style == .held {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var scale: CGFloat {
        growsWithText && typeSize.isAccessibilitySize ? TypeScale.factor(typeSize) : TypeScale.capped(typeSize)
    }

    @ViewBuilder
    private func label(size: CGFloat) -> some View {
        if let subtitle {
            VStack(spacing: 1) {
                titleRow(size: size)
                Text(subtitle)
                    .font(.system(size: size * 0.74, weight: .medium, design: .rounded))
                    .opacity(0.78)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8)
            }
        } else {
            titleRow(size: size)
        }
    }

    @ViewBuilder
    private func titleRow(size: CGFloat) -> some View {
        if let compactTitle {
            // The whole words a little smaller before the short ones.
            ViewThatFits(in: .horizontal) {
                row(title, size: size)
                row(title, size: size * 0.88)
                row(compactTitle, size: size)
            }
            .padding(.horizontal, 8)
        } else {
            row(title, size: size)
        }
    }

    private func row(_ title: String, size: CGFloat) -> some View {
        HStack(spacing: 8) {
            if let icon {
                StepIcon(kind: icon, size: size)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size, weight: .semibold))
            }
            Text(title)
                .font(.system(size: size, weight: .semibold, design: .rounded))
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
