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
        #if DEBUG && os(iOS)
        // `--demo-width 320`: the screen as narrow as a small iPhone with Display Zoom (no such simulator).
        .frame(maxWidth: Self.demoWidth)
        #endif
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

    #if DEBUG && os(iOS)
    private static let demoWidth: CGFloat? = CommandLine.arguments.firstIndex(of: "--demo-width").flatMap { index in
        index + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[index + 1]).map { CGFloat($0) } : nil
    }
    #endif
}
