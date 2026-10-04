#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Окно приветствия (D1) — placeholder, implemented in its own change.
struct MacWelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("Окно приветствия (D1)", systemImage: "hammer")
            .frame(minWidth: 600, minHeight: 400)
    }
}
#endif
