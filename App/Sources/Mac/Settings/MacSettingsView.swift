#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Настройки (E2) — placeholder, implemented in its own change.
struct MacSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("Настройки (E2)", systemImage: "hammer")
            .frame(minWidth: 600, minHeight: 400)
    }
}
#endif
