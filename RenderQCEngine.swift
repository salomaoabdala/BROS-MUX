// BROS-MUX — Render QC engine
// Reads a rendered file (a DaVinci Resolve export, typically) frame by frame and looks for the things a render can get
// wrong without anyone noticing: green or magenta frames, "Media Offline" frames, stray black or white frames, a frame
// repeated inside motion (a dropped frame), bands, lines or blocks of garbage that last a frame, timestamp gaps, audio
// dropouts, clicks and clipping. No reference file is needed: every check compares a frame with its own neighbours.

import Foundation
import Accelerate
import Vision

enum RenderQC {
    enum Severity: Int, Comparable { case info = 0, warning = 1, error = 2
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue } }
    enum Kind: String, CaseIterable {
        case greenFrame = "Green frame", magentaFrame = "Magenta frame", solidFrame = "Solid-colour frame", mediaOffline = "Media Offline frame",
             blackFrame = "Black frame", whiteFrame = "White frame", frozenFrame = "Repeated frame", bandArtifact = "Band / line artifact",
             blockArtifact = "Block artifact", timestampGap = "Timestamp gap", timestampDup = "Duplicate timestamp", avLength = "Audio/video length",
             audioDropout = "Audio dropout", audioClick = "Audio click", audioClipping = "Audio clipping", audioSilent = "Silent channel",
             decodeError = "Decode problem", sync = "Sound vs picture"
    }
    struct Finding: Identifiable {
        let id = UUID()
        let kind: Kind
        let severity: Severity
        let frame: Int           // first frame concerned (video findings) or the frame at that time (audio findings)
        let count: Int           // frames in the run
        let time: Double         // s
        let detail: String
        var channel: Int? = nil
    }
    struct Features {            // per frame, from a 320×180 downscale
        var r: [Float] = [], g: [Float] = [], b: [Float] = []   // channel means 0–255
        var std: [Float] = []                                   // gray standard deviation
        var rows: [Float] = []                                  // 180 gray row means per frame, frame-major
        var rstd: [Float] = []                                  // 180 gray row standard deviations, frame-major
        var tiles: [Float] = []                                 // 16×9 gray tile means per frame, frame-major
        var tstd: [Float] = []                                  // 16×9 gray tile standard deviations, frame-major
        var cols: [UInt8] = []                                  // per frame, the mean of every source row (full height), frame-major
        var colH = 0
        var count = 0
        var exitStatus: Int32 = 0
    }
    static let W = 320, H = 180, TX = 16, TY = 9
    struct Info {
        var width = 0, height = 0, fps = 24.0, frames = 0, duration = 0.0, codec = "", pixFmt = ""
        var audioStreams: [(index: Int, channels: Int, rate: Int, codec: String, duration: Double)] = []
        var videoIndex = 0
        var startTimecode: String? = nil
    }
    struct Report {
        var info = Info()
        var findings: [Finding] = []
        var framesAnalysed = 0
        var audioSeconds = 0.0
        var notes: [String] = []
        var errors: Int { findings.filter { $0.severity == .error }.count }
        var warnings: Int { findings.filter { $0.severity == .warning }.count }
    }

    // MARK: probing

    static func probe(_ url: URL) -> Info? {
        guard let ffprobe = Tools.ffprobe,
              let d = Tools.runSync(ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path]),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let streams = j["streams"] as? [[String: Any]] else { return nil }
        var info = Info()
        let fmt = j["format"] as? [String: Any]
        info.duration = Double(fmt?["duration"] as? String ?? "") ?? 0
        if let tags = fmt?["tags"] as? [String: Any], let tc = tags["timecode"] as? String { info.startTimecode = tc }
        for s in streams {
            let type = s["codec_type"] as? String ?? ""
            let idx = s["index"] as? Int ?? 0
            let tags = s["tags"] as? [String: Any]
            if type == "video", (s["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1, info.width == 0 {
                info.videoIndex = idx
                info.width = s["width"] as? Int ?? 0; info.height = s["height"] as? Int ?? 0
                info.codec = s["codec_name"] as? String ?? ""; info.pixFmt = s["pix_fmt"] as? String ?? ""
                let r = (s["r_frame_rate"] as? String ?? "").split(separator: "/").compactMap { Double($0) }
                if r.count == 2, r[1] > 0 { info.fps = r[0] / r[1] }
                if let n = Int(s["nb_frames"] as? String ?? "") { info.frames = n }
                if let dur = Double(s["duration"] as? String ?? ""), dur > 0, info.duration == 0 { info.duration = dur }
                if let tc = tags?["timecode"] as? String { info.startTimecode = tc }
            } else if type == "audio" {
                info.audioStreams.append((idx, s["channels"] as? Int ?? 0, Int(s["sample_rate"] as? String ?? "") ?? 48000,
                                          s["codec_name"] as? String ?? "", Double(s["duration"] as? String ?? "") ?? 0))
            } else if type == "data", (s["codec_tag_string"] as? String) == "tmcd", let tc = tags?["timecode"] as? String {
                info.startTimecode = tc
            }
        }
        if info.frames == 0, info.duration > 0 { info.frames = Int((info.duration * info.fps).rounded()) }
        return info.width > 0 ? info : nil
    }

    static func timecode(frame: Int, fps: Double, start: String?) -> String {
        let f = Int(fps.rounded())
        var base = 0
        if let s = start {
            let p = s.replacingOccurrences(of: ";", with: ":").split(separator: ":").compactMap { Int($0) }
            if p.count == 4 { base = ((p[0] * 60 + p[1]) * 60 + p[2]) * f + p[3] }
        }
        let n = base + frame
        return String(format: "%02d:%02d:%02d:%02d", n / (3600 * f) % 24, n / (60 * f) % 60, n / f % 60, n % f)
    }

    // MARK: the frame pass

    /// Decodes the whole picture once: 320×180 RGB frames on stdout for the statistics, and through a FIFO one column
    /// per frame with the mean of every source row (full height), so a line a few pixels tall is still visible.
    static func features(url: URL, index: Int, height: Int, cancel: CancelFlag, progress: (Int) -> Void) -> Features? {
        guard let ffmpeg = Tools.ffmpeg else { return nil }
        let colH = max(16, min(height, 1080))                      // a 1 px line at 2160 is still a half-level row at 1080
        let fifo = NSTemporaryDirectory() + "brosmux_qc_\(getpid())_\(UInt32.random(in: 0...UInt32.max)).fifo"
        guard mkfifo(fifo, 0o600) == 0 else { return nil }
        defer { unlink(fifo) }
        // An anchor open for reading and writing keeps a reader and a writer on the FIFO, so neither ffmpeg's open of
        // its side nor our reader's can block. It is closed after ffmpeg exits; then the reader drains and sees EOF.
        let anchor = open(fifo, O_RDWR)
        guard anchor >= 0 else { return nil }
        var anchorOpen = true
        defer { if anchorOpen { close(anchor) } }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostdin", "-v", "error", "-i", url.path, "-fps_mode", "passthrough",
                       "-filter_complex", "[0:\(index)]split=2[a][b];[a]scale=\(W):\(H):flags=area,format=rgb24[a];[b]scale=1:\(colH):flags=area,format=gray[b]",
                       "-map", "[a]", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
                       "-map", "[b]", "-f", "rawvideo", "-pix_fmt", "gray", "-y", fifo]
        p.standardInput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        // the column reader drains the FIFO on its own thread until EOF (the anchor is closed after ffmpeg exits)
        var colData = Data(); let colLock = NSLock(); let colDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = open(fifo, O_RDONLY)
            if fd >= 0 {
                let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                while true {
                    let d = fh.readData(ofLength: 1 << 20)
                    if d.isEmpty { break }
                    colLock.lock(); colData.append(d); colLock.unlock()
                }
            }
            colDone.signal()
        }
        let h = pipe.fileHandleForReading
        let bytes = W * H * 3
        var f = Features()
        f.r.reserveCapacity(100_000); f.g.reserveCapacity(100_000); f.b.reserveCapacity(100_000); f.std.reserveCapacity(100_000)
        var buf = Data()
        var rowAcc = [Float](repeating: 0, count: H), rowStd = [Float](repeating: 0, count: H)
        var tileAcc = [Float](repeating: 0, count: TX * TY), tileSq = [Double](repeating: 0, count: TX * TY)
        let tw = W / TX, th = H / TY
        while true {
            if cancel.isSet { p.terminate(); try? h.close(); break }      // closing our end unblocks ffmpeg's write, or it never exits
            let d = h.readData(ofLength: bytes * 24)
            if d.isEmpty { break }
            buf.append(d)
            var off = 0
            buf.withUnsafeBytes { raw in
                let px = raw.bindMemory(to: UInt8.self)
                while off + bytes <= buf.count {
                    var sr = 0, sg = 0, sb = 0
                    var sq: Double = 0
                    for i in 0..<H { rowAcc[i] = 0 }
                    for i in 0..<(TX * TY) { tileAcc[i] = 0; tileSq[i] = 0 }
                    var o = off
                    for y in 0..<H {
                        var rowSum = 0, rowSq = 0
                        let ty = y / th
                        for x in 0..<W {
                            let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                            sr += r; sg += g; sb += b
                            let gray = (r + g + g + b) >> 2        // cheap luma
                            rowSum += gray; rowSq += gray * gray
                            sq += Double(gray * gray)
                            let tk = ty * TX + x / tw
                            tileAcc[tk] += Float(gray); tileSq[tk] += Double(gray * gray)
                            o += 3
                        }
                        rowAcc[y] = Float(rowSum) / Float(W)
                        let rm = Double(rowSum) / Double(W)
                        rowStd[y] = Float(max(0, Double(rowSq) / Double(W) - rm * rm).squareRoot())
                    }
                    let n = Double(W * H)
                    let mean = Double(sr + sg + sg + sb) / 4 / n
                    f.r.append(Float(Double(sr) / n)); f.g.append(Float(Double(sg) / n)); f.b.append(Float(Double(sb) / n))
                    f.std.append(Float(max(0, sq / n - mean * mean).squareRoot()))
                    f.rows.append(contentsOf: rowAcc); f.rstd.append(contentsOf: rowStd)
                    let tn = Double(tw * th)
                    for i in 0..<(TX * TY) {
                        tileAcc[i] /= Float(tw * th)
                        let m = Double(tileAcc[i])
                        f.tstd.append(Float(max(0, tileSq[i] / tn - m * m).squareRoot()))
                    }
                    f.tiles.append(contentsOf: tileAcc)
                    f.count += 1
                    off += bytes
                }
            }
            if off > 0 { buf.removeSubrange(0..<off) }
            progress(f.count)
        }
        p.waitUntilExit()
        f.exitStatus = p.terminationStatus
        close(anchor); anchorOpen = false                          // the last writer is gone: the reader sees EOF
        colDone.wait()
        colLock.lock()
        f.colH = colH
        f.cols = [UInt8](colData.prefix(f.count * colH))
        colLock.unlock()
        return f
    }

    // MARK: the picture checks

    static func pictureFindings(_ f: Features, fps: Double) -> [Finding] {
        var out: [Finding] = []
        let n = f.count
        guard n > 2 else { return out }
        func t(_ i: Int) -> Double { Double(i) / fps }
        let T = TX * TY
        // frame-to-frame tile differences
        var dprev = [Float](repeating: 0, count: n)          // mean |tile diff| vs the previous frame
        for i in 1..<n {
            var s: Float = 0
            for k in 0..<T { s += abs(f.tiles[i * T + k] - f.tiles[(i - 1) * T + k]) }
            dprev[i] = s / Float(T)
        }
        // 1. solid frames (green, magenta, black, white, red, other) in runs
        enum Solid { case none, black, white, green, magenta, red, other }
        func solid(_ i: Int) -> Solid {
            let r = f.r[i], g = f.g[i], b = f.b[i], sd = f.std[i], m = (r + 2 * g + b) / 4
            if sd < 3 && m < 8 { return .black }
            if sd < 3 && m > 246 { return .white }
            if sd < 12 && g - max(r, b) > 40 { return .green }
            if sd < 12 && r > g + 40 && b > g + 40 { return .magenta }
            if sd < 45 && r > 120 && r - max(g, b) > 50 { return .red }
            if sd < 2.5 { return .other }
            return .none
        }
        var i = 0
        while i < n {
            let s = solid(i)
            if s == .none { i += 1; continue }
            var j = i
            while j + 1 < n && solid(j + 1) == s { j += 1 }
            let len = j - i + 1
            let before = i > 0 ? i - 1 : nil, after = j + 1 < n ? j + 1 : nil
            let contentBefore = before.map { f.std[$0] > 8 } ?? false, contentAfter = after.map { f.std[$0] > 8 } ?? false
            let atEdge = i == 0 || j == n - 1
            switch s {
            case .green:
                out.append(Finding(kind: .greenFrame, severity: .error, frame: i, count: len, time: t(i),
                                   detail: String(format: "%d solid green frame%@ (R %.0f G %.0f B %.0f) — a GPU/decode failure in the render", len, len == 1 ? "" : "s", f.r[i], f.g[i], f.b[i])))
            case .magenta:
                out.append(Finding(kind: .magentaFrame, severity: .error, frame: i, count: len, time: t(i),
                                   detail: String(format: "%d solid magenta frame%@ (R %.0f G %.0f B %.0f) — a missing texture or decode failure", len, len == 1 ? "" : "s", f.r[i], f.g[i], f.b[i])))
            case .red:
                out.append(Finding(kind: .mediaOffline, severity: .error, frame: i, count: len, time: t(i),
                                   detail: String(format: "%d red frame%@ (R %.0f G %.0f B %.0f) — looks like Resolve's “Media Offline” card; confirm on the frame", len, len == 1 ? "" : "s", f.r[i], f.g[i], f.b[i])))
            case .black:
                if atEdge {
                    out.append(Finding(kind: .blackFrame, severity: .info, frame: i, count: len, time: t(i),
                                       detail: String(format: "%.2f s of black at the %@", Double(len) / fps, i == 0 ? "head" : "tail")))
                } else if len <= 3 && contentBefore && contentAfter {
                    let fade = before.map { f.rows.count > 0 && (f.r[$0] + 2 * f.g[$0] + f.b[$0]) / 4 < 25 } ?? false
                    out.append(Finding(kind: .blackFrame, severity: fade ? .warning : .error, frame: i, count: len, time: t(i),
                                       detail: String(format: "%d black frame%@ between two shots with content%@", len, len == 1 ? "" : "s", fade ? " (the shot before is already dark: may be a very short fade)" : " — a gap in the timeline or a dropped frame")))
                } else {
                    out.append(Finding(kind: .blackFrame, severity: .info, frame: i, count: len, time: t(i),
                                       detail: String(format: "%.2f s of black inside the programme (a fade or a planned black?)", Double(len) / fps)))
                }
            case .white:
                out.append(Finding(kind: .whiteFrame, severity: len <= 2 ? .warning : .info, frame: i, count: len, time: t(i),
                                   detail: String(format: "%d white frame%@%@", len, len == 1 ? "" : "s", len <= 2 ? " — a flash frame; intended?" : "")))
            case .other:
                if !atEdge {
                    out.append(Finding(kind: .solidFrame, severity: len <= 2 && contentBefore && contentAfter ? .error : .info, frame: i, count: len, time: t(i),
                                       detail: String(format: "%d flat frame%@ of one colour (R %.0f G %.0f B %.0f)", len, len == 1 ? "" : "s", f.r[i], f.g[i], f.b[i])))
                }
            case .none: break
            }
            i = j + 1
        }
        // 2. a frame repeated inside motion (a dropped frame rendered twice). Several of them close together are the
        //    cadence of footage converted from another frame rate (30→24, 25→24), which is the source, not the render.
        var repeats: [(frame: Int, len: Int)] = []
        i = 1
        while i < n - 1 {
            if dprev[i] < 0.15, dprev[i - 1] > 0.6, dprev[i + 1] > 0.6, dprev[i] < min(dprev[i - 1], dprev[i + 1]) / 8, f.std[i] > 8 {
                var j = i
                while j + 1 < n - 1 && dprev[j + 1] < 0.15 { j += 1 }
                let len = j - i + 1
                if len <= 3 && dprev[j + 1] > 0.6 { repeats.append((i, len)) }
                i = j + 1
            } else { i += 1 }
        }
        var k = 0
        while k < repeats.count {
            var m = k
            while m + 1 < repeats.count && Double(repeats[m + 1].frame - repeats[m].frame) / fps < 3 { m += 1 }
            let group = repeats[k...m]
            if group.count >= 3 {
                let first = group.first!.frame, last = group.last!.frame
                out.append(Finding(kind: .frozenFrame, severity: .info, frame: first, count: last - first + 1, time: t(first),
                                   detail: String(format: "%d repeated frames between %@ and %@ (one every %.1f frames): the cadence of footage converted from another frame rate — the source, not the render", group.count,
                                                  timecode(frame: first, fps: fps, start: nil), timecode(frame: last, fps: fps, start: nil), Double(last - first) / Double(max(1, group.count - 1)))))
            } else {
                for r in group {
                    out.append(Finding(kind: .frozenFrame, severity: r.len == 1 ? .warning : .error, frame: r.frame, count: r.len, time: t(r.frame),
                                       detail: String(format: "frame %d repeats frame %d (%d time%@) while the shot is moving — a dropped or duplicated frame", r.frame, r.frame - 1, r.len, r.len == 1 ? "" : "s")))
                }
            }
            k = m + 1
        }
        // 3. localized transients: a flat band, line or block that appears for one frame and goes away.
        //    Only FLAT patches count (no texture inside): a flash of light on real texture is content, not a fault.
        var medDiff = [Float](repeating: 0, count: n)                      // median tile change per frame (big = a cut)
        var a = [Float](repeating: 0, count: T)
        for i in 1..<n {
            for k in 0..<T { a[k] = abs(f.tiles[i * T + k] - f.tiles[(i - 1) * T + k]) }
            medDiff[i] = a.sorted()[T / 2]
        }
        for i in 1..<(n - 1) {
            guard medDiff[i] < 6, medDiff[i + 1] < 25, i < 2 || medDiff[i - 1] < 25 else { continue }   // not on or next to a cut
            var hot: [Int] = []
            for k in 0..<T {
                let cur = f.tiles[i * T + k], pv = f.tiles[(i - 1) * T + k], nx = f.tiles[(i + 1) * T + k]
                let a = abs(cur - pv), b = abs(cur - nx), c = abs(pv - nx)
                // perfectly flat (a rendered block is flat to the bit; a blurred white wall is not), far from both neighbours
                let flatNow = f.tstd[i * T + k] < 2, texturedAround = max(f.tstd[(i - 1) * T + k], f.tstd[(i + 1) * T + k]) > 6
                if a > 40 && b > 40 && c < min(a, b) / 3 && flatNow && (texturedAround || a > 60) { hot.append(k) }
            }
            if hot.count >= 4 && hot.count <= T * 6 / 10 {
                let rowsHit = Set(hot.map { $0 / TX })
                let fullRows = rowsHit.filter { r in (0..<TX).allSatisfy { x in hot.contains(r * TX + x) } }
                if !fullRows.isEmpty {
                    out.append(Finding(kind: .bandArtifact, severity: .error, frame: i, count: 1, time: t(i),
                                       detail: String(format: "a flat horizontal band for one frame across the full width: tile row%@ %@ of %d", fullRows.count == 1 ? "" : "s", fullRows.sorted().map(String.init).joined(separator: ","), TY)))
                } else if hot.allSatisfy({ f.tiles[i * T + $0] >= 250 }) {
                    // every flat tile is clipped white: a photographic flash or a blown-out first frame of archive footage, not garbage
                    out.append(Finding(kind: .blockArtifact, severity: .info, frame: i, count: 1, time: t(i),
                                       detail: String(format: "%d of %d tiles go pure white for one frame and come back (rows %@) — a camera flash or a blown-out frame of archive footage; a render fault is rarely pure white", hot.count, T, rowsHit.sorted().map(String.init).joined(separator: ","))))
                } else {
                    out.append(Finding(kind: .blockArtifact, severity: hot.count >= 6 ? .error : .warning, frame: i, count: 1, time: t(i),
                                       detail: String(format: "%d of %d tiles turn into a flat patch for one frame and come back (rows %@) — a block of garbage or a missing texture", hot.count, T,
                                                      rowsHit.sorted().map(String.init).joined(separator: ","))))
                }
                continue
            }
            // a band or a line: rows that are flat across the whole width for this frame only, while the frames
            // around agree with each other (real pictures are never flat across 4096 pixels)
            var lineRows = 0, firstRow = -1, lastRow = -1
            for y in 0..<H {
                let cur = f.rows[i * H + y], pv = f.rows[(i - 1) * H + y], nx = f.rows[(i + 1) * H + y]
                if abs(cur - pv) > 20 && abs(cur - nx) > 20 && abs(pv - nx) < 6 && f.rstd[i * H + y] < 4 && max(f.rstd[(i - 1) * H + y], f.rstd[(i + 1) * H + y]) > 6 {
                    lineRows += 1; if firstRow < 0 { firstRow = y }; lastRow = y
                }
            }
            if lineRows >= 3 && lineRows <= H * 6 / 10 {
                let px = Double(lineRows) / Double(H)
                out.append(Finding(kind: .bandArtifact, severity: .error, frame: i, count: 1, time: t(i),
                                   detail: String(format: "a flat band across the full width for one frame: rows %d–%d of %d (about %.0f%% of the height)", firstRow, lastRow, H, px * 100)))
            }
        }
        // 4. thin lines, from the full-height column of row means: a row that jumps away from its neighbours in this
        //    frame only, with nothing like it within ±12 rows in the frames before and after (a moving edge would show there)
        let CH = f.colH
        if CH > 16 && f.cols.count >= n * CH {
            func dev(_ i: Int, _ y: Int) -> Float {
                let base = i * CH
                let lo = max(0, y - 3), hi = min(CH - 1, y + 3)
                var around: [Float] = []
                for r in lo...hi where r != y { around.append(Float(f.cols[base + r])) }
                around.sort()
                return Float(f.cols[base + y]) - around[around.count / 2]
            }
            var lastLine = -100
            for i in 1..<(n - 1) {
                guard medDiff[i] < 6, medDiff[i + 1] < 25, i < 2 || medDiff[i - 1] < 25, i - lastLine > 1 else { continue }
                if out.contains(where: { $0.kind == .bandArtifact && $0.frame == i }) { continue }   // the band's own edge is not a second fault
                var best: Float = 0, bestY = -1
                for y in 3..<(CH - 3) {
                    let d = abs(dev(i, y))
                    if d > best { best = d; bestY = y }
                }
                guard best >= 30, bestY >= 0 else { continue }
                var nearby: Float = 0
                for y in max(3, bestY - 12)...min(CH - 4, bestY + 12) { nearby = max(nearby, abs(dev(i - 1, y)), abs(dev(i + 1, y))) }
                guard nearby < max(10, best / 4) else { continue }        // the rows around it were quiet before and after, relative to the line
                // and the picture around the line did not move between the neighbouring frames: a line drawn on a still
                // picture is a render fault; a bright edge that appears with a cut or a fade inside a window is content
                var moved: Float = 0
                for y in max(3, bestY - 12)...min(CH - 4, bestY + 12) where abs(y - bestY) > 2 {
                    let cur = Float(f.cols[i * CH + y])
                    moved = max(moved, abs(cur - Float(f.cols[(i - 1) * CH + y])), abs(cur - Float(f.cols[(i + 1) * CH + y])))
                }
                guard moved < max(8, best / 6) else { continue }
                // how tall: contiguous rows with at least half the deviation
                var top = bestY, bottom = bestY
                while top > 3 && abs(dev(i, top - 1)) >= best / 2 { top -= 1 }
                while bottom < CH - 4 && abs(dev(i, bottom + 1)) >= best / 2 { bottom += 1 }
                lastLine = i
                out.append(Finding(kind: .bandArtifact, severity: .error, frame: i, count: 1, time: t(i),
                                   detail: String(format: "a horizontal line across the picture for one frame: rows %d–%d of %d (%d px tall, %+.0f levels against the rows around it)", top, bottom, CH, bottom - top + 1, dev(i, bestY))))
            }
        }
        return out.sorted { $0.frame < $1.frame }
    }

    // MARK: timestamps

    static func timestampFindings(url: URL, index: Int, fps: Double) -> (findings: [Finding], packets: Int) {
        guard let ffprobe = Tools.ffprobe, fps > 0,
              let d = Tools.runSync(ffprobe, ["-v", "error", "-select_streams", "\(index)", "-show_entries", "packet=pts_time", "-of", "csv=p=0", url.path]),
              let txt = String(data: d, encoding: .utf8) else { return ([], 0) }
        var pts = txt.split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ",\r "))) }
        pts.sort()
        var out: [Finding] = []
        let frame = 1 / fps
        var gaps = 0, dups = 0
        for i in 1..<max(1, pts.count) {
            let d = pts[i] - pts[i - 1]
            if d > frame * 1.5 {
                gaps += 1
                if gaps <= 20 { out.append(Finding(kind: .timestampGap, severity: .error, frame: i, count: Int((d / frame).rounded()) - 1, time: pts[i - 1],
                                                   detail: String(format: "%.3f s between two frames (%.1f frames): frames missing in the stream", d, d / frame))) }
            } else if d < frame * 0.5 {
                dups += 1
                if dups <= 20 { out.append(Finding(kind: .timestampDup, severity: .warning, frame: i, count: 1, time: pts[i],
                                                   detail: String(format: "two frames %.3f s apart (less than half a frame)", d))) }
            }
        }
        if gaps > 20 || dups > 20 { out.append(Finding(kind: .timestampGap, severity: .error, frame: 0, count: 0, time: 0, detail: "\(gaps) gaps and \(dups) near-duplicates in all; only the first 20 of each are listed")) }
        return (out, pts.count)
    }

    // MARK: audio

    static func audioFindings(url: URL, index: Int, channels: Int, rate: Int, fps: Double, cancel: CancelFlag, progress: (Double) -> Void) -> (findings: [Finding], seconds: Double) {
        guard let ffmpeg = Tools.ffmpeg, channels > 0 else { return ([], 0) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostdin", "-v", "error", "-i", url.path, "-map", "0:\(index)", "-f", "f32le", "-"]
        p.standardInput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return ([], 0) }
        let h = pipe.fileHandleForReading
        let ch = channels, sr = Double(rate)
        var out: [Finding] = []
        var zeroRun = [Int](repeating: 0, count: ch), clipRun = [Int](repeating: 0, count: ch)
        var last = [Float](repeating: 0, count: ch)
        var energy = [Double](repeating: 0, count: ch)            // running RMS (100 ms)
        var peakAll = [Float](repeating: 0, count: ch)
        var lastClick = [Int](repeating: -1_000_000, count: ch), lastDrop = [Int](repeating: -1_000_000, count: ch), lastClip = [Int](repeating: -1_000_000, count: ch)
        var clicks = 0, drops = 0, clips = 0
        var dropEvents: [(sample: Int, channel: Int, run: Int, level: Double)] = []
        var n = 0                                                  // sample frames read
        var buf = Data()
        let frameBytes = ch * 4
        let alpha = 1 / (0.1 * sr)
        while true {
            if cancel.isSet { p.terminate(); try? h.close(); break }
            let d = h.readData(ofLength: 1 << 20)
            if d.isEmpty { break }
            buf.append(d)
            let frames = buf.count / frameBytes
            buf.withUnsafeBytes { raw in
                let x = raw.bindMemory(to: Float.self)
                for k in 0..<frames {
                    for c in 0..<ch {
                        let v = x[k * ch + c], a = abs(v)
                        if a > peakAll[c] { peakAll[c] = a }
                        let e = energy[c]
                        // dropout: exact digital zero for ≥ 2 ms while the signal just before was alive. The level is frozen
                        // during a run of zeros, so a long hole is judged by what played before it, not by a decayed value.
                        if a < 1e-7 {
                            zeroRun[c] += 1
                        } else {
                            energy[c] = e + (Double(v * v) - e) * alpha
                            if zeroRun[c] >= Int(0.002 * sr), e > 3.2e-5, n - lastDrop[c] > Int(0.5 * sr) {
                                drops += 1; lastDrop[c] = n
                                if dropEvents.count < 400 { dropEvents.append((n - zeroRun[c], c, zeroRun[c], e)) }
                            }
                            zeroRun[c] = 0
                        }
                        // click: a sample jump far above the local level
                        let jump = abs(v - last[c])
                        let rms = e.squareRoot()
                        if jump > 0.25, Double(jump) > 12 * rms + 0.02, n - lastClick[c] > Int(0.05 * sr) {
                            clicks += 1; lastClick[c] = n
                            if clicks <= 30 { out.append(Finding(kind: .audioClick, severity: .warning, frame: Int(Double(n) / sr * fps), count: 0, time: Double(n) / sr,
                                                                 detail: String(format: "a %.2f full-scale jump between two samples in channel %d (local level %.0f dBFS) — a click or a discontinuity", jump, c + 1, 20 * log10(rms + 1e-9)), channel: c)) }
                        }
                        last[c] = v
                        // clipping: several consecutive samples at full scale
                        if a >= 0.999 { clipRun[c] += 1 } else {
                            if clipRun[c] >= 4, n - lastClip[c] > Int(1.0 * sr) {
                                clips += 1; lastClip[c] = n
                                if clips <= 30 { out.append(Finding(kind: .audioClipping, severity: .warning, frame: Int(Double(n) / sr * fps), count: 0, time: Double(n) / sr,
                                                                    detail: String(format: "%d consecutive samples at full scale in channel %d", clipRun[c], c + 1), channel: c)) }
                            }
                            clipRun[c] = 0
                        }
                    }
                    n += 1
                }
            }
            buf.removeSubrange(0..<(frames * frameBytes))
            progress(Double(n) / sr)
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 && !cancel.isSet {
            out.append(Finding(kind: .decodeError, severity: .error, frame: Int(Double(n) / sr * fps), count: 0, time: Double(n) / sr,
                               detail: String(format: "the audio decode stopped after %.1f s (ffmpeg exit code %d): the track may be truncated or corrupt", Double(n) / sr, p.terminationStatus)))
        }
        // group the zero runs: the same moment in several channels = a real dropout; one channel alone = a clip boundary
        var used = [Bool](repeating: false, count: dropEvents.count)
        for (a, ev) in dropEvents.enumerated() where !used[a] {
            var channels = Set([ev.channel]); var longest = ev.run; var loudest = ev.level
            for b in (a + 1)..<max(a + 1, dropEvents.count) where !used[b] && abs(dropEvents[b].sample - ev.sample) < Int(0.02 * sr) {
                used[b] = true; channels.insert(dropEvents[b].channel); longest = max(longest, dropEvents[b].run); loudest = max(loudest, dropEvents[b].level)
            }
            let ms = Double(longest) / sr * 1000
            // Severity by how much of the mix goes away. One channel at zero (an empty LFE for a minute, a surround between
            // two clips) is how a mix is built; most channels at once during a black is a mix decision; EVERY channel
            // at zero while the track was playing is the render dropping out.
            let lfeIndex = (ch == 6 || ch == 8) ? 3 : -1
            let playing = Set((0..<ch).filter { $0 != lfeIndex })
            let all = channels.isSuperset(of: playing)
            let wide = channels.count >= max(2, (ch + 1) / 2)
            let sev: Severity = all ? (ms >= 5 ? .error : .warning) : wide ? (ms >= 20 ? .warning : .info) : .info
            let note = all ? "" : wide ? " — the other channels keep playing: a mix decision unless the picture drops too"
                : channels == [lfeIndex] ? " — the LFE alone: it carries nothing here, which is normal"
                : " — in one channel only: usually the gap between two clips of the mix, not a fault"
            if out.filter({ $0.kind == .audioDropout }).count < 30 {
                out.append(Finding(kind: .audioDropout, severity: sev, frame: Int(Double(ev.sample) / sr * fps), count: 0, time: Double(ev.sample) / sr,
                                   detail: String(format: "%.1f ms of digital silence in %@ (%.0f dBFS just before)%@", ms,
                                                  channels.count == 1 ? "channel \(ev.channel + 1)" : all ? "every channel" : "\(channels.count) of \(ch) channels at once", 10 * log10(loudest + 1e-12), note), channel: ev.channel))
            }
        }
        for c in 0..<ch where peakAll[c] < 1e-6 && n > 0 {
            out.append(Finding(kind: .audioSilent, severity: .info, frame: 0, count: 0, time: 0, detail: "channel \(c + 1) is completely silent", channel: c))
        }
        if clicks > 30 || drops > 30 || clips > 30 { out.append(Finding(kind: .audioClick, severity: .warning, frame: 0, count: 0, time: 0, detail: "\(drops) dropouts, \(clicks) clicks and \(clips) clipping runs in all; only the first 30 of each are listed")) }
        return (out, Double(n) / sr)
    }

    // MARK: Media Offline confirmation (text on a red frame)

    static func readText(url: URL, index: Int, frame: Int, fps: Double) -> [String] {
        guard let ffmpeg = Tools.ffmpeg else { return [] }
        let ss = (Double(frame) - PictureSync.seekBefore) / fps   // a quarter frame early: the first frame out is `frame` (PictureSync.seekBefore)
        let w = 960, h = 540
        guard let d = Tools.runSync(ffmpeg, ["-nostdin", "-v", "error", "-ss", String(format: "%.6f", max(0, ss)), "-i", url.path, "-map", "0:\(index)", "-fps_mode", "passthrough",
                                              "-frames:v", "1", "-vf", "scale=\(w):\(h),format=gray", "-f", "rawvideo", "-pix_fmt", "gray", "-"]), d.count >= w * h,
              let provider = CGDataProvider(data: d.subdata(in: 0..<(w * h)) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return [] }
        let req = VNRecognizeTextRequest(); req.recognitionLevel = .fast; req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    // MARK: everything

    static func run(url: URL, cancel: CancelFlag, sync: Bool = true, progress: (String, Double) -> Void) -> Report? {
        guard let info = probe(url) else { return nil }
        var rep = Report(info: info)
        progress("Reading every frame…", 0)
        let total = max(1, info.frames)
        guard let f = features(url: url, index: info.videoIndex, height: info.height, cancel: cancel, progress: { n in progress("Reading every frame… \(n) of \(total)", Double(n) / Double(total) * 0.75) }) else { return nil }
        if cancel.isSet { return nil }
        rep.framesAnalysed = f.count
        var findings: [Finding] = []
        if f.exitStatus != 0 || (info.frames > 0 && Double(f.count) < Double(info.frames) * 0.99) {
            findings.append(Finding(kind: .decodeError, severity: .error, frame: f.count, count: 0, time: Double(f.count) / info.fps,
                                    detail: f.exitStatus != 0 ? "the picture decode stopped at frame \(f.count) (ffmpeg exit code \(f.exitStatus)): the file may be truncated or corrupt"
                                                              : "only \(f.count) of the \(info.frames) frames the container declares could be decoded"))
        }
        findings += pictureFindings(f, fps: info.fps)
        // confirm Media Offline cards by reading their text
        for (k, fd) in findings.enumerated() where fd.kind == .mediaOffline {
            let words = readText(url: url, index: info.videoIndex, frame: fd.frame, fps: info.fps).joined(separator: " ").lowercased()
            if words.contains("offline") || words.contains("media") {
                findings[k] = Finding(kind: .mediaOffline, severity: .error, frame: fd.frame, count: fd.count, time: fd.time, detail: "Resolve's “Media Offline” card (text read on the frame: \(words.prefix(60)))")
            } else {
                findings[k] = Finding(kind: .solidFrame, severity: .info, frame: fd.frame, count: fd.count, time: fd.time,
                                      detail: String(format: "%d flat red/orange frame%@ (no “Media Offline” text on it%@)", fd.count, fd.count == 1 ? "" : "s", words.isEmpty ? "" : "; text read: \(words.prefix(40))"))
            }
        }
        progress("Checking timestamps…", 0.78)
        let ts = timestampFindings(url: url, index: info.videoIndex, fps: info.fps)
        findings += ts.findings
        if ts.packets > 0 && abs(ts.packets - f.count) > 0 { rep.notes.append("\(ts.packets) video packets in the file, \(f.count) frames decoded") }
        if info.frames > 0 && f.count != info.frames { rep.notes.append("the container declares \(info.frames) frames, \(f.count) were decoded") }
        for (k, a) in info.audioStreams.enumerated() {
            if cancel.isSet { return nil }
            let r = audioFindings(url: url, index: a.index, channels: a.channels, rate: a.rate, fps: info.fps, cancel: cancel) { s in
                progress("Listening to audio track \(k + 1) of \(info.audioStreams.count)…", 0.8 + 0.12 * (Double(k) + min(1, s / max(1, info.duration))) / Double(info.audioStreams.count))
            }
            findings += r.findings.map { fd in var x = fd; x = Finding(kind: fd.kind, severity: fd.severity, frame: fd.frame, count: fd.count, time: fd.time, detail: "track \(k + 1): " + fd.detail, channel: fd.channel); return x }
            rep.audioSeconds = max(rep.audioSeconds, r.seconds)
            let videoSeconds = Double(f.count) / info.fps
            if abs(r.seconds - videoSeconds) > 1.5 / info.fps {
                findings.append(Finding(kind: .avLength, severity: abs(r.seconds - videoSeconds) > 0.5 ? .warning : .info, frame: 0, count: 0, time: min(r.seconds, videoSeconds),
                                        detail: String(format: "audio track %d lasts %.3f s, the picture %.3f s (%+.1f frames)", k + 1, r.seconds, videoSeconds, (r.seconds - videoSeconds) * info.fps)))
            }
        }
        // the sound against the picture itself (PictureSync.swift): hard cuts vs sound hits, and the alignment meter —
        // how much of the film is aligned and where it drifts
        if sync, info.duration > 20, !info.audioStreams.isEmpty {
            let segs = PictureSync.segments(duration: info.duration, points: 16, window: 20)
            let cuts = PictureSync.detectCuts(video: url, index: info.videoIndex, fps: info.fps, segments: segs, cancel: cancel) { p in
                progress("Checking the sound against the picture: hard cuts…", 0.92 + 0.06 * p)
            }
            if cancel.isSet { return nil }
            for (k, a) in info.audioStreams.prefix(2).enumerated() {
                progress("Checking the sound against the picture: track \(k + 1)…", 0.98)
                let src = SyncEngine.Source(url: url, index: a.index, duration: a.duration, channels: a.channels)
                let r = PictureSync.match(cuts: cuts, curves: PictureSync.curvesFor(src, segments: segs, shift: 0), fps: info.fps, duration: info.duration)
                if cancel.isSet { return nil }
                let severity: Severity
                if let o = r.offset {
                    let frac = r.meter?.alignedFraction ?? 1
                    severity = !Alignment.ok(o) ? .error : frac >= 0.95 ? .info : .warning
                } else { severity = .info }
                let t0 = r.meter?.drifts.first?.from ?? 0
                findings.append(Finding(kind: .sync, severity: severity, frame: Int(t0 * info.fps), count: 0, time: t0, detail: "track \(k + 1): " + r.message))
            }
        }
        rep.findings = findings.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.time < $1.time }
        return rep
    }
}
