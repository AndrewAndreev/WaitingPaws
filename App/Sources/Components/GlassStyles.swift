import SwiftUI

// Liquid Glass pieces of the iPhone setup screens (welcome, sign-in, nearby computer). iOS 26 gets the system glass;
// iOS 17–18 a dark material with the same shapes.

extension View {
    /// Glass behind a card or a small HUD element.
    @ViewBuilder
    func glassPanel<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(tint.map { $0.opacity(0.4) } ?? .clear, in: shape)
                .overlay(shape.stroke(.white.opacity(0.08), lineWidth: 1))
        }
    }
}

/// Full-width capsule button: the pink prominent glass for the main action (with a dark label: white on light pink
/// is unreadable), clear glass for the second one.
struct WideGlassButton: View {
    var title: String
    var systemImage: String? = nil
    var prominent = true
    var busy = false
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            if prominent {
                Button(action: action) { label.foregroundStyle(isEnabled ? Color.black : Color.secondary) }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(Theme.accent)
            } else {
                Button(action: action) { label.foregroundStyle(.white) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
        } else {
            Button(action: action) { label.foregroundStyle(prominent && isEnabled ? Color.black : .white) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(prominent ? Theme.accent : Theme.control)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().tint(.black)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.system(size: 17, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 30)
    }
}

/// Round ✕ (or another symbol) for the corner of a card or sheet.
struct GlassCircleButton: View {
    var systemImage = "xmark"
    var action: () -> Void

    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        } else {
            IconButton(systemImage: systemImage, action: action)
        }
    }
}

/// The app icon as on the home screen (the system mask, a hairline so the black icon shows on the dark background).
struct AppIconImage: View {
    var size: CGFloat
    var glow = true

    var body: some View {
        Image("AppIconImage")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: max(0.5, size / 140))
            )
            .shadow(color: glow ? Theme.accent.opacity(0.28) : .clear, radius: size * 0.28)
            .shadow(color: .black.opacity(0.5), radius: size * 0.08, y: size * 0.04)
            .accessibilityHidden(true)
    }
}

/// Night behind the setup screens: black with a plum and indigo haze (something for the glass to bend) and a soft
/// pink glow where the icon is.
struct NightBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.035, blue: 0.06)
            if #available(iOS 18, macOS 15, *) {
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.45], [0.6, 0.38], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ], colors: [
                    Color(red: 0.13, green: 0.10, blue: 0.24), Color(red: 0.09, green: 0.07, blue: 0.17), Color(red: 0.16, green: 0.08, blue: 0.18),
                    Color(red: 0.05, green: 0.05, blue: 0.10), Color(red: 0.10, green: 0.06, blue: 0.13), Color(red: 0.06, green: 0.05, blue: 0.11),
                    Color(red: 0.02, green: 0.02, blue: 0.04), Color(red: 0.03, green: 0.03, blue: 0.05), Color(red: 0.02, green: 0.02, blue: 0.04),
                ])
            } else {
                LinearGradient(colors: [Color(red: 0.12, green: 0.09, blue: 0.21), Color(red: 0.03, green: 0.03, blue: 0.05)],
                               startPoint: .top, endPoint: .bottom)
            }
            RadialGradient(colors: [Theme.accent.opacity(0.20), .clear], center: UnitPoint(x: 0.5, y: 0.28),
                           startRadius: 10, endRadius: 260)
        }
        .ignoresSafeArea()
    }
}
