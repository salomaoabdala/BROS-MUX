// BROS-MUX — Picture Sync Check
// The Sync panel lines audio up with audio. This checks audio against the PICTURE itself: hard cuts in the image are
// found by decoding tiny frames, sudden hits are found in the sound, and the offset at which hits land on cuts tells
// how late (or early) the sound is vs the picture. A viewer shows the frames around a cut with the waveform under them
// and plays the moment in a loop, so the result can be checked by eye and ear.

import SwiftUI
import AVKit
import AVFoundation
import Accelerate

enum PictureSync {
    struct Segment { let start: Double; let length: Double }
    struct Cut { let time: Double; let strength: Double; let segment: Int }      // time = first frame of the new shot
    struct Hit { let cut: Double; let onset: Double; let rise: Double }           // onset = where the sound hits (same timeline)
    struct OnsetCurve { let start: Double; let hop: Double; let values: [Float] } // sound change (dB) per 2 ms step
    struct Group {
        let lag: Double                // s from the cut
        let value: Double              // votes (spread-weighted)
        let count: Int                 // cuts that agree
        let windows: Int               // how many of the film's windows they come from
        let points: [Hit]              // the best ones to check by eye
    }
    struct Result {
        var offset: Double?            // s; > 0 = the sound is LATE vs the picture
        var cuts = 0
        var hits = 0
        var ratio = 0.0                // peak of the match vs the runner-up
        var spreadMs = 0.0
        var points: [Hit] = []         // the best cut-with-a-hit places to check by eye (strongest first)
        var curve: [Double] = []       // match score per ms, from -range to +range
        var message = ""
        var frames: Double? = nil      // offset in video frames
        var peaks: [[(lag: Double, rise: Double)]] = []   // per cut: its strongest sound rises (lag from the cut, dB)
        var groups: [Group] = []       // groups of agreeing cuts, strongest first (the first one is the answer)
        var confident = false          // the best group clearly beats the next one
        var windows: [Alignment.Point] = []   // per window of the film: the lag its cuts vote for most (windows with no vote are left out)
        var meter: Alignment.Meter? = nil     // how much of the film is aligned, and where it drifts (Alignment.swift)
    }
    static let range = 0.25            // s searched each side of a cut
    static let thumbW = 96, thumbH = 54

    static let bodyFrom = 0.05, bodyTo = 0.80   // the part of the film that is measured (the user's rule: 5%–80%)

    /// Evenly spread windows over the BODY of the film: the head (studio logos, title cards) and the tail (end credits,
    /// archive footage, post-credits scenes) are often out of sync on purpose or by accident, so they are left out.
    static func segments(duration: Double, points: Int, window: Double) -> [Segment] {
        let win = min(window, max(4, duration / 8))
        let lo = max(range + 0.5, duration * bodyFrom), hi = min(duration - win - range - 0.5, duration * bodyTo - win)
        guard hi > lo else { return duration > 2 ? [Segment(start: 0, length: duration)] : [] }
        return (0..<points).map { i in Segment(start: lo + (hi - lo) * Double(i) / Double(max(1, points - 1)), length: win) }
    }

    /// Why the seeks start a QUARTER frame before the wanted frame, not half: ffmpeg drops the frames before `-ss` after
    /// converting it to the stream's time base (1/24 for a 24 fps MOV). Written with six decimals, (f0 − 0.5)/24 lands on
    /// either side of the rounding — 30465.499992 rounds down and frame 30465 comes out first, one frame too early —
    /// which moved every cut of some windows by a frame (seen on 2DIE4, 2026-11-04). (f0 − 0.25)/fps always rounds to f0.
    static let seekBefore = 0.25
    /// Hard cuts: a frame that differs a lot from the previous one while the next one doesn't (a flash fails that test)
    static func detectCuts(video: URL, index: Int, fps: Double, segments: [Segment], cancel: CancelFlag,
                           progress: (Double) -> Void) -> [Cut] {
        guard let ffmpeg = Tools.ffmpeg, fps > 0 else { return [] }
        let bytes = thumbW * thumbH
        var cuts: [Cut] = []
        for (k, seg) in segments.enumerated() {
            if cancel.isSet { break }
            let f0 = Int((seg.start * fps).rounded())
            let ss = (Double(f0) - seekBefore) / fps        // a quarter frame early: the first frame out is f0 (see `seekBefore`)
            let args = ["-nostdin", "-v", "error", "-ss", String(format: "%.6f", max(0, ss)), "-t", String(format: "%.6f", seg.length + 1 / fps),
                        "-i", video.path, "-map", "0:\(index)", "-fps_mode", "passthrough", "-vf", "scale=\(thumbW):\(thumbH):flags=area,format=gray",
                        "-f", "rawvideo", "-pix_fmt", "gray", "-"]
            guard let d = Tools.runCancellable(ffmpeg, args, cancel: cancel), d.count >= bytes * 3 else { continue }
            let n = d.count / bytes
            var diff = [Double](repeating: 0, count: n)
            d.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for i in 1..<n {
                    var acc = 0
                    let a = (i - 1) * bytes, b = i * bytes
                    for j in 0..<bytes { acc += abs(Int(p[b + j]) - Int(p[a + j])) }
                    diff[i] = Double(acc) / Double(bytes)
                }
            }
            let med = max(0.5, Fmt.median(Array(diff.dropFirst())))
            let floor = max(4, 3 * med)
            for i in 2..<(n - 1) {
                let v = diff[i]
                guard v >= floor, v >= 2 * diff[i - 1], v >= 2 * diff[i + 1] else { continue }
                cuts.append(Cut(time: Double(f0 + i) / fps, strength: v / med, segment: k))
            }
            progress(Double(k + 1) / Double(segments.count))
        }
        return cuts
    }

    /// How much the sound CHANGES at each instant: the band levels of the 150 ms after it against the 150 ms before it,
    /// every 2 ms. A cut to another scene changes the ambience abruptly (a sharp peak here); music that just carries on
    /// across a cut, or an engine passing, doesn't. `shift` reads the audio that will sit under this picture after a trim.
    static func onsets(_ src: SyncEngine.Source, segment: Segment, shift: Double = 0) -> OnsetCurve {
        let rate = 16000, hop = 32, win = 128, half = 75 /* hops = 150 ms */, pad = range + 0.2
        let start = segment.start - pad
        let x = WaveData.window(src, start: start + shift, length: segment.length + 2 * pad, rate: rate)
        let n = max(0, (x.count - win) / hop)
        guard n > 2 * half + 2 else { return OnsetCurve(start: start, hop: Double(hop) / Double(rate), values: []) }
        let edges = [1, 3, 5, 9, 17, 25, 37, 49, 64]       // 125 Hz bins: 0–250, –500, –1k, –2k, –3k, –4.5k, –6k, –8k
        let bands = edges.count - 1
        let log2n = vDSP_Length(7)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return OnsetCurve(start: start, hop: 0.002, values: []) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: win)
        vDSP_hann_window(&window, vDSP_Length(win), Int32(vDSP_HANN_NORM))
        var level = [Float](repeating: 0, count: n * bands)          // dB per band, frame-major
        var re = [Float](repeating: 0, count: win / 2), im = [Float](repeating: 0, count: win / 2)
        var frame = [Float](repeating: 0, count: win), mags = [Float](repeating: 0, count: win / 2)
        for f in 0..<n {
            let o = f * hop
            for i in 0..<win { frame[i] = x[o + i] * window[i] }
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: win / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(win / 2)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(win / 2))
            } }
            for bnd in 0..<bands {
                var e: Float = 0
                for k in edges[bnd]..<edges[bnd + 1] { e += mags[k] }
                level[f * bands + bnd] = 10 * log10(e / Float(edges[bnd + 1] - edges[bnd]) + 1e-9)
            }
        }
        // running sums per band → mean level before/after each frame in O(1)
        var cum = [Double](repeating: 0, count: (n + 1) * bands)
        for f in 0..<n { for bnd in 0..<bands { cum[(f + 1) * bands + bnd] = cum[f * bands + bnd] + Double(level[f * bands + bnd]) } }
        var nov = [Float](repeating: 0, count: n)
        for f in half..<(n - half) {
            var d = 0.0
            for bnd in 0..<bands {
                let before = (cum[f * bands + bnd] - cum[(f - half) * bands + bnd]) / Double(half)
                let after = (cum[(f + half) * bands + bnd] - cum[f * bands + bnd]) / Double(half)
                d += abs(after - before)
            }
            nov[f] = Float(d / Double(bands))                       // mean absolute band change, dB
        }
        return OnsetCurve(start: start, hop: Double(hop) / Double(rate), values: nov)
    }

    /// Where do the sound hits land relative to the picture cuts? The lag with the most rise under the cuts wins.
    static func match(cuts: [Cut], curves: [OnsetCurve], fps: Double, duration: Double = 0) -> Result {
        var r = Result(); r.cuts = cuts.count
        guard cuts.count >= 3 else { r.message = "Not enough hard cuts found in the picture (\(cuts.count))."; return r }
        let bins = Int(range * 2000) + 1                    // 1 ms steps
        func value(_ c: OnsetCurve, at t: Double) -> Double {
            let p = (t - c.start) / c.hop
            let i = Int(p.rounded(.down))
            guard i >= 0, i + 1 < c.values.count else { return 0 }
            let f = p - Double(i)
            return Double(c.values[i]) * (1 - f) + Double(c.values[i + 1]) * f
        }
        // each cut votes at its three strongest local peaks (a hit = a prominent rise ≥ 3 dB); the votes are spread ±4 ms
        var score = [Double](repeating: 0, count: bins)
        var perWindow: [Int: [Double]] = [:]                       // votes per window of the film, capped at 1 per lag
        var peaksPerCut: [[(lag: Double, rise: Double)]] = []
        let used = cuts.filter { $0.segment < curves.count }
        let ext = 200                                               // ms of context before the search range (for the echo test)
        for c in used {
            let cv = curves[c.segment]
            let v = (0..<(bins + ext)).map { value(cv, at: c.time + Double($0 - ext) / 1000 - range) }
            var peaks: [(lag: Double, rise: Double)] = []
            for b in (ext + 12)..<(bins + ext - 12) where v[b] >= 2 {
                var top = true
                for k in 1...12 where v[b - k] > v[b] || v[b + k] > v[b] { top = false; break }
                guard top else { continue }
                // a transition sound on a cut (a whoosh, a hit) ends ~150 ms after it starts, which this 150 ms measure
                // sees as a second change: drop a peak that has a comparable change 110–190 ms before it
                var echo = false
                for k in stride(from: -172, through: -136, by: 2) where v[b + k] >= 0.5 * v[b] { echo = true; break }
                if !echo { peaks.append((Double(b - ext) / 1000 - range, v[b])) }
            }
            peaks.sort { $0.rise > $1.rise }
            let chosen = Array(peaks.prefix(3))
            peaksPerCut.append(chosen)
            var sw = perWindow[c.segment] ?? [Double](repeating: 0, count: bins)
            for (rank, pk) in chosen.prefix(2).enumerated() {
                let w = [1.0, 0.5][rank] * min(1, max(0, pk.rise - 2) / 4)
                let center = Int(((pk.lag + range) * 1000).rounded())
                for d in -15...15 where center + d >= 0 && center + d < bins { sw[center + d] += w * (1 - Double(abs(d)) / 16) }
            }
            perWindow[c.segment] = sw
        }
        for (_, sw) in perWindow { for b in 0..<bins { score[b] += min(1, sw[b]) } }   // one window = at most one vote per lag
        r.curve = score
        // groups of hits = local maxima of the votes; maxima closer than a frame (≥ 30 ms) are one group
        var raw: [(lag: Double, value: Double)] = []
        let apart = max(0.03, 1 / fps)                // hits jitter within a frame around a cut
        for b in 1..<(bins - 1) where score[b] >= score[b - 1] && score[b] > score[b + 1] && score[b] > 0 {
            let lagB = Double(b) / 1000 - range
            if let i = raw.indices.last(where: { abs(raw[$0].lag - lagB) < apart }) {
                if score[b] > raw[i].value { raw[i] = (lagB, score[b]) }
            } else { raw.append((lagB, score[b])) }
        }
        raw.sort { $0.value > $1.value }
        guard let best = raw.first else { r.message = "No sound changes found under the cuts."; return r }
        let noise = max(0.05, Fmt.median(score))
        /// the cuts that agree with a group: their best change within ±12 ms of it
        func agreeing(_ g: Double) -> [(cut: Cut, hit: Hit)] {
            var out: [(cut: Cut, hit: Hit)] = []
            for (c, pk) in zip(used, peaksPerCut) {
                var bestPk: (lag: Double, rise: Double)? = nil
                for q in pk where abs(q.lag - g) <= 0.012 && q.rise >= 2 { if bestPk == nil || q.rise > bestPk!.rise { bestPk = q } }
                if let b = bestPk { out.append((c, Hit(cut: c.time, onset: c.time + b.lag, rise: b.rise))) }
            }
            return out
        }
        func group(_ g: (lag: Double, value: Double)) -> Group {
            let a = agreeing(g.lag)
            let lag = a.isEmpty ? g.lag : Fmt.median(a.map { $0.hit.onset - $0.hit.cut })
            var pts: [Hit] = []
            for h in a.map(\.hit).sorted(by: { $0.rise > $1.rise }) where pts.count < 12 {
                if pts.allSatisfy({ abs($0.cut - h.cut) >= 15 }) { pts.append(h) }
            }
            return Group(lag: lag, value: g.value, count: a.count, windows: Set(a.map(\.cut.segment)).count, points: pts.sorted { $0.cut < $1.cut })
        }
        r.peaks = peaksPerCut
        // the answer is the group that more DIFFERENT parts of the film agree with (a sync offset is global; archive
        // footage with its own sync, or a montage, is local), then the one with more cuts
        r.groups = raw.prefix(8).map(group).sorted { $0.windows != $1.windows ? $0.windows > $1.windows : ($0.count != $1.count ? $0.count > $1.count : $0.value > $1.value) }
        // the alignment meter: which of the film-wide candidates each window votes for on its own (a window that votes for
        // none of them, or barely, is left out), in film order — a sync offset is global, so only those lags are plausible
        var winPts: [Alignment.Point] = []
        let candidates = r.groups.prefix(5).map(\.lag)
        for (seg, sw) in perWindow {
            // the window's vote for each candidate; it counts only when one candidate clearly wins inside the window
            var votes: [(lag: Double, v: Double)] = []
            for g in candidates {
                let c = Int(((g + range) * 1000).rounded())
                var lag = g, v = 0.0
                for b in max(0, c - 12)...min(bins - 1, c + 12) where sw[b] > v { v = sw[b]; lag = Double(b) / 1000 - range }
                votes.append((lag, v))
            }
            votes.sort { $0.v > $1.v }
            guard let top = votes.first, top.v >= 1.0, votes.count < 2 || top.v >= 1.5 * votes[1].v else { continue }
            let bestLag = top.lag
            let times = used.filter { $0.segment == seg }.map(\.time)
            winPts.append(Alignment.Point(time: times.reduce(0, +) / Double(max(1, times.count)), lag: bestLag))
        }
        r.windows = winPts.sorted { $0.time < $1.time }
        let dur = duration > 0 ? duration : (used.map(\.time).max() ?? 0) + 30
        if let m = Alignment.measure(points: r.windows, applied: 0, fps: fps, duration: dur), m.spans.count > 1 { r.meter = m }
        let chosen = r.groups[0]
        let lag = chosen.lag
        let next = r.groups.count > 1 ? r.groups[1] : nil
        _ = noise
        r.ratio = Double(chosen.windows) / Double(max(1, next?.windows ?? 1))
        r.points = chosen.points
        let hits = agreeing(chosen.lag)
        let devs = hits.map { abs($0.hit.onset - $0.hit.cut - lag) * 1000 }
        r.hits = hits.count
        r.spreadMs = devs.isEmpty ? 0 : Fmt.median(devs)
        guard chosen.count >= 6, chosen.windows >= 4 else {
            r.message = String(format: "No clear match between picture cuts and sound changes (%d of %d cuts agree, from %d windows). Try more windows, or check the points by eye.", chosen.count, cuts.count, chosen.windows)
            if let m = r.meter { r.message += " · window by window: " + m.summary }
            return r
        }
        r.confident = r.ratio >= 1.3 && chosen.windows >= 6
        r.offset = lag
        r.frames = lag * fps
        let ms = lag * 1000
        let how = abs(ms) < 1 ? "in sync with the picture" : String(format: "the sound is %.1f ms %@ vs the picture (%.2f frame%@)", abs(ms), ms > 0 ? "LATE" : "EARLY", abs(lag * fps), abs(lag * fps) == 1 ? "" : "s")
        r.message = String(format: "%@ · %d of %d cuts agree, from %d of the film's %d windows · spread ±%.0f ms", how, chosen.count, cuts.count, chosen.windows, curves.count, r.spreadMs)
        if let n = next, Double(n.windows) >= 0.7 * Double(chosen.windows) {
            r.message += String(format: " · another group of %d cuts (in %d windows) sits at %+.0f ms (%.1f frames): compare the two by eye", n.count, n.windows, n.lag * 1000, abs(n.lag * fps))
        } else if !r.confident { r.message += " · a thin margin: confirm by eye on the check points" }
        if let m = r.meter { r.message += " · window by window: " + m.summary }
        return r
    }

    /// One audio source against one picture, start to finish
    static func measure(video: URL, videoIndex: Int, fps: Double, audio: SyncEngine.Source, shift: Double = 0, duration: Double,
                        points: Int = 15, window: Double = 30, cancel: CancelFlag, progress: (String, Double) -> Void) -> Result {
        let segs = segments(duration: duration, points: points, window: window)
        let cuts = detectCuts(video: video, index: videoIndex, fps: fps, segments: segs, cancel: cancel) { progress("Finding hard cuts in the picture…", $0 * 0.8) }
        if cancel.isSet { var r = Result(); r.message = "Cancelled."; return r }
        let curves = curvesFor(audio, segments: segs, shift: shift)
        progress("Matching sound hits to the cuts…", 0.95)
        return match(cuts: cuts, curves: curves, fps: fps, duration: duration)
    }

    static func curvesFor(_ src: SyncEngine.Source, segments: [Segment], shift: Double) -> [OnsetCurve] {
        var out = [OnsetCurve?](repeating: nil, count: segments.count)
        let lock = NSLock(), gate = DispatchSemaphore(value: 4)     // a few ffmpeg decodes at a time
        DispatchQueue.concurrentPerform(iterations: segments.count) { i in
            gate.wait(); defer { gate.signal() }
            let c = onsets(src, segment: segments[i], shift: shift)
            lock.lock(); out[i] = c; lock.unlock()
        }
        return out.map { $0 ?? OnsetCurve(start: 0, hop: 0.002, values: []) }
    }

    /// Small RGB frames, letterboxed to a fixed size, from `firstFrame` on
    static func thumbnails(video: URL, index: Int, fps: Double, firstFrame: Int, count: Int, width: Int = 256, height: Int = 144) -> [CGImage] {
        guard let ffmpeg = Tools.ffmpeg, fps > 0, count > 0 else { return [] }
        let ss = (Double(max(0, firstFrame)) - seekBefore) / fps   // a quarter frame early (see `seekBefore`)
        let vf = "scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,format=rgb24"
        let args = ["-nostdin", "-v", "error", "-ss", String(format: "%.6f", max(0, ss)), "-i", video.path, "-map", "0:\(index)",
                    "-fps_mode", "passthrough", "-frames:v", "\(count)", "-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
        guard let d = Tools.runSync(ffmpeg, args) else { return [] }
        let bytes = width * height * 3
        var out: [CGImage] = []
        for i in 0..<(d.count / bytes) {
            let slice = d.subdata(in: i * bytes..<(i + 1) * bytes)
            guard let provider = CGDataProvider(data: slice as CFData),
                  let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            out.append(img)
        }
        return out
    }

    static func fps(of streams: [ProbeStream]) -> Double {
        let v = streams.first { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }
        return v.flatMap { Rational($0.r_frame_rate ?? $0.avg_frame_rate ?? "")?.value } ?? 24
    }
}

// MARK: - Model

@Observable
final class PictureSyncModel: Identifiable {
    /// one sound to check against the picture
    struct Lane: Identifiable {
        let id = UUID()
        let label: String
        let src: SyncEngine.Source
        var shift: Double              // audio source time = picture time + shift (the trim that will be applied)
        let fileAudioIndex: Int        // which audio track of its file (for AVFoundation)
        let playable: Bool
        var result: PictureSync.Result?
        var members: [(url: URL, audioIndex: Int)] = []   // a mono group: every member plays together (MonoGroup.swift)
    }
    let project: Project
    let picture: URL
    let pictureIndex: Int
    let fps: Double
    let duration: Double
    let isOutput: Bool                 // a muxed file (play it as is) or the project (video + audio from different files)
    var lanes: [Lane] = []
    var targetID: UUID?                // project mode: the track under test
    var after = true                   // project mode: the track as it will be muxed, or as delivered
    var measuring = false
    var stage = ""
    var progress = 0.0
    var points: [PictureSync.Hit] = []
    var selected = 0
    var selectedGroup = 0              // which group of the played lane's result the check points come from
    var thumbs: [CGImage] = []
    var refEnv = WaveEnvelope()
    var candEnv = WaveEnvelope()
    var loadingView = false
    var playLane = 0                   // which lane's sound plays
    var player: AVQueuePlayer?
    var playing = false
    var slow = false
    var playheadMs: Double?            // where the player is, relative to the cut
    var playerNote = ""
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var cuts: [PictureSync.Cut] = []
    @ObservationIgnored private var segs: [PictureSync.Segment] = []
    @ObservationIgnored private var cancelFlag = CancelFlag()
    @ObservationIgnored private var generation = 0
    static let frameSpan = 4           // frames shown on each side of the cut

    /// Project mode: the project's video, its reference audio and one track to test
    init?(project: Project, target: Track?) {
        guard let v = project.videoTrack else { return nil }
        self.project = project
        picture = v.url; pictureIndex = v.streamIndex; isOutput = false
        fps = max(1, project.videoFPS.value)
        duration = v.duration > 0 ? v.duration : project.videoDuration
        targetID = target?.id
        rebuildLanes()
    }

    /// Output mode: a muxed file — its own picture and every audio track in it
    init?(project: Project, output: URL) {
        let streams = Probe.raw(output)?.streams ?? []
        guard let v = streams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) else { return nil }
        self.project = project
        picture = output; pictureIndex = v.index; isOutput = true
        fps = PictureSync.fps(of: streams)
        let audios = streams.filter { $0.codec_type == "audio" }
        let dur = audios.compactMap { Double($0.duration ?? "") }.min() ?? Double(v.duration ?? "") ?? 0
        duration = dur
        var list: [Lane] = []
        for (k, s) in audios.enumerated() {
            let name = s.tags?["title"] ?? s.codec_name?.uppercased() ?? "Audio \(k + 1)"
            let ch = s.channels.map { "\($0) ch" } ?? ""
            let label = "\(name) · \(s.codec_name ?? "") \(ch)"
            let src = SyncEngine.Source(url: output, index: s.index, duration: Double(s.duration ?? "") ?? dur, channels: s.channels ?? 2)
            list.append(Lane(label: label, src: src, shift: 0, fileAudioIndex: k, playable: true, result: nil))
        }
        lanes = list
    }

    var target: Track? { project.tracks.first { $0.id == targetID } }
    var targets: [Track] { project.tracks.filter { $0.kind == .audio && $0.include && $0.id != project.syncReferenceID } }
    var halfWidth: Double { Double(Self.frameSpan) / fps }
    var cut: Double? { points.indices.contains(selected) ? points[selected].cut : nil }
    var referenceLane: Lane? { isOutput ? nil : lanes.first }
    var targetLane: Lane? { isOutput ? nil : (lanes.count > 1 ? lanes[1] : nil) }
    var hasMeasurement: Bool { lanes.contains { $0.result != nil } }

    static func audioIndexInFile(_ t: Track) -> Int {
        let streams = Probe.raw(t.url)?.streams ?? []
        return streams.filter { $0.codec_type == "audio" && $0.index < t.streamIndex }.count
    }
    /// The members of a mono group as (file, audio track in that file), for playback
    static func memberAudio(_ t: Track) -> [(url: URL, audioIndex: Int)] {
        guard t.isGroup else { return [] }
        var cache: [String: [ProbeStream]] = [:]
        return t.members.map { m in
            let streams = cache[m.url.path] ?? (Probe.raw(m.url)?.streams ?? [])
            cache[m.url.path] = streams
            return (m.url, streams.filter { $0.codec_type == "audio" && $0.index < m.streamIndex }.count)
        }
    }

    /// what the trim moves the track by (s): positive = the source is read later
    func shift(of t: Track) -> Double {
        guard after, let p = project.plan(for: t), t.sampleRate > 0 else { return 0 }
        return Double(p.cut - p.pad) / t.sampleRate   // (E-AC-3: the plan already cuts whole Dolby frames and delays the rest)
    }

    func rebuildLanes() {
        guard !isOutput else { return }
        var new: [Lane] = []
        if let r = project.reference {
            new.append(Lane(label: "REFERENCE · \(r.title) (\(r.fromVideoFile ? "the video's own audio" : r.isGroup ? "\(r.members.count) mono files" : r.url.lastPathComponent))",
                            src: SyncViewerModel.source(r), shift: 0, fileAudioIndex: Self.audioIndexInFile(r), playable: true,
                            result: lanes.first(where: { $0.label.hasPrefix("REFERENCE") })?.result, members: Self.memberAudio(r)))
        }
        if let t = target {
            let raw = ["eac3", "truehd", "ac3"].contains(t.codecKey) && !t.fromVideoFile   // AVFoundation can't open raw Dolby elementary streams
            new.append(Lane(label: "\(t.title) · \(after ? "after alignment (as it will be muxed)" : "before alignment (as delivered)")",
                            src: SyncViewerModel.source(t), shift: shift(of: t), fileAudioIndex: Self.audioIndexInFile(t), playable: !raw, result: nil,
                            members: Self.memberAudio(t)))
        }
        lanes = new
    }

    // MARK: measuring

    func measure() {
        guard !measuring, !lanes.isEmpty else { return }
        measuring = true; stage = "Starting…"; progress = 0
        let flag = CancelFlag(); cancelFlag = flag
        let segsNeeded = cuts.isEmpty
        let pic = picture, idx = pictureIndex, f = fps, dur = duration
        let laneCopies = lanes
        let laneKeys = lanes.map { "\($0.label)|\($0.shift)" }
        let haveCuts = cuts, haveSegs = segs
        DispatchQueue.global(qos: .userInitiated).async {
            var cs = haveCuts, sg = haveSegs
            if segsNeeded {
                sg = PictureSync.segments(duration: dur, points: 30, window: 30)
                cs = PictureSync.detectCuts(video: pic, index: idx, fps: f, segments: sg, cancel: flag) { p in
                    DispatchQueue.main.async { self.stage = "Finding hard cuts in the picture…"; self.progress = p * 0.75 }
                }
            }
            var results: [PictureSync.Result] = []
            for (k, lane) in laneCopies.enumerated() {
                if flag.isSet { break }
                DispatchQueue.main.async { self.stage = "Finding sound hits: \(lane.label)…"; self.progress = 0.75 + 0.25 * Double(k) / Double(laneCopies.count) }
                let curves = PictureSync.curvesFor(lane.src, segments: sg, shift: lane.shift)
                results.append(PictureSync.match(cuts: cs, curves: curves, fps: f))
            }
            DispatchQueue.main.async {
                guard !flag.isSet else { self.measuring = false; self.stage = ""; return }
                self.cuts = cs; self.segs = sg
                // the lanes may have been rebuilt meanwhile (another track, before/after): a result only goes to the lane it measured
                for (k, r) in results.enumerated() where k < self.lanes.count && k < laneKeys.count && "\(self.lanes[k].label)|\(self.lanes[k].shift)" == laneKeys[k] { self.lanes[k].result = r }
                self.selectedGroup = 0
                self.points = self.groupPoints()
                self.measuring = false; self.stage = ""; self.progress = 1
                self.selected = min(self.selected, max(0, self.points.count - 1))
                self.showPoint()
            }
        }
    }

    func cancel() { cancelFlag.set() }

    /// the trim changed (nudge, stepper…): re-read only the sound, the cuts are known
    func refreshTarget() {
        rebuildLanes()
        if !cuts.isEmpty { measure() } else { showPoint() }
    }

    /// Project mode: the stepper value this measurement suggests
    var suggestedLag: Double? {
        guard let r = referenceLane?.result, r.offset != nil, r.confident else { return nil }
        return r.groups.indices.contains(selectedGroup) && playLane == 0 ? r.groups[selectedGroup].lag : r.offset
    }
    var suggestedFrames: Int? {
        guard let o = suggestedLag else { return nil }
        let f = Int((o * fps).rounded())
        return f == Int(project.referenceLateFrames) ? nil : f
    }

    func applySuggestion() {
        guard let f = suggestedFrames else { return }
        project.referenceLateFrames = Double(f)
        refreshTarget()
    }

    // MARK: the moment on screen

    func showPoint() {
        generation += 1
        let g = generation
        guard let c = cut else { thumbs = []; refEnv = WaveEnvelope(); candEnv = WaveEnvelope(); return }
        loadingView = true
        let pic = picture, idx = pictureIndex, f = fps, half = halfWidth, lanesNow = lanes
        let first = Int((c * f).rounded()) - Self.frameSpan
        DispatchQueue.global(qos: .userInitiated).async {
            var th: [CGImage] = [], a: [Float] = [], b: [Float] = []
            let group = DispatchGroup()
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                th = PictureSync.thumbnails(video: pic, index: idx, fps: f, firstFrame: first, count: Self.frameSpan * 2)
            }
            if let l = lanesNow.first { a = WaveData.window(l.src, start: c - half + l.shift, length: half * 2, rate: 48000) }
            if lanesNow.count > 1 { b = WaveData.window(lanesNow[1].src, start: c - half + lanesNow[1].shift, length: half * 2, rate: 48000) }
            group.wait()
            let ea = WaveData.envelope(a, columns: 1200), eb = WaveData.envelope(b, columns: 1200)
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                self.thumbs = th; self.refEnv = ea; self.candEnv = eb; self.loadingView = false
                self.buildPlayer()
            }
        }
    }

    func select(_ i: Int) { selected = i; showPoint() }

    /// the result whose groups are offered: the lane being played (or the first one measured)
    var shownResult: PictureSync.Result? { (lanes.indices.contains(playLane) ? lanes[playLane].result : nil) ?? lanes.compactMap(\.result).first }
    func groupPoints() -> [PictureSync.Hit] {
        guard let r = shownResult, !r.groups.isEmpty else { return [] }
        return r.groups[min(selectedGroup, r.groups.count - 1)].points
    }
    func selectGroup(_ i: Int) { selectedGroup = i; points = groupPoints(); selected = 0; showPoint() }

    // MARK: playback (a 2-second loop around the cut)

    static let loopBefore = 1.0, loopAfter = 1.0

    func buildPlayer() {
        stopPlayer()
        guard let c = cut, lanes.indices.contains(playLane) else { return }
        let lane = lanes[playLane]
        guard lane.playable else { playerNote = "This track can't be played on its own (raw Dolby stream). Mux first and check the muxed file, or play the reference."; return }
        let start = max(0, c - Self.loopBefore), length = Self.loopBefore + Self.loopAfter
        let ts: CMTimeScale = 48000
        playerNote = ""
        let pic = picture, isOut = isOutput
        Task { @MainActor in
            do {
                let item: AVPlayerItem
                if isOut {
                    let asset = AVURLAsset(url: pic)
                    item = AVPlayerItem(asset: asset)
                    if let group = try await asset.loadMediaSelectionGroup(for: .audible), lane.fileAudioIndex < group.options.count {
                        item.select(group.options[lane.fileAudioIndex], in: group)
                    }
                } else {
                    let comp = AVMutableComposition()
                    let vAsset = AVURLAsset(url: pic)
                    guard let vt = try await vAsset.loadTracks(withMediaType: .video).first else { playerNote = "The picture can't be played by AVFoundation (MXF?)."; return }
                    let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: ts), duration: CMTime(seconds: length, preferredTimescale: ts))
                    let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    try cv?.insertTimeRange(range, of: vt, at: .zero)
                    cv?.preferredTransform = try await vt.load(.preferredTransform)
                    // a mono group plays every member together (one composition track each)
                    let parts: [(url: URL, audioIndex: Int)] = lane.members.isEmpty ? [(lane.src.url, lane.fileAudioIndex)] : lane.members
                    for part in parts {
                        let aAsset = AVURLAsset(url: part.url)
                        let aTracks = try await aAsset.loadTracks(withMediaType: .audio)
                        guard part.audioIndex < aTracks.count else { playerNote = "The audio can't be opened by AVFoundation."; return }
                        let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        let srcStart = start + lane.shift
                        if srcStart >= 0 {
                            try ca?.insertTimeRange(CMTimeRange(start: CMTime(seconds: srcStart, preferredTimescale: ts), duration: range.duration), of: aTracks[part.audioIndex], at: .zero)
                        } else {   // silence first, then the audio from its start
                            let lead = CMTime(seconds: -srcStart, preferredTimescale: ts)
                            try ca?.insertTimeRange(CMTimeRange(start: .zero, duration: range.duration - lead), of: aTracks[part.audioIndex], at: lead)
                        }
                    }
                    item = AVPlayerItem(asset: comp)
                }
                let p = AVQueuePlayer()
                p.volume = 1
                let loopRange = isOut ? CMTimeRange(start: CMTime(seconds: start, preferredTimescale: ts), duration: CMTime(seconds: length, preferredTimescale: ts)) : .invalid
                looper = loopRange.isValid ? AVPlayerLooper(player: p, templateItem: item, timeRange: loopRange) : AVPlayerLooper(player: p, templateItem: item)
                let cutInItem = isOut ? c : c - start
                observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 120), queue: .main) { [weak self] t in
                    guard let self else { return }
                    self.playheadMs = (t.seconds - cutInItem) * 1000
                    self.playing = p.rate != 0
                }
                player = p
                if isOut { await p.seek(to: CMTime(seconds: start, preferredTimescale: ts), toleranceBefore: .zero, toleranceAfter: .zero) }
            } catch {
                playerNote = "Can't build the preview: \(error.localizedDescription)"
            }
        }
    }

    func togglePlay() {
        guard let p = player else { return }
        if p.rate != 0 { p.pause(); playing = false } else { p.rate = slow ? 0.5 : 1; playing = true }
    }
    func step(_ n: Int) {
        guard let p = player else { return }
        p.pause(); playing = false
        p.currentItem?.step(byCount: n)
    }
    func setSlow(_ s: Bool) { slow = s; if let p = player, p.rate != 0 { p.rate = s ? 0.5 : 1 } }
    func stopPlayer() {
        if let p = player { p.pause(); if let o = observer { p.removeTimeObserver(o) } }
        observer = nil; looper = nil; player = nil; playing = false; playheadMs = nil
    }
}

// MARK: - Views

struct PictureSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: PictureSyncModel
    var standalone = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Picture Sync Check", subtitle: model.picture.lastPathComponent) {
                if !model.isOutput, model.targets.count > 1 {
                    Picker("", selection: Binding(get: { model.targetID }, set: { model.targetID = $0; model.refreshTarget() })) {
                        ForEach(model.targets) { t in
                            Text(model.targets.count > 4 ? "\(t.title) · \(t.url.lastPathComponent)" : t.title).tag(Optional(t.id))
                        }
                    }
                    .headerPickerStyle(count: model.targets.count).labelsHidden().frame(maxWidth: 420).disabled(model.measuring)
                }
                if model.measuring {
                    ProgressView(value: model.progress).frame(width: 160)
                    Text(model.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Stop") { model.cancel() }
                } else {
                    Button(model.hasMeasurement ? "Measure Again" : "Measure") { model.measure() }.buttonStyle(.borderedProminent)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    Text("This checks the sound against the picture itself, not against another audio track: hard cuts in the image are found in 30 windows of 30 s spread over the body of the film (5%–80%: studio logos, title cards and end credits are left out, they are often out of sync on their own), the changes of sound are found under them, and the offset at which the sound changes land on the cuts is measured to the millisecond. Below, the frames around one cut with the waveform under them — press Play to loop that moment and judge it by ear.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    HStack(alignment: .top, spacing: DS.gap) {
                        GroupBox { playerCard }.groupBoxStyle(.inset).frame(width: 628)
                        GroupBox("Measured against the picture") { verdictCard }.groupBoxStyle(.inset).frame(maxWidth: .infinity)
                    }
                    GroupBox { momentCard }.groupBoxStyle(.inset)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            if !standalone {
                SheetButtons {
                    Button("Done") { model.stopPlayer(); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: DS.sheet(1280, standalone ? 1060 : 980).width, height: DS.sheet(1280, standalone ? 1060 : 980).height)
        .onAppear { if !standalone && !model.hasMeasurement { model.measure() } }
        .onDisappear { model.stopPlayer() }
    }

    var verdictCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.lanes.isEmpty { Text("No audio to check.").foregroundStyle(.secondary) }
            ForEach(model.lanes) { lane in
                VStack(alignment: .leading, spacing: 3) {
                    Text(lane.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    if let r = lane.result {
                        let ms = (r.offset ?? 0) * 1000
                        let ok = r.offset != nil && r.confident && ms >= -15 && ms <= 45
                        Label {
                            Text(r.message).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: r.offset == nil ? "questionmark.circle" : ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(r.offset == nil ? Color.secondary : ok ? Color.green : Color.orange)
                        }
                    } else {
                        Text(model.measuring ? "Measuring…" : "Not measured yet.").foregroundStyle(.secondary)
                    }
                }
            }
            if let f = model.suggestedFrames, let o = model.suggestedLag {
                VStack(alignment: .leading, spacing: 4) {
                    Button(String(format: "Use %d frame%@ (%+.1f ms) in the Sync section", f, abs(f) == 1 ? "" : "s", o * 1000)) { model.applySuggestion() }
                        .buttonStyle(.borderedProminent).tint(.orange)
                    Text("Sets “The reference is N frames late vs its picture” and moves every trim.").font(.caption).foregroundStyle(.secondary)
                }
            } else if !model.isOutput, model.referenceLane?.result?.offset != nil {
                Label("The Sync section already has this value (\(Int(model.project.referenceLateFrames)) frame\(abs(model.project.referenceLateFrames) == 1 ? "" : "s")).", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            }
            if let r = model.shownResult, !r.curve.isEmpty {
                if r.groups.count > 1 {
                    HStack(spacing: 8) {
                        Text("Groups of cuts").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { min(model.selectedGroup, r.groups.count - 1) }, set: { model.selectGroup($0) })) {
                            ForEach(Array(r.groups.prefix(4).enumerated()), id: \.offset) { i, g in
                                Text(String(format: "%+.0f ms · %d cuts / %d win", g.lag * 1000, g.count, g.windows)).tag(i)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    Text("The first group is the answer; the others are cuts whose sound sits elsewhere (archive footage with its own sync, music montages). Pick one to see its cuts below.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                LagChart(result: r, fps: model.fps).frame(height: 110)
                Text("Where the sound hits land relative to the picture cuts, over all cuts found (0 = on the cut, + = after it). A single sharp peak means the sound follows the cuts at one fixed offset.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var playerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let p = model.player, !standalone {
                    VideoPlayer(player: p).frame(height: 338)
                } else {
                    Rectangle().fill(Color.black).frame(height: 338)
                    Text(model.playerNote.isEmpty ? (model.cut == nil ? "Measure first — the check points come from the measurement." : "Preparing the preview…") : model.playerNote)
                        .font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                Button { model.togglePlay() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }
                    .disabled(model.player == nil).keyboardShortcut(.space, modifiers: [])
                Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }.help("One frame back").disabled(model.player == nil)
                Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }.help("One frame forward").disabled(model.player == nil)
                Toggle("½× speed", isOn: Binding(get: { model.slow }, set: { model.setSlow($0) })).toggleStyle(.checkbox)
                Spacer()
                if let ms = model.playheadMs {
                    Text(String(format: "%+.0f ms · %+.1f fr", ms, ms / 1000 * model.fps)).font(.system(.callout, design: .monospaced))
                        .foregroundStyle(abs(ms) < 1000 / model.fps / 2 ? Color.red : Color.primary)
                        .help("Player position relative to the cut")
                }
            }
            HStack(spacing: 8) {
                Text("Sound").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { model.playLane }, set: { model.playLane = $0; model.selectedGroup = 0; model.points = model.groupPoints(); model.selected = 0; model.showPoint() })) {
                    ForEach(Array(model.lanes.enumerated()), id: \.offset) { i, l in Text(shortLabel(l.label)).tag(i) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if !model.isOutput {
                    Picker("", selection: Binding(get: { model.after }, set: { model.after = $0; model.refreshTarget() })) {
                        Text("After alignment").tag(true); Text("Before").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200).disabled(model.measuring)
                }
            }
            Text("Loops 1 s before to 1 s after the cut. The frame counter turns red on the cut frame; the sound should hit when the picture changes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func shortLabel(_ s: String) -> String { s.hasPrefix("REFERENCE") ? "Reference" : String(s.split(separator: "·").first ?? Substring(s)).trimmingCharacters(in: .whitespaces) }

    var momentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(model.cut.map { "Cut at \(Fmt.duration($0)) — frames −\(PictureSyncModel.frameSpan)…+\(PictureSyncModel.frameSpan - 1) and the sound under them" } ?? "Frames around a cut").font(.headline)
                Spacer()
                if model.loadingView { ProgressView().controlSize(.small) }
                Text("Check points").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.points.enumerated()), id: \.offset) { i, h in
                            Button("\(i + 1) · \(Fmt.duration(h.cut).dropLast(4))") { model.select(i) }
                                .buttonStyle(.bordered).controlSize(.small).tint(i == model.selected ? Color.accentColor : nil)
                                .help(String(format: "hit %.0f dB, %+.0f ms from the cut", h.rise, (h.onset - h.cut) * 1000))
                        }
                    }
                }
                .frame(maxWidth: 620)
            }
            GeometryReader { geo in
                let w = geo.size.width / CGFloat(PictureSyncModel.frameSpan * 2)
                HStack(spacing: 0) {
                    ForEach(0..<(PictureSyncModel.frameSpan * 2), id: \.self) { i in
                        ZStack(alignment: .topLeading) {
                            if i < model.thumbs.count { Image(decorative: model.thumbs[i], scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fit) }
                            else { Rectangle().fill(Color.black.opacity(0.6)) }
                            Text(i - PictureSyncModel.frameSpan >= 0 ? "+\(i - PictureSyncModel.frameSpan)" : "\(i - PictureSyncModel.frameSpan)")
                                .font(.system(.caption2, design: .monospaced)).foregroundColor(.white).padding(3)
                                .background(i == PictureSyncModel.frameSpan ? Color.red.opacity(0.85) : Color.black.opacity(0.5)).padding(3)
                        }
                        .frame(width: w)
                        .overlay(alignment: .leading) { if i == PictureSyncModel.frameSpan { Rectangle().fill(Color.red).frame(width: 2) } }
                    }
                }
            }
            .frame(height: 1200 / CGFloat(PictureSyncModel.frameSpan * 2) * 9 / 16)
            WaveLanes(ref: model.refEnv, cand: model.candEnv, overlay: false, halfWidth: model.halfWidth, fps: model.fps,
                      refLabel: model.lanes.first?.label ?? "", candLabel: model.lanes.count > 1 ? model.lanes[1].label : "",
                      marker: markerFor(model.lanes.count > 1 ? model.lanes[1] : nil), markerLabel: markerLabel)
                .frame(height: 230)
                .background(DS.scope, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("The red line is the cut: the first frame of the new shot starts there. A sound that belongs to the cut should start on that line. Each grid column is one frame.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func markerFor(_ lane: PictureSyncModel.Lane?) -> Double? { lane?.result?.offset }
    var markerLabel: String {
        guard let l = model.lanes.count > 1 ? model.lanes[1] : nil, let o = l.result?.offset else { return "" }
        return abs(o) < 0.001 ? "in sync with the picture" : String(format: "sound %.1f ms %@ the cut (%.2f fr)", abs(o) * 1000, o > 0 ? "after" : "before", abs(o) * model.fps)
    }
}

/// Match score per lag: where the sound hits sit relative to the cuts
struct LagChart: View {
    let result: PictureSync.Result
    let fps: Double
    var body: some View {
        Canvas { ctx, size in
            let c = result.curve
            guard let mx = c.max(), mx > 0, c.count > 1 else { return }
            let range = PictureSync.range
            func x(_ s: Double) -> CGFloat { CGFloat((s + range) / (2 * range)) * size.width }
            let plotH = size.height - 14
            // frame grid
            var f = -(range * fps).rounded(.down) / fps
            while f <= range {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(f), y: 0)); $0.addLine(to: CGPoint(x: x(f), y: plotH)) }, with: .color(.secondary.opacity(abs(f) < 1e-9 ? 0.7 : 0.15)), lineWidth: abs(f) < 1e-9 ? 1.5 : 1)
                f += 1 / fps
            }
            var p = Path()
            for (i, v) in c.enumerated() {
                let pt = CGPoint(x: CGFloat(i) / CGFloat(c.count - 1) * size.width, y: plotH - CGFloat(v / mx) * (plotH - 4))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Color.accentColor), lineWidth: 1.5)
            if let o = result.offset {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(o), y: 0)); $0.addLine(to: CGPoint(x: x(o), y: plotH)) }, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                ctx.draw(Text(String(format: "%+.1f ms", o * 1000)).font(.caption2.weight(.semibold)).foregroundColor(.orange),
                         at: CGPoint(x: x(o) + (o > 0.15 ? -4 : 4), y: 2), anchor: o > 0.15 ? .topTrailing : .topLeading)
            }
            for (s, label) in [(-range, String(format: "−%.0f ms", range * 1000)), (0.0, "cut"), (range, String(format: "+%.0f ms", range * 1000))] {
                ctx.draw(Text(label).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary),
                         at: CGPoint(x: s < 0 ? 0 : s > 0 ? size.width : x(0), y: size.height), anchor: s < 0 ? .bottomLeading : s > 0 ? .bottomTrailing : .bottom)
            }
        }
    }
}
