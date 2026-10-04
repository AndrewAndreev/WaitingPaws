#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// История (C2) — placeholder, implemented in its own change.
struct MacHistoryWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("История (C2)", systemImage: "hammer")
            .frame(minWidth: 600, minHeight: 400)
    }
}
#endif
