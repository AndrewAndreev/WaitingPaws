import AppIntents
import Foundation

/// The step button of the Live Activity («Вернулись», «Вышли»): pressed on the lock screen or in the expanded Dynamic
/// Island without opening the app. A `LiveActivityIntent` runs in the app's process (iOS wakes the app in the
/// background, or launches it), so the step is taken by the app's own training — and a training mirrored from a Mac
/// forwards it there, as the app's buttons do. The extension compiles this type only to draw the button.
struct TrainingStepIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Training step"
    /// Only for the button: not offered in Shortcuts, Spotlight or Siri.
    static let isDiscoverable = false
    /// The point is not to unlock the phone behind the door.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// `TrainingActivityAttributes.Step`.
    @Parameter(title: "Step")
    var step: String
    /// `TrainingActivityAttributes.training`: a press left over from another training does nothing.
    @Parameter(title: "Training")
    var training: String

    init() {}

    init(step: TrainingActivityAttributes.Step, training: String) {
        self.step = step.rawValue
        self.training = training
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let kind = TrainingActivityAttributes.Step(rawValue: step), let handler = Self.handler {
            await handler(kind, training)
        }
        return .result()
    }

    /// Set by the app when it starts (`TrainingGlance.start`): takes the step if it is still the one on the button.
    /// Nil in the widget extension, which never performs it.
    @MainActor static var handler: ((TrainingActivityAttributes.Step, String) async -> Void)?
}
