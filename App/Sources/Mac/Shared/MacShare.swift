#if os(macOS)
import AppKit
import SwiftUI

/// Sharing on the Mac goes through AppKit's own share picker, given plain items: the log as an `NSString` and a video
/// as its file `NSURL`. SwiftUI's `ShareLink` is not used here because it wraps every item in an `NSItemProvider`
/// built from `Transferable`, so a share extension gets the log only as a `public.utf8-plain-text` attachment and
/// never as the item's `attributedContentText`. Telegram's extension takes text only from `attributedContentText`
/// and attachments only when they load as a URL or an image. With the log, its «Отправить» did nothing, its sheet
/// would not close, and the app had to be force-quit.
enum MacShareItem {
    /// Text, with a title for the picker's header («Тренировка 5 нояб.») and a subject for Mail.
    case text(String, title: String, subject: String? = nil)
    case file(URL)

    /// What AppKit gets: a title goes with the text in `NSPreviewRepresentingActivityItem`, which AppKit unwraps
    /// before it builds the extension's input. The text reaches extensions as `attributedContentText`.
    var pickerItem: Any {
        switch self {
        case let .text(text, title, _):
            NSPreviewRepresentingActivityItem(item: text as NSString, title: title, image: nil, icon: nil)
        case let .file(url):
            url as NSURL
        }
    }

    var subject: String? {
        if case let .text(_, _, subject) = self { return subject }
        return nil
    }
}

/// Shows the picker next to a view of the window (the button that asked, or a point inside a bigger view). It keeps
/// the picker while it is open and gives the chosen service the subject (Mail's «Тема»).
@MainActor
final class MacShareAnchor: NSObject, NSSharingServicePickerDelegate {
    fileprivate weak var view: NSView?
    private var picker: NSSharingServicePicker?
    private var subject: String?

    /// Under the whole anchor view (a button), or, with `atPointer`, where the pointer is (a row's context menu:
    /// the menu is gone by then, and the picker opens where it was).
    func show(_ item: MacShareItem, atPointer: Bool = false) {
        guard let view, let window = view.window else { return }
        var rect = view.bounds
        if atPointer {
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            // A rect of no size counts as none: the picker would open from the whole view.
            if view.bounds.contains(point) { rect = NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2) }
        }
        let picker = NSSharingServicePicker(items: [item.pickerItem])
        picker.delegate = self
        self.picker = picker
        subject = item.subject
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    // AppKit calls these on the main thread, from the picker shown above and the service it starts.

    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            if let service, let subject { service.subject = subject }
            if let service { print("[share] \(service.title)") }
        }
    }

    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker,
                                          delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }
}

extension MacShareAnchor: NSSharingServiceDelegate {
    /// An extension's window (Telegram's chat list) opens as a sheet on the window that asked, as ShareLink's did,
    /// not as a panel in the middle of the screen.
    nonisolated func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                                    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        MainActor.assumeIsolated { view?.window }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { print("[share] \(sharingService.title): sent") }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        MainActor.assumeIsolated { print("[share] \(sharingService.title): \(error.localizedDescription)") }
    }
}

/// The NSView a `MacShareAnchor` shows its picker from: put behind the button (or the table) as a background.
struct MacShareAnchorView: NSViewRepresentable {
    let anchor: MacShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// «Отправить…»: a button that opens the share picker under itself. Styles, shortcuts and help go on it as on any
/// button.
struct MacShareButton<Label: View>: View {
    private let item: () -> MacShareItem
    private let label: Label
    @State private var anchor = MacShareAnchor()

    /// `item` is read on the click: a long log is formatted only when it is sent.
    init(_ item: @autoclosure @escaping () -> MacShareItem, @ViewBuilder label: () -> Label) {
        self.item = item
        self.label = label()
    }

    var body: some View {
        Button { anchor.show(item()) } label: { label }
            .background(MacShareAnchorView(anchor: anchor))
    }
}
#endif
