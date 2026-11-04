// BROS-MUX — which channel is which. Listens to a multichannel PCM track and tells L, R, C, LFE, Ls, Rs apart from the
// sound alone: the LFE is the channel with nothing above the subwoofer band; the front pair are the two loud channels
// that move together; the centre is the one that carries speech (speech-band energy modulated at syllable rate);
// the surrounds are the remaining pair. Which of a pair is the left one cannot be heard — it is taken from the file
// order, and the report says so. Reordering is done by permuting whole samples inside each block of the WAV copy, so
// the audio data is never touched.

import Foundation
import Accelerate

enum ChannelRole: String, CaseIterable, Identifiable, Codable {
    case L, R, C, LFE, Ls, Rs, Lrs, Rrs, M
    var id: String { rawValue }
    var name: String {
        switch self {
        case .L: return "Left"; case .R: return "Right"; case .C: return "Centre"; case .LFE: return "LFE (subwoofer)"
        case .Ls: return "Left surround"; case .Rs: return "Right surround"; case .Lrs: return "Left rear surround"; case .Rrs: return "Right rear surround"
        case .M: return "Mono"
        }
    }
}

/// An order of channel roles, as the channels sit in a file
struct ChannelOrder: Equatable, Hashable, Identifiable {
    let roles: [ChannelRole]
    var id: String { text }
    var count: Int { roles.count }
    var text: String { roles.map(\.rawValue).joined(separator: " ") }
    var isComplete: Bool { Set(roles).count == roles.count }

    struct Preset: Identifiable { let name: String; let order: ChannelOrder; var id: String { order.text } }

    /// The conventions worth offering for a channel count
    static func presets(channels: Int) -> [Preset] {
        switch channels {
        case 2: return [Preset(name: "Stereo", order: ChannelOrder(roles: [.L, .R]))]
        case 6: return [
            Preset(name: "SMPTE / ITU (WAV, QuickTime, Academy)", order: ChannelOrder(roles: [.L, .R, .C, .LFE, .Ls, .Rs])),
            Preset(name: "Film / Pro Tools", order: ChannelOrder(roles: [.L, .C, .R, .Ls, .Rs, .LFE])),
            Preset(name: "L C R LFE Ls Rs", order: ChannelOrder(roles: [.L, .C, .R, .LFE, .Ls, .Rs])),
            Preset(name: "DTS", order: ChannelOrder(roles: [.L, .R, .Ls, .Rs, .C, .LFE])),
            Preset(name: "C L R Ls Rs LFE", order: ChannelOrder(roles: [.C, .L, .R, .Ls, .Rs, .LFE])),
        ]
        case 8: return [
            Preset(name: "SMPTE / ITU 7.1", order: ChannelOrder(roles: [.L, .R, .C, .LFE, .Ls, .Rs, .Lrs, .Rrs])),
            Preset(name: "Film / Pro Tools 7.1", order: ChannelOrder(roles: [.L, .C, .R, .Ls, .Rs, .Lrs, .Rrs, .LFE])),
        ]
        case 5: return [
            Preset(name: "SMPTE 5.0", order: ChannelOrder(roles: [.L, .R, .C, .Ls, .Rs])),
            Preset(name: "Film 5.0", order: ChannelOrder(roles: [.L, .C, .R, .Ls, .Rs])),
        ]
        case 3: return [Preset(name: "L R C", order: ChannelOrder(roles: [.L, .R, .C])), Preset(name: "L C R", order: ChannelOrder(roles: [.L, .C, .R]))]
        default: return []
        }
    }
    var presetName: String? { Self.presets(channels: count).first { $0.order == self }?.name }
    var label: String { presetName.map { "\(text)  (\($0))" } ?? text }

    /// Apple AudioChannelLayoutTag that describes exactly this order, when one exists (written into the 'chan' atom)
    var layoutTag: UInt32? {
        switch roles {
        case [.M]: return 0x0064_0001                                   // Mono
        case [.L, .R]: return 0x0065_0002                               // Stereo
        case [.L, .R, .C, .LFE, .Ls, .Rs]: return 0x0079_0006           // MPEG_5_1_A
        case [.L, .R, .Ls, .Rs, .C, .LFE]: return 0x007A_0006           // MPEG_5_1_B
        case [.L, .C, .R, .Ls, .Rs, .LFE]: return 0x007B_0006           // MPEG_5_1_C
        case [.C, .L, .R, .Ls, .Rs, .LFE]: return 0x007C_0006           // MPEG_5_1_D
        case [.L, .R, .C, .LFE, .Ls, .Rs, .Lrs, .Rrs]: return 0x0080_0008   // MPEG_7_1_C
        default: return nil
        }
    }
    static func layoutName(_ tag: UInt32) -> String? {
        let all: [ChannelOrder] = [ChannelOrder(roles: [.M]), ChannelOrder(roles: [.L, .R]), ChannelOrder(roles: [.L, .R, .C, .LFE, .Ls, .Rs]),
                                   ChannelOrder(roles: [.L, .R, .Ls, .Rs, .C, .LFE]), ChannelOrder(roles: [.L, .C, .R, .Ls, .Rs, .LFE]),
                                   ChannelOrder(roles: [.C, .L, .R, .Ls, .Rs, .LFE]), ChannelOrder(roles: [.L, .R, .C, .LFE, .Ls, .Rs, .Lrs, .Rrs])]
        return all.first { $0.layoutTag == tag }?.text
    }

    /// Whether this order can be written from `source`: same channel count, every role used once on both sides, same roles
    func canBeWritten(from source: ChannelOrder) -> Bool {
        source.count == count && source.isComplete && isComplete && Set(source.roles) == Set(roles)
    }
    /// Output channel k takes source channel permutation[k]; nil when a role is missing or the order is the same
    func permutation(from source: ChannelOrder) -> [Int]? {
        guard source.count == count, source.isComplete, isComplete, Set(source.roles) == Set(roles) else { return nil }
        let p = roles.map { r in source.roles.firstIndex(of: r)! }
        return p == Array(0..<count) ? nil : p
    }
}

enum ChannelID {
    struct Features {
        var level = -120.0        // dBFS RMS over the active windows
        var low = 0.0             // share of the energy below 120 Hz
        var speech = 0.0          // share of the energy in 300–3400 Hz
        var high = 0.0            // share of the energy above 4 kHz
        var modulation = 0.0      // share of the speech-band envelope modulation that sits at syllable rate (3–8 Hz)
        var zeros = 0.0           // share of samples that are exactly zero
        var active = 0            // windows where the channel had signal
    }
    struct Guess: Identifiable {
        let channel: Int
        let role: ChannelRole
        let confidence: Double    // 0–1
        let why: String
        var id: Int { channel }
    }
    struct Report {
        let channels: Int
        let sampleRate: Double
        let bits: Int
        let guesses: [Guess]           // one per channel, in file order
        let features: [Features]
        let correlation: [[Double]]    // broadband correlation at lag 0, energy weighted
        let windows: Int
        let seconds: Double
        let overall: Double            // confidence in the whole assignment (0–1)
        let orderAssumed: Bool         // left/right inside each pair taken from the file order
        let notes: [String]
        var detected: ChannelOrder { ChannelOrder(roles: guesses.map(\.role)) }

        var text: String {
            var s = "CHANNELS: \(channels) · \(Int(sampleRate)) Hz · \(bits)-bit · \(windows) windows of \(Int(seconds)) s between 5% and 80% of the track\n"
            s += String(format: "DETECTED ORDER: %@%@ · confidence %.0f%%\n", detected.text, detected.presetName.map { "  (\($0))" } ?? "", overall * 100)
            for g in guesses {
                let f = features[g.channel]
                s += String(format: "  ch %d → %-3@ %3.0f%%  %@  [%.0f dBFS · low %.0f%% · speech %.0f%% · high %.0f%% · modulation %.0f%% · zeros %.0f%%]\n",
                            g.channel + 1, g.role.rawValue, g.confidence * 100, g.why, f.level, f.low * 100, f.speech * 100, f.high * 100, f.modulation * 100, f.zeros * 100)
            }
            if channels > 1 {
                s += "  correlation between channels (lag 0):\n"
                for i in 0..<channels {
                    s += "    ch \(i + 1): " + (0..<channels).map { j in i == j ? "  —  " : String(format: "%+.2f", correlation[i][j]) }.joined(separator: " ") + "\n"
                }
            }
            for n in notes { s += "  · \(n)\n" }
            return s
        }
    }

    // MARK: reading the WAV

    /// Decodes `count` samples of every channel starting at `start` (sample index) into floats in −1…1
    static func read(_ fh: FileHandle, info: WavInfo, start: Int, count: Int, channels: Int, bits: Int, float: Bool) -> [[Float]]? {
        let ba = info.blockAlign, bps = ba / max(1, channels)
        guard bps >= 1, bps <= 4, (start + count) * ba <= info.dataSize, (try? fh.seek(toOffset: UInt64(info.dataStart + start * ba))) != nil else { return nil }
        let d = fh.readData(ofLength: count * ba)
        guard d.count == count * ba else { return nil }
        var out = [[Float]](repeating: [Float](repeating: 0, count: count), count: channels)
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for n in 0..<count {
                let b = n * ba
                for c in 0..<channels {
                    let o = b + c * bps
                    var v: Float
                    switch (bps, float) {
                    case (1, _): v = (Float(p[o]) - 128) / 128
                    case (2, _): v = Float(Int16(bitPattern: UInt16(p[o]) | UInt16(p[o + 1]) << 8)) / 32768
                    case (3, _):
                        let u = UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16
                        v = Float(Int32(bitPattern: u << 8) >> 8) / 8_388_608
                    case (4, true):
                        v = Float(bitPattern: UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24)
                    default:
                        v = Float(Int32(bitPattern: UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24)) / 2_147_483_648
                    }
                    out[c][n] = v
                }
            }
        }
        return out
    }

    // MARK: the analysis

    static func analyze(url: URL, info: WavInfo, windows: Int = 40, seconds: Double = 6, bodyFrom: Double = 0.05, bodyTo: Double = 0.80,
                        cancel: CancelFlag? = nil, progress: (Double) -> Void = { _ in }) -> Report? {
        let fmt = info.fmt
        guard fmt.count >= 16 else { return nil }
        var tag = fmt.le16(0)
        let channels = fmt.le16(2), sr = Double(fmt.le32(4)), bits = fmt.le16(14)
        if tag == 0xFFFE && fmt.count >= 26 { tag = fmt.le16(24) }           // WAVE_FORMAT_EXTENSIBLE: the real format is in the sub-format GUID
        let isFloat = tag == 3
        // only the counts the role model knows (mono, stereo, LCR, quad, 5.0, 5.1, 7.1) and sample rates with a speech band
        guard [1, 2, 3, 4, 5, 6, 8].contains(channels), sr >= 8000, info.blockAlign == channels * ((bits + 7) / 8) else { return nil }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let total = info.dataSize / info.blockAlign
        return analyze(channels: channels, sampleRate: sr, bits: bits, total: total, windows: windows, seconds: seconds,
                       bodyFrom: bodyFrom, bodyTo: bodyTo, cancel: cancel, progress: progress) { start, count in
            read(fh, info: info, start: start, count: count, channels: channels, bits: bits, float: isFloat)
        }
    }

    /// The analysis itself, over any reader of windows (`read(start, count)` → one float array per channel, −1…1):
    /// a multichannel WAV, or the members of a mono group (MonoGroup.swift)
    static func analyze(channels: Int, sampleRate sr: Double, bits: Int, total: Int, windows: Int = 40, seconds: Double = 6,
                        bodyFrom: Double = 0.05, bodyTo: Double = 0.80, cancel: CancelFlag? = nil, progress: (Double) -> Void = { _ in },
                        read: (Int, Int) -> [[Float]]?) -> Report? {
        guard [1, 2, 3, 4, 5, 6, 8].contains(channels), sr >= 8000, total > 0 else { return nil }
        let winN = Int(seconds * sr)
        let lo = Int(Double(total) * bodyFrom), hi = Int(Double(total) * bodyTo) - winN
        let count = hi > lo ? min(windows, max(1, (hi - lo) / winN)) : 1
        let starts: [Int] = count == 1 ? [max(0, min(total - winN, total / 2 - winN / 2))] : (0..<count).map { lo + ($0 * (hi - lo)) / max(1, count - 1) }
        guard winN > 0, total >= winN else { return nil }

        // FFT geometry
        let win = 4096, hop = 2048, log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var hann = [Float](repeating: 0, count: win)
        vDSP_hann_window(&hann, vDSP_Length(win), Int32(vDSP_HANN_NORM))
        let binHz = sr / Double(win)
        func bin(_ hz: Double) -> Int { max(1, min(win / 2 - 1, Int((hz / binHz).rounded()))) }
        let lowHi = bin(120), spLo = bin(300), spHi = bin(3400), hiLo = bin(4000), hiHi = max(bin(4000), bin(min(12000, sr / 2 - 1)))
        let frameRate = sr / Double(hop)

        var feats = [Features](repeating: Features(), count: channels)
        var sumLow = [Double](repeating: 0, count: channels), sumSp = sumLow, sumHi = sumLow, sumTot = sumLow, sumMod = sumLow, sumLevel = sumLow, sumZero = sumLow
        var corrSum = [[Double]](repeating: [Double](repeating: 0, count: channels), count: channels), corrW = corrSum
        var re = [Float](repeating: 0, count: win / 2), im = re, frame = [Float](repeating: 0, count: win), mags = re

        for (wi, start) in starts.enumerated() {
            if cancel?.isSet == true { return nil }
            guard let x = read(start, winN), x.count == channels, x.allSatisfy({ $0.count == winN }) else { return nil }
            let nFrames = winN >= win ? (winN - win) / hop + 1 : 0
            var rms = [Double](repeating: 0, count: channels)
            var env = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: channels)   // speech-band energy per frame (dB)
            for c in 0..<channels {
                var ss: Float = 0
                vDSP_svesq(x[c], 1, &ss, vDSP_Length(winN))
                rms[c] = sqrt(Double(ss) / Double(winN))
                var zeros = 0
                for v in x[c] where v == 0 { zeros += 1 }
                sumZero[c] += Double(zeros) / Double(winN)
                guard rms[c] > 1e-5 else { continue }          // below −100 dBFS: nothing to listen to
                var eLow = 0.0, eSp = 0.0, eHi = 0.0, eTot = 0.0
                for f in 0..<nFrames {
                    let o = f * hop
                    for i in 0..<win { frame[i] = x[c][o + i] * hann[i] }
                    re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: win / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(win / 2)) }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(win / 2))
                    } }
                    var l = 0.0, s = 0.0, h = 0.0, t = 0.0
                    for k in 1..<lowHi { l += Double(mags[k]) }
                    for k in spLo..<spHi { s += Double(mags[k]) }
                    for k in hiLo..<hiHi { h += Double(mags[k]) }
                    for k in 1..<(win / 2) { t += Double(mags[k]) }
                    eLow += l; eSp += s; eHi += h; eTot += t
                    env[c][f] = 10 * log10(Float(s) + 1e-9)
                }
                guard eTot > 0 else { continue }
                sumLow[c] += eLow / eTot; sumSp[c] += eSp / eTot; sumHi[c] += eHi / eTot; sumTot[c] += 1
                sumLevel[c] += 20 * log10(rms[c])
                feats[c].active += 1
                // syllable-rate modulation of the speech-band envelope: power at 3–8 Hz over power at 0.5–12 Hz
                if nFrames > 16 {
                    var mean: Float = 0
                    vDSP_meanv(env[c], 1, &mean, vDSP_Length(nFrames))
                    var band = 0.0, all = 0.0
                    let df = frameRate / Double(nFrames)
                    var k = 1
                    while Double(k) * df <= 12 && k < nFrames / 2 {
                        let f = Double(k) * df
                        var cr = 0.0, ci = 0.0
                        for n in 0..<nFrames {
                            let a = 2 * Double.pi * Double(k) * Double(n) / Double(nFrames)
                            let v = Double(env[c][n] - mean)
                            cr += v * cos(a); ci -= v * sin(a)
                        }
                        let p = cr * cr + ci * ci
                        if f >= 0.5 { all += p }
                        if f >= 3 && f <= 8 { band += p }
                        k += 1
                    }
                    if all > 0 { sumMod[c] += band / all }
                }
            }
            // correlations at lag 0 between every pair, weighted by the quieter channel's level
            for i in 0..<channels {
                for j in (i + 1)..<channels where rms[i] > 1e-5 && rms[j] > 1e-5 {
                    var dot: Float = 0
                    vDSP_dotpr(x[i], 1, x[j], 1, &dot, vDSP_Length(winN))
                    let r = Double(dot) / (rms[i] * rms[j] * Double(winN))
                    let w = min(rms[i], rms[j])
                    corrSum[i][j] += r * w; corrW[i][j] += w
                }
            }
            progress(Double(wi + 1) / Double(starts.count))
        }

        var corr = [[Double]](repeating: [Double](repeating: 0, count: channels), count: channels)
        for i in 0..<channels { for j in (i + 1)..<channels where corrW[i][j] > 0 { corr[i][j] = corrSum[i][j] / corrW[i][j]; corr[j][i] = corr[i][j] } }
        for c in 0..<channels where feats[c].active > 0 {
            let n = Double(feats[c].active)
            feats[c].low = sumLow[c] / n; feats[c].speech = sumSp[c] / n; feats[c].high = sumHi[c] / n
            feats[c].modulation = sumMod[c] / n; feats[c].level = sumLevel[c] / n
        }
        for c in 0..<channels { feats[c].zeros = sumZero[c] / Double(starts.count) }

        return assign(feats, corr: corr, channels: channels, sampleRate: sr, bits: bits, windows: starts.count, seconds: seconds)
    }

    // MARK: who is who

    /// softmax with a temperature such that a margin of 0.3 in score is about 95% sure
    static func softmax(_ scores: [Double], t: Double = 0.1) -> [Double] {
        guard let m = scores.max() else { return [] }
        let e = scores.map { exp(($0 - m) / t) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }

    static func assign(_ f: [Features], corr: [[Double]], channels: Int, sampleRate: Double, bits: Int, windows: Int, seconds: Double) -> Report {
        var role = [ChannelRole?](repeating: nil, count: channels)
        var conf = [Double](repeating: 0, count: channels)
        var why = [String](repeating: "", count: channels)
        var notes: [String] = []
        var steps: [Double] = []                           // confidence of each decision; the whole is their product
        let silent = (0..<channels).filter { f[$0].active == 0 }
        for c in silent { notes.append("channel \(c + 1) is silent in every window listened to") }
        var pool = (0..<channels).filter { f[$0].active > 0 }
        let pairLabel = { (a: Int, b: Int) in "ch \(min(a, b) + 1) and ch \(max(a, b) + 1)" }
        func levelTerm(_ c: Int, among: [Int]) -> Double {
            let mean = among.map { f[$0].level }.reduce(0, +) / Double(max(1, among.count))
            return max(-1, min(1, (f[c].level - mean) / 10))
        }

        // 1. LFE: all its energy under 120 Hz, nothing up high. Only the 5.1 and 7.1 models have one.
        let wantsLFE = channels == 6 || channels == 8
        if pool.count >= 2 {
            let scores = pool.map { f[$0].low - 2 * f[$0].high - f[$0].speech + 0.2 * f[$0].zeros }
            let p = softmax(scores)
            if let bi = scores.indices.max(by: { scores[$0] < scores[$1] }) {
                let c = pool[bi]
                if wantsLFE && f[c].low > 0.6 {
                    role[c] = .LFE; conf[c] = p[bi]; steps.append(p[bi])
                    why[c] = String(format: "%.0f%% of its energy is below 120 Hz", f[c].low * 100)
                    pool.removeAll { $0 == c }
                } else if wantsLFE {
                    notes.append(String(format: "no channel looks like an LFE (the lowest one has only %.0f%% of its energy under 120 Hz)", f[c].low * 100))
                }
            }
        }

        // 2. the front pair: loud, similar, moving together
        func bestPair(in cands: [Int], level: Bool) -> (Int, Int, Double, Double)? {        // (a, b, confidence, correlation)
            var pairs: [(Int, Int)] = [], scores: [Double] = []
            for (x, a) in cands.enumerated() { for b in cands[(x + 1)...] {
                let lt = level ? (levelTerm(a, among: cands) + levelTerm(b, among: cands)) / 2 : 0
                let diff = abs(f[a].level - f[b].level) / 10
                // level first: the fronts are the loud pair in nearly every mix, while surround ambience can be more
                // correlated than the fronts; correlation then separates a true pair from two unrelated loud channels
                pairs.append((a, b)); scores.append(0.8 * corr[a][b] + 1.0 * lt - 0.3 * diff)
            } }
            guard !pairs.isEmpty, let bi = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
            let p = softmax(scores)
            return (pairs[bi].0, pairs[bi].1, p[bi], corr[pairs[bi].0][pairs[bi].1])
        }
        if channels == 1, let c = pool.first {
            role[c] = .M; conf[c] = 1; why[c] = "the only channel"
            pool.removeAll()
        } else if pool.count == 2 {
            // the only two channels with sound (a stereo file, or a stem with everything else silent): the front pair
            let (a, b) = (pool[0], pool[1])
            let c = corr[a][b] > 0.2 ? 0.9 : 0.7
            role[a] = .L; role[b] = .R; conf[a] = c; conf[b] = c; steps.append(c)
            why[a] = String(format: "%@ pair with ch %d (correlation %+.2f); left by file order", channels == 2 ? "stereo" : "the only audible", b + 1, corr[a][b])
            why[b] = String(format: "%@ pair with ch %d; right by file order", channels == 2 ? "stereo" : "the only audible", a + 1)
            pool.removeAll()
        } else if pool.count >= 3, let (a, b, pc, r) = bestPair(in: pool, level: true) {
            role[a] = .L; role[b] = .R; conf[a] = pc; conf[b] = pc; steps.append(pc)
            why[a] = String(format: "front pair with ch %d: loudest pair, correlation %+.2f; left by file order", b + 1, r)
            why[b] = String(format: "front pair with ch %d; right by file order", a + 1)
            pool.removeAll { $0 == a || $0 == b }
        }

        // 3. the centre: speech, modulated at syllable rate, not glued to any other channel
        if pool.count >= 1 && channels != 2 && channels != 4 && role.contains(.L) {
            let scores = pool.map { c -> Double in
                let others = (0..<channels).filter { $0 != c }
                let glued = others.map { corr[c][$0] }.max() ?? 0
                return 1.2 * f[c].speech + 1.5 * f[c].modulation + 0.3 * levelTerm(c, among: pool) - 0.5 * max(0, glued)
            }
            let p = softmax(scores)
            if let bi = scores.indices.max(by: { scores[$0] < scores[$1] }) {
                let c = pool[bi]
                let pc = pool.count == 1 ? min(1, 0.6 + steps.last! * 0.4) : p[bi]
                role[c] = .C; conf[c] = pc; steps.append(pc)
                why[c] = String(format: "speech: %.0f%% of its energy in 300–3400 Hz, %.0f%% of its envelope moving at syllable rate", f[c].speech * 100, f[c].modulation * 100)
                pool.removeAll { $0 == c }
            }
        }

        // 4. the surrounds: what is left, in pairs (only once a front pair exists)
        if pool.count == 2 && role.contains(.L) {
            let (a, b) = (pool[0], pool[1])
            let pc = min(1, 0.5 + 0.5 * max(0, corr[a][b]) + 0.3)
            role[a] = .Ls; role[b] = .Rs; conf[a] = pc; conf[b] = pc; steps.append(pc)
            why[a] = String(format: "remaining pair with ch %d (correlation %+.2f, %.0f dB under the fronts); left by file order", b + 1, corr[a][b],
                            (role.firstIndex(of: .L).map { f[$0].level } ?? f[a].level) - f[a].level)
            why[b] = String(format: "remaining pair with ch %d; right by file order", a + 1)
            pool.removeAll()
        } else if pool.count == 4 && role.contains(.L) {
            let p = pool
            let pairings = [[(p[0], p[1]), (p[2], p[3])], [(p[0], p[2]), (p[1], p[3])], [(p[0], p[3]), (p[1], p[2])]]
            let scores = pairings.map { $0.reduce(0.0) { $0 + corr[$1.0][$1.1] } }
            let sm = softmax(scores)
            let bi = scores.indices.max(by: { scores[$0] < scores[$1] })!
            var pairs = pairings[bi]
            // the louder pair sits at the sides (Ls Rs), the quieter one at the back (Lrs Rrs)
            let lv = pairs.map { (f[$0.0].level + f[$0.1].level) / 2 }
            if lv[1] > lv[0] { pairs.reverse() }
            let margin = min(1, 0.5 + abs(lv[0] - lv[1]) / 6)
            let pc = sm[bi] * margin
            steps.append(pc)
            for (k, pr) in pairs.enumerated() {
                let (a, b) = pr.0 < pr.1 ? (pr.0, pr.1) : (pr.1, pr.0)
                role[a] = k == 0 ? .Ls : .Lrs; role[b] = k == 0 ? .Rs : .Rrs; conf[a] = pc; conf[b] = pc
                why[a] = String(format: "%@ pair with ch %d (correlation %+.2f, %@); left by file order", k == 0 ? "side surround" : "rear surround", b + 1, corr[a][b], k == 0 ? "the louder of the two surround pairs" : "the quieter pair")
                why[b] = String(format: "%@ pair with ch %d; right by file order", k == 0 ? "side surround" : "rear surround", a + 1)
            }
            pool.removeAll()
        }

        // 5. whatever has no role yet (silent channels, odd counts): the roles still free, in file order, with little confidence
        let wanted: [ChannelRole] = channels == 8 ? [.L, .R, .C, .LFE, .Ls, .Rs, .Lrs, .Rrs] : channels == 6 ? [.L, .R, .C, .LFE, .Ls, .Rs]
            : channels == 5 ? [.L, .R, .C, .Ls, .Rs] : channels == 4 ? [.L, .R, .Ls, .Rs] : channels == 3 ? [.L, .R, .C] : channels == 2 ? [.L, .R] : [.M]
        var free = wanted.filter { r in !role.contains(r) }
        for c in 0..<channels where role[c] == nil {
            let r = free.isEmpty ? ChannelRole.M : free.removeFirst()
            role[c] = r; conf[c] = 0.25
            why[c] = f[c].active == 0 ? "silent — given the role left over" : "no clear signature — given the role left over"
            steps.append(0.25)
        }
        if (channels == 6 || channels == 8) && role.firstIndex(of: .LFE).map({ f[$0].zeros }) ?? 0 > 0.3 {
            notes.append("the LFE is exactly zero much of the time, which is how a cinema mix usually looks")
        }
        if channels > 2 { notes.append("which channel of a pair is the left one cannot be told from the sound; the file order was kept (first = left)") }
        let overall = steps.isEmpty ? 1 : steps.reduce(1, *)
        let guesses = (0..<channels).map { Guess(channel: $0, role: role[$0] ?? .M, confidence: conf[$0], why: why[$0]) }
        return Report(channels: channels, sampleRate: sampleRate, bits: bits, guesses: guesses, features: f, correlation: corr,
                      windows: windows, seconds: seconds, overall: overall, orderAssumed: channels > 1, notes: notes)
    }

    // MARK: command line

    /// `--channels FILE.wav [--target "L C R Ls Rs LFE"] [--out FILE.wav]`
    static func cli(_ args: [String]) -> Int32 {
        var file: String?, target: String?, out: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--target": i += 1; target = i < args.count ? args[i] : nil
            case "--out": i += 1; out = i < args.count ? args[i] : nil
            default: file = args[i]
            }
            i += 1
        }
        guard let file else { fputs("usage: --channels FILE.wav [--target \"L C R Ls Rs LFE\" --out OUT.wav]\n", stderr); return 2 }
        let url = URL(fileURLWithPath: file)
        guard let info = WavInfo.read(url) else { fputs("not a WAV file: \(file)\n", stderr); return 1 }
        guard let r = analyze(url: url, info: info, progress: { p in fputs(String(format: "\r  … listening %3.0f%%", p * 100), stderr) }) else {
            fputs("\ncould not analyse \(file)\n", stderr); return 1
        }
        fputs("\r                      \r", stderr)
        print(r.text)
        if let target {
            let tokens = target.split(separator: " ")
            let roles = tokens.compactMap { ChannelRole(rawValue: String($0)) }
            guard roles.count == tokens.count else { fputs("unknown channel role in target “\(target)” — use \(ChannelRole.allCases.map(\.rawValue).joined(separator: " "))\n", stderr); return 2 }
            let order = ChannelOrder(roles: roles)
            guard order.count == r.channels, order.isComplete else { fputs("target must name each of the \(r.channels) channels once\n", stderr); return 2 }
            guard order.canBeWritten(from: r.detected) else { fputs("target \(order.text) is not made of the roles heard (\(r.detected.text))\n", stderr); return 2 }
            guard let perm = order.permutation(from: r.detected) else { print("TARGET \(order.text): the file is already in that order"); return 0 }
            print("TARGET \(order.text): " + perm.enumerated().map { "out \($0 + 1) ← ch \($1 + 1) (\(r.detected.roles[$1].rawValue))" }.joined(separator: ", "))
            if let out {
                let total = info.dataSize / info.blockAlign
                do {
                    try WavInfo.writeTrimmed(info, from: url, to: URL(fileURLWithPath: out), pad: 0, cut: 0, keep: total, order: perm, cancel: CancelFlag()) { p in
                        fputs(String(format: "\r  … writing %3.0f%%", p * 100), stderr)
                    }
                    fputs("\r                      \r", stderr)
                    print("WROTE \(out)")
                } catch { fputs("\n\(error.localizedDescription)\n", stderr); return 1 }
            }
        }
        return 0
    }
}
