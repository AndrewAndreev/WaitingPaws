import SwiftUI
import WaitingPawsCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.settings.isSetUp || model.isLinkedToMac {
                SessionScreen()
            } else {
                OnboardingFlow()
            }
        }
        .animation(.easeInOut, value: model.settings.isSetUp || model.isLinkedToMac)
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.didEnterBackground()
            case .active: Task { await model.didBecomeActive() }
            default: break
            }
        }
        #endif
    }
}
