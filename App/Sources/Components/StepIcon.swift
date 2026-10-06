import SwiftUI

/// The icon of a training step. «Вышли» and «Вернулись» are the same door with the arrow going out of it or coming
/// back in (SF Symbols has the first only); other steps use a symbol.
struct StepIcon: View {
    enum Kind: Equatable {
        case outside, backInside
        case symbol(String)
    }

    let kind: Kind
    /// About the size of the text next to it.
    var size: CGFloat

    var body: some View {
        switch kind {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size, weight: .semibold))
        case .outside, .backInside:
            DoorArrowShape(entering: kind == .backInside)
                .stroke(style: StrokeStyle(lineWidth: max(1.5, size * 0.13), lineCap: .round, lineJoin: .round))
                .frame(width: size * 1.2, height: size * 1.2)
                .accessibilityHidden(true)
        }
    }
}

/// A door open on its right side with an arrow through the gap: out of it, or into it (`entering`). Drawn on a
/// 24 pt grid and scaled.
struct DoorArrowShape: Shape {
    var entering: Bool

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // The door: its right side open where the arrow passes.
        path.move(to: p(14, 9))
        path.addLine(to: p(14, 5.5))
        path.addQuadCurve(to: p(11.5, 3), control: p(14, 3))
        path.addLine(to: p(6.5, 3))
        path.addQuadCurve(to: p(4, 5.5), control: p(4, 3))
        path.addLine(to: p(4, 18.5))
        path.addQuadCurve(to: p(6.5, 21), control: p(4, 21))
        path.addLine(to: p(11.5, 21))
        path.addQuadCurve(to: p(14, 18.5), control: p(14, 21))
        path.addLine(to: p(14, 15))
        // The arrow: out to the right, or in from the right.
        path.move(to: p(9, 12))
        path.addLine(to: p(21, 12))
        if entering {
            path.move(to: p(13, 8))
            path.addLine(to: p(9, 12))
            path.addLine(to: p(13, 16))
        } else {
            path.move(to: p(17, 8))
            path.addLine(to: p(21, 12))
            path.addLine(to: p(17, 16))
        }
        return path
    }
}
