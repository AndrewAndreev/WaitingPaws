#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Выбор камеры (D3) — placeholder, implemented in its own change.
struct MacCameraPickerSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("Выбор камеры (D3)", systemImage: "hammer")
            .frame(minWidth: 600, minHeight: 400)
    }
}
#endif
