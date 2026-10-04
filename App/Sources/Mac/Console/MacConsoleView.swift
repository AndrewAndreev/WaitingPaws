#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// «Пульт» — placeholder until the console lands.
struct MacConsoleView: View {
    var body: some View {
        ContentUnavailableView("Пульт", systemImage: "hammer")
    }
}
#endif
