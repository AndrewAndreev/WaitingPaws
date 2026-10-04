import SwiftUI
import WaitingPawsCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.settings.isConfigured || model.isLinkedToMac {
                SessionScreen()
            } else {
                OnboardingFlow()
            }
        }
        .animation(.easeInOut, value: model.settings.isConfigured || model.isLinkedToMac)
    }
}
