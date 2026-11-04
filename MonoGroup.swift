// BROS-MUX — several mono PCM sounds, one per channel (mono WAV files, or the mono streams Resolve writes inside a
// ProRes MOV), handled as ONE multichannel track: nobody listens to "just the left". They are detected when the files
// are read, each channel is named (from the labels in the file, from the file names, or by listening — ChannelID.swift),
// the sync is measured once for the whole group and one offset moves every channel by the same whole samples, and at
// mux time the mono sounds are interleaved into one PCM track — every sample copied as it is — which is then verified
// channel by channel against the mono sources.

import Foundation

// MARK: - Which channel is this mono sound?

enum GroupRoles {
    /// The roles a standard layout of this many channels is made of
    static func wanted(_ n: Int) -> [ChannelRole]? {
        switch n {
        case 1: return [.M]
        case 2: return [.L, .R]
        case 3: return [.L, .R, .C]
        case 4: return [.L, .R, .Ls, .Rs]
        case 5: return [.L, .R, .C, .Ls, .Rs]
        case 6: return [.L, .R, .C, .LFE, .Ls, .Rs]
        case 8: return [.L, .R, .C, .LFE, .Ls, .Rs, .Lrs, .Rrs]
        default: return nil
        }
    }
    static let sizes: Set<Int> = [2, 3, 4, 5, 6, 8]

    /// A speaker as a file, MediaInfo, ffprobe or a file name names it; "surround" vs "back" is settled by the set
    enum Raw: Equatable { case L, R, C, LFE, M, side(left: Bool), back(left: Bool) }

    /// One token, however it is spelled: Pro Tools (.L .C .R .Ls .Rs .LFE, Lss/Rss/Lsr/Rsr for 7.1), Resolve (_L _R _C
    /// _LFE _Ls _Rs), ffprobe (FL FR FC LFE BL BR SL SR), MediaInfo (L R C LFE Ls Rs Lb Rb Lss Rss)
    static func raw(_ token: String) -> Raw? {
        switch token.lowercased() {
        case "l", "left", "fl": return .L
        case "r", "right", "fr": return .R
        case "c", "center", "centre", "fc", "cen", "ctr": return .C
        case "lfe", "sub", "subwoofer", "sw": return .LFE
        case "m", "mono": return .M
        case "ls", "lss", "lsd", "sl", "lsur", "lsurr", "lsi": return .side(left: true)
        case "rs", "rss", "rsd", "sr", "rsur", "rsurr", "rsi": return .side(left: false)
        case "lrs", "lsr", "lb", "bl", "lrear", "lback", "lr": return .back(left: true)
        case "rrs", "rsr", "rb", "br", "rrear", "rback", "rr": return .back(left: false)
        default: return nil
        }
    }

    /// The label the file itself carries for a mono stream: MediaInfo's ChannelLayout ("L", "LFE", "Ls"…) first, then
    /// ffprobe's ("1 channels (FL)"). A plain "mono"/"C" with nothing else is what every unlabeled mono file says, so
    /// it only counts when the whole set turns out consistent (see `resolve`).
    static func fromFile(_ t: Track) -> Raw? {
        if let l = t.mi?["ChannelLayout"]?.trimmingCharacters(in: .whitespaces), !l.contains(" "), let r = raw(l) { return r }
        if let l = t.channelLayout, let open = l.firstIndex(of: "("), let close = l.firstIndex(of: ")"), open < close {
            return raw(String(l[l.index(after: open)..<close]))
        }
        return nil
    }

    /// The channel named at the end of the file name: "Mix.L.wav", "Mix_LFE.wav", "Mix-Ls.wav", "Mix L.wav"
    static func fromName(_ t: Track) -> Raw? {
        let base = t.url.deletingPathExtension().lastPathComponent
        let tokens = base.components(separatedBy: CharacterSet(charactersIn: " _.-")).filter { !$0.isEmpty }
        // a trailing take/version number ("Mix_L_01") is skipped
        for tok in tokens.reversed() {
            if Int(tok) != nil { continue }
            return raw(tok)
        }
        return nil
    }

    /// Settles surround/back for the set and checks it is exactly one standard layout; nil = not a valid set
    static func resolve(_ raw: [Raw?], count n: Int) -> [ChannelRole]? {
        guard raw.count == n, let want = wanted(n), !raw.contains(where: { $0 == nil }) else { return nil }
        let r = raw.map { $0! }
        let hasSide = r.contains { if case .side = $0 { return true } else { return false } }
        let roles: [ChannelRole] = r.map { x in
            switch x {
            case .L: return .L
            case .R: return .R
            case .C: return .C
            case .LFE: return .LFE
            case .M: return .M
            case .side(let left): return left ? .Ls : .Rs
            case .back(let left): return (n == 8 && hasSide) ? (left ? .Lrs : .Rrs) : (left ? .Ls : .Rs)
            }
        }
        guard Set(roles).count == n, Set(roles) == Set(want) else { return nil }
        return roles
    }

    /// Roles for a set of mono tracks, and where they came from (nil: the names say nothing usable — listen instead)
    static func detect(_ members: [Track]) -> (roles: [ChannelRole], source: String)? {
        let n = members.count
        if let r = resolve(members.map(fromFile), count: n) {
            return (r, members.allSatisfy({ $0.fromVideoFile }) ? "read from the channel labels in the file" : "read from the channel labels in the files")
        }
        if let r = resolve(members.map(fromName), count: n) { return (r, "taken from the file names") }
        return nil
    }
}

// MARK: - The group as one Track

extension Track {
    /// Bytes per sample of one channel, for PCM
    static func codecBytes(_ codec: String) -> Int? {
        ["pcm_u8": 1, "pcm_s8": 1, "pcm_s16le": 2, "pcm_s16be": 2, "pcm_s24le": 3, "pcm_s24be": 3, "pcm_s32le": 4, "pcm_s32be": 4,
         "pcm_f32le": 4, "pcm_f32be": 4, "pcm_f64le": 8, "pcm_f64be": 8][codec]
    }
    /// Bytes one sample of this mono track takes in its file (a WAV may keep 24 bits in 4 bytes)
    var monoBytesPerSample: Int? { wav?.blockAlign ?? Track.codecBytes(codecKey) }
    var isFloatPCM: Bool { codecKey.hasPrefix("pcm_f") }

    /// Why these tracks can't be one multichannel track (nil = they can)
    static func groupProblem(_ m: [Track]) -> String? {
        guard GroupRoles.sizes.contains(m.count) else { return "\(m.count) mono tracks don't make a standard layout (2, 3, 4, 5, 6 or 8 channels)" }
        guard m.allSatisfy({ $0.kind == .audio && $0.isPCM && $0.channels == 1 && !$0.isGroup }) else { return "only mono PCM tracks can be grouped" }
        let f = m[0]
        guard let bps = f.monoBytesPerSample, f.sampleRate > 0,
              m.allSatisfy({ $0.monoBytesPerSample == bps && $0.sampleRate == f.sampleRate && $0.bitDepth == f.bitDepth && $0.isFloatPCM == f.isFloatPCM })
        else { return "the mono tracks differ in sample rate or bit depth" }
        let lens = m.map(\.totalSamples)
        guard let lo = lens.min(), let hi = lens.max(), lo > 0, Double(hi - lo) <= f.sampleRate else { return "the mono tracks differ in length by more than a second — are they the same program?" }
        return nil
    }
    static func groupable(_ m: [Track]) -> Bool { !m.isEmpty && groupProblem(m) == nil }

    /// One multichannel track made of these mono tracks (in this order). Roles come from the files or their names when
    /// they say so; otherwise `channelRoles` stays nil until the group is listened to.
    static func group(_ m: [Track]) -> Track? {
        guard groupable(m), let bps = m[0].monoBytesPerSample else { return nil }
        let f = m[0], n = m.count
        let embedded = m.allSatisfy(\.fromVideoFile)
        let codec: String
        switch (bps, f.isFloatPCM) {
        case (1, _): codec = "pcm_u8"
        case (2, _): codec = "pcm_s16le"
        case (3, _): codec = "pcm_s24le"
        case (4, true): codec = "pcm_f32le"
        case (4, false): codec = "pcm_s32le"
        default: codec = "pcm_f64le"
        }
        let lens = m.map(\.totalSamples)
        let total = lens.min() ?? 0
        let chText = Probe.channelText(n, nil)
        let sr = f.sampleRate
        let duration = Double(total) / sr
        var d: [String] = [Fmt.hz(sr), "\(n) channels", Fmt.bitrate(Double(n * bps * 8) * sr)]
        if duration > 0 { d.append(Fmt.duration(duration)) }
        var warnings: [String] = []
        if let hi = lens.max(), hi > total {
            warnings.append("The mono \(embedded ? "streams" : "files") differ in length (up to \(Fmt.int(hi - total)) samples); the longer ones end with the shortest.")
        }
        let indices = m.map(\.streamIndex).sorted()
        let contiguous = indices.enumerated().allSatisfy { $0.offset == 0 || $0.element == indices[$0.offset - 1] + 1 }
        let sourceLabel = embedded ? (contiguous ? "streams \(indices[0] + 1)–\(indices[n - 1] + 1)" : "\(n) streams") : "\(n) mono files"
        // MediaInfo-style description of the track that will be written (the Academy/Zidoo predictions read it)
        var mf = f.mi?.f ?? ["@type": "Audio", "Format": "PCM", "BitDepth": "\(f.bitDepth)", "SamplingRate": "\(Int(sr))"]
        mf["@type"] = "Audio"
        mf["Channels"] = "\(n)"
        mf["ChannelLayout"] = nil; mf["ChannelPositions"] = nil; mf["Title"] = nil
        mf["Format_Settings_Endianness"] = "Little"
        if let s = f.mi?.d("StreamSize") { mf["StreamSize"] = String(s * Double(n)) }
        mf["BitRate"] = String(Double(n * bps * 8) * sr)
        mf["Duration"] = String(duration)
        var t = Track(url: f.url, selector: nil, streamIndex: f.streamIndex, kind: .audio, codecKey: codec,
                      codecName: f.bitDepth > 0 ? "PCM \(f.bitDepth)-bit" + (f.isFloatPCM ? " float" : "") : "PCM",
                      details: d.joined(separator: " · "), badges: [chText, "\(n) mono \(embedded ? "streams" : "files")"], warnings: warnings,
                      sourceLabel: sourceLabel, isAtmos: false, channels: n, sampleRate: sr, bitDepth: f.bitDepth,
                      bitRate: Double(n * bps * 8) * sr, duration: duration, wav: nil, channelLayout: nil, fromVideoFile: embedded,
                      mi: MITrack(type: "Audio", f: mf), include: true, language: f.language, title: Fmt.ascii("PCM \(chText)"), enabled: f.enabled)
        t.members = m
        t.groupBPS = bps
        t.groupTotal = total
        if let r = GroupRoles.detect(m) {
            t.channelRoles = r.roles
            t.rolesSource = r.source
            t.channelTarget = ChannelOrder.presets(channels: n).first?.order
        }
        return t
    }

    /// The group's members in the order they are written (output channel k = members[permutation[k]])
    var orderedMembers: [Track] { (channelPermutation ?? Array(members.indices)).map { members[$0] } }

    /// One line for the row: the roles, where they came from, and the order written
    var groupChannelsText: String {
        guard isGroup else { return "" }
        if listening { return "Listening to the channels to tell L, R, C, LFE and the surrounds apart…" }
        guard let src = sourceOrder else { return "Channels not identified — written in file order, no channel labels. Open “Channels…” to set them." }
        var s = src.text
        if let how = rolesSource { s += " (\(how)" + (channelConfidence.map { String(format: " · %.0f%% sure", $0 * 100) } ?? "") + ")" }
        if !src.isComplete { return s + " — each role must be used once: open “Channels…”" }
        if let t = channelTarget, t != src, t.canBeWritten(from: src) {
            s += " → written as \(t.text)" + (t.presetName.map { " (\($0))" } ?? "")
        } else {
            s += " · written in this order" + (src.presetName.map { " (\($0))" } ?? "")
        }
        s += outputLayoutTag(writeLabels: true) != nil ? " · channel labels written" : " · no standard channel labels for this order"
        return s
    }
    var groupMembersText: String {
        guard isGroup else { return "" }
        if fromVideoFile { return "\(members.count) mono streams inside \(url.lastPathComponent) (\(sourceLabel))" }
        return "\(members.count) files: " + members.map { $0.url.lastPathComponent }.joined(separator: " · ")
    }
}

// MARK: - Reading the mono sources as bytes

/// A mono PCM stream read through ffmpeg (copied byte for byte, or byte-swapped to little-endian — the values never
/// change), with the same trim as a WAV: `pad` samples of silence, skip `cut`, deliver `keep`
final class PipeRangeSource: ByteSource {
    let p: Process; let h: FileHandle
    var padLeft: Int; var skipLeft: Int; var left: Int; let silence: UInt8
    init(url: URL, index: Int, codec: String, as outCodec: String, bps: Int, pad: Int, cut: Int, keep: Int) throws {
        guard let fmt = Verifier.rawFormat(outCodec) else { throw AppError("can't read \(outCodec) as raw samples") }
        (p, h) = try Tools.ffmpegPipe(["-i", url.path, "-map", "0:\(index)"] + (codec == outCodec ? ["-c", "copy"] : ["-c:a", outCodec]) + ["-f", fmt, "-"])
        padLeft = pad * bps; skipLeft = cut * bps; left = keep * bps
        silence = outCodec == "pcm_u8" ? 0x80 : 0
    }
    func read(_ max: Int) throws -> Data {
        if padLeft > 0 { let n = min(max, padLeft); padLeft -= n; return Data(repeating: silence, count: n) }
        while skipLeft > 0 {
            let d = h.readData(ofLength: min(skipLeft, 8 << 20))
            guard !d.isEmpty else { throw AppError("the mono source ended earlier than expected") }
            skipLeft -= d.count
        }
        guard left > 0 else { return Data() }
        let d = h.readData(ofLength: min(max, left))
        guard !d.isEmpty else { throw AppError("the mono source ended earlier than expected") }
        left -= d.count
        return d
    }
    func finish() throws { Tools.stop(p, h) }
}

enum Interleave {
    /// Whole blocks of each channel → frames (sample 1 of every channel, sample 2 of every channel, …)
    static func merge(_ parts: [Data], bps: Int) -> Data {
        let n = parts.count
        guard n > 0, bps > 0 else { return Data() }
        let frames = parts.map { $0.count / bps }.min() ?? 0
        guard frames > 0 else { return Data() }
        var out = Data(count: frames * n * bps)
        out.withUnsafeMutableBytes { o in
            guard let op = o.bindMemory(to: UInt8.self).baseAddress else { return }
            for (c, part) in parts.enumerated() {
                part.withUnsafeBytes { i in
                    guard let ip = i.bindMemory(to: UInt8.self).baseAddress else { return }
                    var dst = c * bps, src = 0
                    for _ in 0..<frames {
                        for j in 0..<bps { op[dst + j] = ip[src + j] }
                        dst += n * bps; src += bps
                    }
                }
            }
        }
        return out
    }
    /// Frames → one block per channel (the inverse of `merge`)
    static func split(_ d: Data, channels n: Int, bps: Int) -> [Data] {
        guard n > 0, bps > 0 else { return [] }
        let frames = d.count / (n * bps)
        var out = [Data](repeating: Data(count: frames * bps), count: n)
        guard frames > 0 else { return out }
        d.withUnsafeBytes { i in
            guard let ip = i.bindMemory(to: UInt8.self).baseAddress else { return }
            for c in 0..<n {
                out[c].withUnsafeMutableBytes { o in
                    guard let op = o.bindMemory(to: UInt8.self).baseAddress else { return }
                    var src = c * bps, dst = 0
                    for _ in 0..<frames {
                        for j in 0..<bps { op[dst + j] = ip[src + j] }
                        src += n * bps; dst += bps
                    }
                }
            }
        }
        return out
    }
}

enum GroupSources {
    /// The samples of one member with the group's trim, as the bytes that will be written
    static func open(_ m: Track, as codec: String, bps: Int, pad: Int, cut: Int, keep: Int) throws -> ByteSource {
        if let wav = m.wav { return try WavRangeSource(m.url, info: wav, pad: pad, cut: cut, keep: keep) }
        return try PipeRangeSource(url: m.url, index: m.streamIndex, codec: m.codecKey, as: codec, bps: bps, pad: pad, cut: cut, keep: keep)
    }

    /// Exactly `n` bytes, or what is left at the end (empty = ended)
    static func readExactly(_ s: ByteSource, _ n: Int) throws -> Data {
        var out = Data()
        while out.count < n {
            let d = try s.read(n - out.count)
            if d.isEmpty { break }
            out.append(d)
        }
        return out
    }

    /// 'fmt ' chunk of the multichannel WAV that is written (WAVE_FORMAT_EXTENSIBLE, as Pro Tools and Resolve write)
    static func fmtChunk(channels n: Int, sampleRate: Double, bps: Int, validBits: Int, float: Bool, order: ChannelOrder?) -> Data {
        var f = Data()
        func le16(_ v: Int) { f.append(UInt8(v & 0xFF)); f.append(UInt8((v >> 8) & 0xFF)) }
        le16(0xFFFE); le16(n); f.appendLE32(Int(sampleRate)); f.appendLE32(Int(sampleRate) * n * bps); le16(n * bps); le16(bps * 8)
        le16(22); le16(validBits > 0 ? min(validBits, bps * 8) : bps * 8)
        // the WAV speaker mask only when its own order (FL FR FC LFE BL BR …) is the order written
        var mask = 0
        switch order?.roles ?? [] {
        case [.M]: mask = 0x4
        case [.L, .R]: mask = 0x3
        case [.L, .R, .C]: mask = 0x7
        case [.L, .R, .C, .LFE, .Ls, .Rs]: mask = 0x3F
        default: mask = 0
        }
        f.appendLE32(mask)
        f.append(contentsOf: [float ? 0x03 : 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        return f
    }

    /// Writes the WAV: header, then the members interleaved frame by frame. Every byte of every sample is copied as it is.
    static func writeInterleaved(_ members: [ByteSource], bps: Int, frames: Int, fmt: Data, to dst: URL,
                                 cancel: CancelFlag, progress: (Double) -> Void) throws {
        let n = members.count
        guard n > 0, frames > 0 else { throw AppError("Nothing to interleave.") }
        let dataBytes = frames * n * bps
        let fmtChunk = 8 + fmt.count + (fmt.count & 1)
        let total = 12 + fmtChunk + 8 + dataBytes + (dataBytes & 1)
        let rf64 = total + 36 > Int(UInt32.max)
        var h = Data()
        if rf64 {
            h.appendASCII("RF64"); h.appendLE32(0xFFFF_FFFF); h.appendASCII("WAVE")
            h.appendASCII("ds64"); h.appendLE32(28)
            h.appendLE64(total + 36 - 8); h.appendLE64(dataBytes); h.appendLE64(frames); h.appendLE32(0)
        } else {
            h.appendASCII("RIFF"); h.appendLE32(total - 8); h.appendASCII("WAVE")
        }
        h.appendASCII("fmt "); h.appendLE32(fmt.count); h.append(fmt)
        if fmt.count & 1 == 1 { h.append(0) }
        h.appendASCII("data"); h.appendLE32(rf64 ? 0xFFFF_FFFF : dataBytes)
        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else { throw AppError("Couldn't create \(dst.lastPathComponent)") }
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        try out.write(contentsOf: h)
        let step = max(1, (4 << 20) / bps)          // frames per round: ~4 MB per channel
        var done = 0
        while done < frames {
            if cancel.isSet { throw Cancelled() }
            let f = min(step, frames - done)
            var parts: [Data] = []
            parts.reserveCapacity(n)
            for m in members {
                let d = try readExactly(m, f * bps)
                guard d.count == f * bps else { throw AppError("a mono source ended earlier than expected (\(Fmt.int(done + d.count / bps)) of \(Fmt.int(frames)) samples)") }
                parts.append(d)
            }
            try out.write(contentsOf: Interleave.merge(parts, bps: bps))
            done += f
            progress(Double(done) / Double(frames))
        }
        if dataBytes & 1 == 1 { try out.write(contentsOf: Data([0])) }
    }

    /// The multichannel track of the final file, split back into channels and compared with the mono sources one by one
    static func verify(_ t: Track, pad: Int, cut: Int, keep: Int, out: URL, outStream: ProbeStream,
                       cancel: CancelFlag, progress: (Double) -> Void) -> Verifier.Result {
        let name = "Audio “\(t.title)”"
        let n = t.channels, bps = t.groupBPS
        guard let fmt = Verifier.rawFormat(t.codecKey), bps > 0, n == t.members.count else { return .init(ok: false, text: "\(name): can't verify this group ✗") }
        guard (outStream.channels ?? 0) == n else { return .init(ok: false, text: "\(name): the final file has \(outStream.channels ?? 0) channels, expected \(n) ✗") }
        let ordered = t.orderedMembers
        let roles = t.channelTarget?.roles ?? t.channelRoles ?? []
        var sources: [ByteSource] = []
        func close() { for s in sources { try? s.finish() } }
        do {
            for m in ordered { sources.append(try GroupSources.open(m, as: t.codecKey, bps: bps, pad: pad, cut: cut, keep: keep)) }
        } catch { close(); return .init(ok: false, text: "\(name): \(error.localizedDescription) ✗") }
        let outSrc: PipeSource
        do {
            let outCodec = outStream.codec_name ?? ""
            outSrc = try PipeSource(["-i", out.path, "-map", "0:\(outStream.index)"] + (outCodec == t.codecKey ? ["-c", "copy"] : ["-c:a", t.codecKey]) + ["-f", fmt, "-"])
        } catch { close(); return .init(ok: false, text: "\(name): \(error.localizedDescription) ✗") }
        let expected = Double(max(1, (pad + keep) * n * bps))
        let step = max(1, (4 << 20) / bps)
        var total = 0
        func label(_ k: Int) -> String { "channel \(k + 1)" + (k < roles.count ? " (\(roles[k].rawValue))" : "") + (k < ordered.count ? " ← \(ordered[k].fromVideoFile ? "stream \(ordered[k].streamIndex + 1)" : ordered[k].url.lastPathComponent)" : "") }
        do {
            while true {
                if cancel.isSet { outSrc.abort(); close(); return .init(ok: false, text: "\(name): verification cancelled") }
                let want = step * n * bps
                let b = try readExactly(outSrc, want)
                if b.isEmpty { break }
                guard b.count % (n * bps) == 0 else { outSrc.abort(); close(); return .init(ok: false, text: "\(name): the final file's track isn't whole \(n)-channel frames ✗") }
                let frames = b.count / (n * bps)
                let parts = Interleave.split(b, channels: n, bps: bps)
                for k in 0..<n {
                    let a = try readExactly(sources[k], frames * bps)
                    if a.count < frames * bps {
                        outSrc.abort(); close()
                        return .init(ok: false, text: "\(name): the final file has MORE data than the sources (\(label(k)) ended at \(Fmt.bytes(Double(total / n + a.count)))) ✗")
                    }
                    if a != parts[k] {
                        outSrc.abort(); close()
                        return .init(ok: false, text: "\(name): \(label(k)) is DIFFERENT from its source near \(Fmt.bytes(Double(total / n))) ✗")
                    }
                }
                total += b.count
                progress(min(Double(total) / expected, 1))
                if b.count < want { break }
            }
            for k in 0..<n where try !sources[k].read(1).isEmpty {
                outSrc.abort(); close()
                return .init(ok: false, text: "\(name): the final file has LESS data than the sources (\(label(k)) goes on past \(Fmt.bytes(Double(total / n)))) ✗")
            }
            close()
            do { try outSrc.finish() } catch { return .init(ok: false, text: "\(name): the final file has \(error.localizedDescription) ✗") }
        } catch {
            outSrc.abort(); close()
            return .init(ok: false, text: "\(name): \(error.localizedDescription) ✗")
        }
        guard total > 0 else { return .init(ok: false, text: "\(name): no data was read — can't confirm ✗") }
        return .init(ok: true, text: "\(name): bit-identical ✓ (\(n) channels, each checked against its mono source · \(Fmt.bytes(Double(total))))")
    }
}

// MARK: - Listening to a group (ChannelID on several mono sources)

extension ChannelID {
    /// Reads a window of one mono member as floats: straight from a WAV, or decoded by ffmpeg for a stream in a movie
    static func memberReader(_ t: Track, sampleRate sr: Double) -> (Int, Int) -> [Float]? {
        if let wav = t.wav {
            let float = t.isFloatPCM
            return { start, count in
                guard let fh = try? FileHandle(forReadingFrom: t.url) else { return nil }
                defer { try? fh.close() }
                return read(fh, info: wav, start: start, count: count, channels: 1, bits: wav.bitsPerSample, float: float)?.first
            }
        }
        let src = SyncEngine.Source(url: t.url, index: t.streamIndex, duration: t.duration, channels: 1)
        return { start, count in
            var x = SyncEngine.decode(src, from: Double(start) / sr, length: Double(count) / sr, rate: Int(sr))
            guard !x.isEmpty else { return nil }
            if x.count < count { x += [Float](repeating: 0, count: count - x.count) } else if x.count > count { x = Array(x.prefix(count)) }
            return x
        }
    }

    /// Same analysis as a multichannel WAV, over the members of a group (in member order)
    static func analyzeGroup(_ g: Track, cancel: CancelFlag? = nil, progress: (Double) -> Void = { _ in }) -> Report? {
        let m = g.members
        guard g.isGroup, [1, 2, 3, 4, 5, 6, 8].contains(m.count), g.sampleRate >= 8000, g.groupTotal > 0 else { return nil }
        let sr = g.sampleRate
        let readers = m.map { memberReader($0, sampleRate: sr) }
        return analyze(channels: m.count, sampleRate: sr, bits: g.bitDepth, total: g.groupTotal, cancel: cancel, progress: progress) { start, count in
            var out: [[Float]] = []
            out.reserveCapacity(readers.count)
            for r in readers { guard let x = r(start, count), x.count == count else { return nil }; out.append(x) }
            return out
        }
    }
}
