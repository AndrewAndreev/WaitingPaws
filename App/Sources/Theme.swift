import SwiftUI

enum Theme {
    /// Light pink.
    static let accent = Color(red: 1.00, green: 0.72, blue: 0.80)
    static let danger = Color(red: 1.00, green: 0.42, blue: 0.42)
    static let warning = Color(red: 1.00, green: 0.72, blue: 0.30)
    static let info = Color(red: 0.55, green: 0.75, blue: 1.00)
    /// Card background.
    static let panel = Color(white: 0.10)
    /// Every secondary control (pills, icon buttons, secondary buttons) shares this fill.
    static let control = Color(white: 0.18)
    static let cornerRadius: CGFloat = 24

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Platform helpers

enum Pasteboard {
    static var string: String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #else
        return NSPasteboard.general.string(forType: .string)
        #endif
    }
}

extension View {
    /// Disables autocapitalisation / autocorrection for logins, URLs and codes.
    @ViewBuilder
    func plainInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Sensible sheet size on macOS; no-op on iOS.
    @ViewBuilder
    func sheetFrame(width: CGFloat = 560, height: CGFloat = 680) -> some View {
        #if os(macOS)
        self.frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }
}

#if os(macOS)
enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif
