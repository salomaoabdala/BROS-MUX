// BROS-MUX — gamut conversion for HDR encodes
// A P3-D65 or BT.709 master that is encoded as HDR10 / Dolby Vision must travel in a BT.2020 container: the primaries are
// converted in linear light (PQ decoded, 3×3 matrix, PQ encoded) through a 3D LUT that ffmpeg's lut3d filter applies in
// float. The colours themselves don't change — BT.2020 is the wider box they are carried in. The LUT is written once to
// the app's cache and reused. Checked against the exact maths on a real frame of 2DIE4: every pixel within 1 code value.

import Foundation

enum ColorLUT {
    static let size = 65
    static let version = 1

    // SMPTE ST 2084 (PQ), 1.0 = 10 000 nits
    static let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
    static let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
    static func pqToLinear(_ e: Double) -> Double {
        let e = min(max(e, 0), 1), p = pow(e, 1 / m2), n = max(p - c1, 0)
        return pow(n / (c2 - c3 * p), 1 / m1)
    }
    static func linearToPQ(_ y: Double) -> Double {
        let y = min(max(y, 0), 1), p = pow(y, m1)
        return pow((c1 + c2 * p) / (1 + c3 * p), m2)
    }

    typealias M3 = [[Double]]
    static func inverse(_ m: M3) -> M3 {
        let (a, b, c) = (m[0][0], m[0][1], m[0][2]), (d, e, f) = (m[1][0], m[1][1], m[1][2]), (g, h, i) = (m[2][0], m[2][1], m[2][2])
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
                [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
                [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
    }
    static func mul(_ a: M3, _ b: M3) -> M3 {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }
    /// RGB → XYZ for a set of chromaticities, normalised so that RGB (1,1,1) is the white point
    static func rgbToXYZ(_ p: [(Double, Double)], white: (Double, Double)) -> M3 {
        let P: M3 = [[p[0].0 / p[0].1, p[1].0 / p[1].1, p[2].0 / p[2].1], [1, 1, 1],
                     [(1 - p[0].0 - p[0].1) / p[0].1, (1 - p[1].0 - p[1].1) / p[1].1, (1 - p[2].0 - p[2].1) / p[2].1]]
        let W = [white.0 / white.1, 1.0, (1 - white.0 - white.1) / white.1]
        let inv = inverse(P)
        let S = (0..<3).map { i in (0..<3).reduce(0) { $0 + inv[i][$1] * W[$1] } }
        return (0..<3).map { i in (0..<3).map { j in P[i][j] * S[j] } }
    }

    static let p3d65: [(Double, Double)] = [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)]
    static let bt709: [(Double, Double)] = [(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)]
    static let bt2020: [(Double, Double)] = [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)]
    static let d65 = (0.3127, 0.3290)

    /// The source primaries (ffprobe tag) this can convert to BT.2020
    static func primaries(_ tag: String) -> [(Double, Double)]? {
        switch tag { case "smpte432": return p3d65; case "bt709": return bt709; default: return nil }
    }
    static func label(_ tag: String) -> String {
        switch tag { case "smpte432": return "P3-D65"; case "bt709": return "BT.709"; case "bt2020": return "BT.2020"; default: return tag }
    }

    /// The .cube that converts `tag` (PQ) → BT.2020 (PQ), written once into the app's cache
    static func file(from tag: String) throws -> URL {
        guard let prim = primaries(tag) else { throw AppError("No gamut conversion from \(label(tag)) to BT.2020.") }
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BROS-MUX/luts", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(tag)-to-bt2020-pq-\(size)-v\(version).cube")
        let header = "TITLE \"BROS-MUX \(label(tag)) PQ to BT.2020 PQ\"\nLUT_3D_SIZE \(size)\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        let expected = header.utf8.count + 33 * size * size * size      // every line is "0.12345678 0.12345678 0.12345678\n"
        if let a = try? fm.attributesOfItem(atPath: url.path), (a[.size] as? Int) == expected { return url }
        let m = mul(inverse(rgbToXYZ(bt2020, white: d65)), rgbToXYZ(prim, white: d65))
        var s = header
        s.reserveCapacity(expected)
        let n = Double(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let lin = [pqToLinear(Double(r) / n), pqToLinear(Double(g) / n), pqToLinear(Double(b) / n)]
            // P3 red sits a hair outside BT.2020: the tiny negative blue it produces is clipped to 0
            let o = (0..<3).map { i in linearToPQ(max(0, m[i][0] * lin[0] + m[i][1] * lin[1] + m[i][2] * lin[2])) }
            s += String(format: "%.8f %.8f %.8f\n", o[0], o[1], o[2])
        } } }
        let tmp = url.appendingPathExtension("tmp")
        try s.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
        return url
    }

    /// A path as an ffmpeg filter option value: escaped at both levels (the option's and the filtergraph's)
    static func escaped(_ path: String) -> String {
        func esc(_ s: String, _ special: String) -> String {
            var out = ""
            for ch in s { if special.contains(ch) { out.append("\\") }; out.append(ch) }
            return out
        }
        return esc(esc(path, "\\:'"), "\\'[],;")
    }
}
