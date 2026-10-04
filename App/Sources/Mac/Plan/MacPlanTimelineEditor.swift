#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// The plan on a time axis before the start (A6) — placeholder; the real one (drag block edges, zoom) lands separately.
struct MacPlanTimelineEditor: View {
    @Binding var plan: TrainingPlan
    /// The plan as the trainer sent it («Как у тренера»), nil when unknown.
    var original: TrainingPlan?

    var body: some View {
        Text("План: \(plan.exits.count) выходов · ≈ \(DurationText.short(plan.estimatedDuration))")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
