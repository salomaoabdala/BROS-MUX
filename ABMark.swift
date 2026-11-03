// BROS-MUX — the Abdala Brothers "AB" ligature as vector shapes (generated from the brand artwork; do not edit by hand).
// The A is drawn as an outline and the B as a solid shape, like the official mark.

import SwiftUI

/// Normalised coordinates of the mark (0…1 inside its bounding box; aspect 1.5019)
enum ABMarkGeometry {
    static let aspect: CGFloat = 1.50190
    /// The outlined A occupies this share of the mark's width; its stroke is 7.5 % of that
    static let strokeShare: CGFloat = 0.04370
    static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
}

private func scaled(_ p: Path, into rect: CGRect) -> Path {
    p.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width, y: rect.height))
}

/// The letter A of the mark (stroke it)
struct ABMarkA: Shape {
    func path(in rect: CGRect) -> Path {
        typealias P = CGPoint
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var p = Path()
        p.move(to: P(0.17982, 0.45851))
        p.addLine(to: P(0.37267, 0.45851))
        p.addCurve(to: P(0.39894, 0.43573), control1: P(0.38347, 0.45851), control2: P(0.39354, 0.44978))
        p.addCurve(to: P(0.39894, 0.39017), control1: P(0.40434, 0.42168), control2: P(0.40434, 0.40422))
        p.addLine(to: P(0.37994, 0.34073))
        p.addLine(to: P(0.30248, 0.13924))
        p.addLine(to: P(0.34150, 0.03635))
        p.addLine(to: P(0.37583, 0.03635))
        p.addLine(to: P(0.45325, 0.23773))
        p.addLine(to: P(0.55544, 0.50318))
        p.addLine(to: P(0.51643, 0.60535))
        p.addLine(to: P(0.25380, 0.60536))
        p.addCurve(to: P(0.22755, 0.62807), control1: P(0.24302, 0.60536), control2: P(0.23296, 0.61406))
        p.addLine(to: P(0.10096, 0.95601))
        p.addLine(to: P(0.06651, 0.95601))
        p.addLine(to: P(0.02728, 0.85397))
        p.addLine(to: P(0.17982, 0.45851))
        p.move(to: P(0.05076, 0.98775))
        p.addCurve(to: P(0.05607, 0.99236), control1: P(0.05186, 0.99060), control2: P(0.05388, 0.99236))
        p.addLine(to: P(0.11137, 0.99236))
        p.addCurve(to: P(0.11667, 0.98776), control1: P(0.11355, 0.99236), control2: P(0.11558, 0.99060))
        p.addLine(to: P(0.24849, 0.64630))
        p.addCurve(to: P(0.25380, 0.64170), control1: P(0.24959, 0.64346), control2: P(0.25161, 0.64170))
        p.addLine(to: P(0.52689, 0.64170))
        p.addCurve(to: P(0.53222, 0.63707), control1: P(0.52910, 0.64170), control2: P(0.53113, 0.63993))
        p.addLine(to: P(0.58161, 0.50771))
        p.addCurve(to: P(0.58160, 0.49851), control1: P(0.58270, 0.50486), control2: P(0.58269, 0.50136))
        p.addLine(to: P(0.47420, 0.21954))
        p.addLine(to: P(0.39158, 0.00461))
        p.addCurve(to: P(0.38626, 0.00000), control1: P(0.39048, 0.00175), control2: P(0.38845, 0.00000))
        p.addLine(to: P(0.33100, 0.00000))
        p.addCurve(to: P(0.32567, 0.00465), control1: P(0.32879, 0.00000), control2: P(0.32675, 0.00178))
        p.addLine(to: P(0.27633, 0.13477))
        p.addCurve(to: P(0.27634, 0.14394), control1: P(0.27525, 0.13761), control2: P(0.27525, 0.14110))
        p.addLine(to: P(0.35898, 0.35890))
        p.addLine(to: P(0.37798, 0.40834))
        p.addCurve(to: P(0.37267, 0.42216), control1: P(0.38034, 0.41449), control2: P(0.37739, 0.42216))
        p.addLine(to: P(0.16941, 0.42216))
        p.addCurve(to: P(0.16410, 0.42676), control1: P(0.16722, 0.42216), control2: P(0.16520, 0.42391))
        p.addLine(to: P(0.00110, 0.84933))
        p.addCurve(to: P(0.00110, 0.85856), control1: P(0.00000, 0.85218), control2: P(0.00000, 0.85570))
        p.addLine(to: P(0.05076, 0.98775))
        p.closeSubpath()
        return scaled(p, into: rect)
    }
}

/// The letter B of the mark (fill it)
struct ABMarkB: Shape {
    func path(in rect: CGRect) -> Path {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var p = Path()
        p.move(to: P(0.99819, 0.46569))
        p.addLine(to: P(0.93844, 0.37596))
        p.addLine(to: P(0.93811, 0.37546))
        p.addLine(to: P(0.89156, 0.37546))
        p.addCurve(to: P(0.88621, 0.36153), control1: P(0.88680, 0.37546), control2: P(0.88383, 0.36772))
        p.addLine(to: P(0.94039, 0.22072))
        p.addLine(to: P(0.96964, 0.14461))
        p.addCurve(to: P(0.96964, 0.13533), control1: P(0.97074, 0.14174), control2: P(0.97074, 0.13820))
        p.addLine(to: P(0.91961, 0.00518))
        p.addCurve(to: P(0.91426, 0.00054), control1: P(0.91851, 0.00231), control2: P(0.91647, 0.00054))
        p.addLine(to: P(0.51047, 0.00054))
        p.addCurve(to: P(0.50428, 0.00982), control1: P(0.50705, 0.00054), control2: P(0.50428, 0.00469))
        p.addLine(to: P(0.50428, 0.06443))
        p.addCurve(to: P(0.50511, 0.06908), control1: P(0.50428, 0.06606), control2: P(0.50457, 0.06767))
        p.addLine(to: P(0.56162, 0.21608))
        p.addCurve(to: P(0.56697, 0.22072), control1: P(0.56273, 0.21895), control2: P(0.56477, 0.22072))
        p.addLine(to: P(0.76040, 0.22072))
        p.addCurve(to: P(0.76575, 0.23465), control1: P(0.76516, 0.22072), control2: P(0.76813, 0.22846))
        p.addLine(to: P(0.68231, 0.45156))
        p.addCurve(to: P(0.68231, 0.46085), control1: P(0.68121, 0.45444), control2: P(0.68121, 0.45798))
        p.addLine(to: P(0.73234, 0.59100))
        p.addCurve(to: P(0.73769, 0.59564), control1: P(0.73345, 0.59387), control2: P(0.73549, 0.59564))
        p.addLine(to: P(0.84274, 0.59564))
        p.addCurve(to: P(0.84810, 0.60954), control1: P(0.84748, 0.59564), control2: P(0.85046, 0.60335))
        p.addLine(to: P(0.78497, 0.77515))
        p.addCurve(to: P(0.77961, 0.77982), control1: P(0.78387, 0.77803), control2: P(0.78182, 0.77982))
        p.addLine(to: P(0.29567, 0.77982))
        p.addCurve(to: P(0.29032, 0.78446), control1: P(0.29346, 0.77982), control2: P(0.29142, 0.78159))
        p.addLine(to: P(0.24052, 0.91400))
        p.addCurve(to: P(0.23969, 0.91864), control1: P(0.23998, 0.91541), control2: P(0.23969, 0.91701))
        p.addLine(to: P(0.23969, 0.99072))
        p.addCurve(to: P(0.24588, 1.00000), control1: P(0.23969, 0.99584), control2: P(0.24246, 1.00000))
        p.addLine(to: P(0.86412, 1.00000))
        p.addCurve(to: P(0.86947, 0.99536), control1: P(0.86633, 1.00000), control2: P(0.86837, 0.99823))
        p.addLine(to: P(0.99917, 0.65797))
        p.addCurve(to: P(1.00000, 0.65333), control1: P(0.99971, 0.65655), control2: P(1.00000, 0.65496))
        p.addLine(to: P(1.00000, 0.47226))
        p.addCurve(to: P(0.99819, 0.46569), control1: P(1.00000, 0.46980), control2: P(0.99935, 0.46744))
        p.closeSubpath()
        return scaled(p, into: rect)
    }
}

/// The complete mark in one colour, keeping its proportions
struct ABMark: View {
    var color: Color = .primary
    var body: some View {
        GeometryReader { g in
            let stroke = g.size.width * ABMarkGeometry.strokeShare
            let inner = CGRect(origin: .zero, size: g.size).insetBy(dx: stroke / 2 + 0.5, dy: stroke / 2 + 0.5)
            ZStack {
                ABMarkB().path(in: inner).fill(color)
                ABMarkA().path(in: inner).stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
            }
        }
        .aspectRatio(ABMarkGeometry.aspect, contentMode: .fit)
        .accessibilityLabel("Abdala Brothers")
    }
}
