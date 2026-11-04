// BROS-MUX — Alignment meter
// A sync measurement is never one number: the sound is measured at many points of the film (against another audio
// track, by cross-correlation — SyncEngine — or against the picture's hard cuts — PictureSync). This meter turns those
// points into one verdict a person can act on: once a correction is applied (the trim chosen by "Align", or one typed
// by hand), how much of the film is aligned, and where and by how much it drifts — "aligned 62% of the film; from
// 37:05 the sound is 1 frame + 0.0 ms late (41.7 ms)". It also says which single correction aligns the most film
// when no single offset fits everywhere (a reel with a frame missing, a conform that slipped).

import Foundation

enum Alignment {
    /// One measurement: at `time` (s into the film) the sound is `lag` s LATE (negative = early) vs the reference or the picture
    struct Point { let time: Double; let lag: Double }

    /// A stretch of the film where the sound sits at the same offset
    struct Span {
        let from: Double, to: Double       // s into the film
        let residual: Double               // s left after the correction (> 0 = still late, < 0 = early)
        let points: Int                    // measurements inside it
        var length: Double { max(0, to - from) }
    }

    /// Tolerance (ms): what a viewer doesn't notice. ATSC IS-191: sound up to 15 ms early or 45 ms late.
    static let early = -15.0, late = 45.0
    static func ok(_ residual: Double) -> Bool { residual * 1000 >= early && residual * 1000 <= late }

    struct Meter {
        let fps: Double
        let duration: Double               // s, the whole film
        let applied: Double                // s taken off the head of the sound (negative = the sound was delayed)
        let spans: [Span]
        let measuredFrom: Double, measuredTo: Double   // where the measurements come from (the head and tail beyond them are assumed to follow)
        let points: Int

        var alignedSeconds: Double { spans.filter { ok($0.residual) }.reduce(0) { $0 + $1.length } }
        var alignedFraction: Double { duration > 0 ? min(1, alignedSeconds / duration) : 0 }
        var drifts: [Span] { spans.filter { !ok($0.residual) } }
        var allAligned: Bool { drifts.isEmpty }
        /// the worst residual (ms) over the whole film
        var worstMs: Double { spans.map { abs($0.residual) * 1000 }.max() ?? 0 }

        /// "aligned 62% of the film (37:05 of 60:09) · from 37:05 to the end the sound is 1 fr + 0.0 ms late (41.7 ms)"
        var summary: String {
            guard !spans.isEmpty else { return "alignment not measured" }
            if spans.count == 1 {
                let r = spans[0].residual
                return (ok(r) ? "aligned from start to end" : "out of sync from start to end") + " · " + Alignment.text(residual: r, fps: fps)
            }
            var s = String(format: "aligned %.0f%% of the film (%@ of %@, %d measured points)", alignedFraction * 100, Alignment.clock(alignedSeconds), Alignment.clock(duration), points)
            for d in drifts.prefix(3) { s += " · " + Alignment.where(d, duration: duration) + " the sound is " + Alignment.text(residual: d.residual, fps: fps) }
            if drifts.count > 3 { s += " · and \(drifts.count - 3) more stretch\(drifts.count - 3 == 1 ? "" : "es") out of sync" }
            // inside the tolerance but not exact (half a frame or more): worth knowing, e.g. "1 fr late" on a 24 fps film (41.7 ms < 45 ms)
            let frameMs = fps > 0 ? 1000 / fps : 1000 / 24
            for n in spans.filter({ ok($0.residual) && abs($0.residual) * 1000 >= frameMs / 2 }).prefix(2) {
                s += " · " + Alignment.where(n, duration: duration) + " the sound is " + Alignment.text(residual: n.residual, fps: fps) + ", inside the tolerance"
            }
            return s
        }
        /// one line per stretch, in order
        var lines: [String] {
            spans.map { "\(Alignment.clock($0.from))–\(Alignment.clock($0.to)): \(Alignment.text(residual: $0.residual, fps: fps)) \(ok($0.residual) ? "✓" : "✗") (\($0.points) point\($0.points == 1 ? "" : "s"))" }
        }
        var note: String { String(format: "measured between %@ and %@; the head and tail are assumed to follow", Alignment.clock(measuredFrom), Alignment.clock(measuredTo)) }
    }

    /// "37:05" or "1:02:10" — the meter's clock (seconds are enough here)
    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s).rounded()), h = t / 3600, m = t / 60 % 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// "1 fr + 5.3 ms late (47.0 ms)" / "5.3 ms late" / "exact"
    static func text(residual: Double, fps: Double) -> String {
        let ms = residual * 1000
        guard abs(ms) >= 0.05 else { return "exact" }
        let frameMs = fps > 0 ? 1000 / fps : 1000 / 24
        let fr = Int(abs(ms) / frameMs), rest = abs(ms) - Double(fr) * frameMs
        let side = ms > 0 ? "late" : "early"
        if fr == 0 { return String(format: "%.1f ms %@", abs(ms), side) }
        return String(format: "%d fr + %.1f ms %@ (%.1f ms)", fr, rest, side, abs(ms))
    }
    static func `where`(_ s: Span, duration: Double) -> String {
        if s.from <= 0.001 && s.to >= duration - 0.001 { return "from start to end" }
        if s.from <= 0.001 { return "up to \(Alignment.clock(s.to))" }
        if s.to >= duration - 0.001 { return "from \(Alignment.clock(s.from)) to the end" }
        return "from \(Alignment.clock(s.from)) to \(Alignment.clock(s.to))"
    }

    /// Groups the points into stretches of equal offset, after taking `applied` off, and measures how much of the film is aligned.
    /// Points closer than a third of a frame (or 10 ms) are the same stretch; the boundary between two stretches is halfway
    /// between their last and first points. Returns nil without points.
    static func measure(points: [Point], applied: Double, fps: Double, duration: Double) -> Meter? {
        let pts = points.sorted { $0.time < $1.time }
        guard !pts.isEmpty, duration > 0 else { return nil }
        let same = max(0.010, 0.34 / max(1, fps))
        var groups: [[Point]] = []
        for p in pts {
            if let last = groups.last, let ref = last.first, abs(p.lag - Fmt.median(last.map(\.lag))) <= same || abs(p.lag - ref.lag) <= same {
                groups[groups.count - 1].append(p)
            } else { groups.append([p]) }
        }
        var spans: [Span] = []
        for (i, g) in groups.enumerated() {
            let from = i == 0 ? 0 : (groups[i - 1].last!.time + g.first!.time) / 2
            let to = i == groups.count - 1 ? duration : (g.last!.time + groups[i + 1].first!.time) / 2
            spans.append(Span(from: from, to: to, residual: Fmt.median(g.map(\.lag)) - applied, points: g.count))
        }
        return Meter(fps: fps, duration: duration, applied: applied, spans: spans, measuredFrom: pts.first!.time, measuredTo: pts.last!.time, points: pts.count)
    }

    /// The single correction that aligns the most film (s to take off the head of the sound): the offset whose stretches,
    /// added together, cover the most minutes — not only the longest one, since a stray measurement can split a stretch in two
    static func bestCorrection(points: [Point], fps: Double, duration: Double) -> Double? {
        guard let m = measure(points: points, applied: 0, fps: fps, duration: duration) else { return nil }
        let same = max(0.010, 0.34 / max(1, fps))
        var best: (lag: Double, total: Double)? = nil
        for s in m.spans {
            let total = m.spans.filter { abs($0.residual - s.residual) <= same }.reduce(0) { $0 + $1.length }
            if best == nil || total > best!.total { best = (s.residual, total) }
        }
        return best?.lag
    }
}
