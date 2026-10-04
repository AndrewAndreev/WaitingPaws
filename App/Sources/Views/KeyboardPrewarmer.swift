#if os(iOS)
import UIKit

/// The first keyboard appearance on a device costs a second or more while iOS loads the input
/// system; pay it right after launch instead of when the schedule editor opens.
enum KeyboardPrewarmer {
    private static var done = false

    static func prewarm(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !done,
                  let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap({ $0.windows })
                    .first(where: { $0.isKeyWindow }) else { return }
            done = true
            let field = UITextField(frame: .zero)
            field.isHidden = true
            window.addSubview(field)
            field.becomeFirstResponder()
            field.resignFirstResponder()
            field.removeFromSuperview()
        }
    }
}
#endif
