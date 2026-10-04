import SwiftUI

/// Pinch (or trackpad magnify) to zoom, drag to pan when zoomed, double-tap to reset.
/// The content itself does not receive touches, so it works over a WKWebView.
struct ZoomableView<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topTrailing) {
                content
                    .allowsHitTesting(false)
                    // Always the same modifier chain: an `if` here would change the view identity and recreate the web view.
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(magnify(in: size).simultaneously(with: drag(in: size)))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.3)) { reset() }
                    }

                if scale > 1.01 {
                    Button {
                        withAnimation(.spring(response: 0.3)) { reset() }
                    } label: {
                        Pill(text: String(format: "%.1f×", scale), systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(10)
                }
            }
        }
        .clipped()
    }

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(maxScale, max(1, baseScale * value.magnification))
                offset = clamped(offset, in: size)
            }
            .onEnded { _ in
                baseScale = scale
                baseOffset = offset
                if scale <= 1.01 { withAnimation(.spring(response: 0.3)) { reset() } }
            }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: scale > 1 ? 0 : 1_000)
            .onChanged { value in
                guard scale > 1 else { return }
                offset = clamped(CGSize(width: baseOffset.width + value.translation.width,
                                        height: baseOffset.height + value.translation.height), in: size)
            }
            .onEnded { _ in baseOffset = offset }
    }

    /// Keeps the zoomed content covering the viewport.
    private func clamped(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}
