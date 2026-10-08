#if os(macOS)
import SwiftUI

/// Width of the «Пульт» panel on the right (the new training / the session readout) and the toolbar above it.
///
/// The panel is resized by its edge and folds away into «Только камера» when dragged past its narrowest. The toolbar
/// follows it: the panel's buttons (recording, sound, history…) sit over the panel at the window's edge, the camera's
/// group always on the camera's side of the panel's edge. The toolbar places items from the window's edge, so a
/// spacer item between the two groups as wide as the gap they leave decides where the camera's group lands; when the
/// panel's buttons don't fit over it with their titles, they drop the titles.
enum ConsolePanelLayout {
    /// Enough for the timer, the two step buttons and «Начать тренировку и запись ⌘↩».
    static let minWidth: CGFloat = 340
    static let defaultWidth: CGFloat = 380
    static let maxWidth: CGFloat = 720
    /// The camera keeps at least this much of the window.
    static let minCameraWidth: CGFloat = 420
    /// Dragging the edge this far past `minWidth` folds the panel away.
    static let foldDistance: CGFloat = 80

    static func widthRange(window: CGFloat) -> ClosedRange<CGFloat> {
        guard window > 0 else { return minWidth...maxWidth }
        return minWidth...max(minWidth, min(maxWidth, window - minCameraWidth))
    }

    /// The toolbar's own room around an item (macOS 26: 8 pt before it, 10 pt after), and the gap kept on each side
    /// of the panel's edge.
    static let itemSpacing: CGFloat = 18
    static let edgeInset: CGFloat = 8

    /// Width of the spacer item that puts the camera's group right before the panel's edge (`edge` in window
    /// coordinates, nil without the panel). `buttonsMinX` is where the panel's buttons begin: the toolbar places them
    /// from the window's edge, so they stay put when the spacer changes. (The spacer's own frame is no anchor: SwiftUI
    /// lays a wider spacer out centred in its old item before the toolbar resizes the item.)
    static func spacerWidth(buttonsMinX: CGFloat?, edge: CGFloat?, window: CGFloat) -> CGFloat {
        // The first layout passes report items at the window's left: not yet where they will be.
        guard let buttonsMinX, let edge, window > 0, buttonsMinX > window / 2 else { return 1 }
        return max(1, buttonsMinX - itemSpacing - (edge - edgeInset))
    }

    /// Whether the panel's buttons fit over the panel. `buttonsWidth`: from their left end to the window's edge.
    static func fits(buttonsWidth: CGFloat, edge: CGFloat, window: CGFloat) -> Bool {
        window - buttonsWidth >= edge + edgeInset
    }
}

/// The panel's left edge: a line with a few points to grab. Drag to resize; past the narrowest width the panel
/// folds away (`onFold`) when that is allowed.
struct TrainingPanelEdge: View {
    @Binding var width: Double
    var range: ClosedRange<CGFloat>
    var canFold: Bool
    var onFold: () -> Void
    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .overlay(alignment: .leading) { Divider() }
            // A background, not a view: like the panel's own, it runs up under the toolbar, so the panel's colour
            // starts at the same edge there as below.
            .background(Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
        .pointerStyle(.columnResize)
        .gesture(
            // Window coordinates: the edge moves under the pointer while dragging.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    // From the width on screen: the stored one may be wider than a narrow window allows.
                    let start = startWidth ?? min(max(CGFloat(width), range.lowerBound), range.upperBound)
                    startWidth = start
                    let proposed = start - drag.translation.width
                    if canFold, proposed < range.lowerBound - ConsolePanelLayout.foldDistance {
                        // Opens again at the width it had before this drag.
                        width = Double(start)
                        startWidth = nil
                        onFold()
                        return
                    }
                    width = Double(min(max(proposed, range.lowerBound), range.upperBound))
                }
                .onEnded { _ in startWidth = nil }
        )
        .help(canFold ? "Потяните, чтобы изменить ширину; до упора вправо — только камера" : "Потяните, чтобы изменить ширину")
        .accessibilityHidden(true)
    }
}

/// Lives in the toolbar's spacer item and reads from AppKit where the toolbar items around it are: where the panel's
/// buttons (the items after the spacer) begin, and where the camera's group (the items before it) ends. SwiftUI
/// reports a toolbar item's place only when its size changes, and the first of the panel's buttons moves without
/// resizing when those after it change (titles dropped, «Завершить» appears): its reported place went stale and the
/// camera's group ran over the panel's edge. Read after every update of the item, as the toolbar settles.
struct ToolbarNeighboursProbe: NSViewRepresentable {
    /// Anything whose change may move the items (the probe re-reads on every update).
    var token: Int
    var onRead: (_ buttonsMinX: CGFloat, _ groupMaxX: CGFloat?) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onRead = onRead
        view.scheduleReads()
    }

    final class ProbeView: NSView {
        var onRead: ((CGFloat, CGFloat?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleReads()
        }

        /// Now and over the next few hundred milliseconds: the toolbar lays items out after SwiftUI's update.
        func scheduleReads() {
            for delay in [0.0, 0.05, 0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.read() }
            }
        }

        private func read() {
            guard let window, let items = window.toolbar?.items,
                  let index = items.firstIndex(where: { item in item.view.map { isDescendant(of: $0) } ?? false })
            else { return }
            // Items moved into the overflow menu have no window.
            func frames(_ slice: ArraySlice<NSToolbarItem>) -> [CGRect] {
                slice.compactMap { $0.view }.filter { $0.window === window }.map { $0.convert($0.bounds, to: nil) }
            }
            guard let buttonsMinX = frames(items[(index + 1)...]).map(\.minX).min() else { return }
            onRead?(buttonsMinX, frames(items[..<index]).map(\.maxX).max())
        }
    }
}

/// Title and icon, or the icon alone when the toolbar over the panel is short of room.
struct ToolbarFitLabelStyle: LabelStyle {
    var compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}
#endif
