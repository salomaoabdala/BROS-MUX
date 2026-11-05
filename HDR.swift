// BROS-MUX — HDR playback versions: Dolby Vision 8.1 + HDR10 + HDR10+ from a master (IMF package or HDR ProRes).
// Masters (ProRes / JPEG 2000 + the colorist's Dolby Vision metadata) don't play on TVs or Apple devices. Playback files
// are HEVC 10-bit with the Dolby Vision metadata (RPU) and the HDR10+ metadata inside the video stream — so here, unlike
// the rest of BROS-MUX, the picture IS re-encoded (x265). The audio still goes through the normal bit-exact path.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

extension Tools {
    static let doviTool = find("dovi_tool")
    static let hdr10plusTool = find("hdr10plus_tool")

    /// Runs a program and returns its exit code with stdout and stderr together
    static func runAll(_ exe: String, _ args: [String]) -> (status: Int32, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? pipe.fileHandleForReading.close()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// Runs a long program: each stdout line goes to `line`, stderr to `log`; the cancel flag stops it. Returns the exit code.
    static func runStreaming(_ exe: String, _ args: [String], cancel: CancelFlag,
                             line: @escaping (String) -> Void, log: @escaping (String) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let queue = DispatchQueue(label: "bros.stream")
        var pending = ""
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            queue.sync {
                pending += String(decoding: d, as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    line(String(pending[..<nl])); pending = String(pending[pending.index(after: nl)...])
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { log(String(decoding: d, as: UTF8.self)) }
        }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
            log("Couldn't start \(exe): \(error.localizedDescription)\n"); return -1
        }
        while p.isRunning {
            if cancel.isSet { p.terminate() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let rest = out.fileHandleForReading.readDataToEndOfFile()
        queue.sync { pending += String(decoding: rest, as: UTF8.self); if !pending.isEmpty { line(pending); pending = "" } }
        let restErr = err.fileHandleForReading.readDataToEndOfFile()
        if !restErr.isEmpty { log(String(decoding: restErr, as: UTF8.self)) }
        try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
        return p.terminationReason == .exit ? p.terminationStatus : -2
    }
}

extension Fmt {
    /// "6 h 05 min", "42 min", "50 s"
    static func hm(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "—" }
        if s < 60 { return "\(Int(s.rounded())) s" }
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(m) min" : "\(m / 60) h \(String(format: "%02d", m % 60)) min"
    }
}

/// An exact frame rate or edit rate ("24 1", "24000/1001")
struct Rational: Equatable, CustomStringConvertible {
    let num: Int
    let den: Int
    init(_ num: Int, _ den: Int) { self.num = num; self.den = den }
    init?(_ s: String) {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
        if parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), n > 0, d > 0 { num = n; den = d; return }
        guard parts.count == 1, let v = Double(parts[0]), v > 0 else { return nil }
        for (n, d) in [(24000, 1001), (30000, 1001), (60000, 1001)] where abs(v - Double(n) / Double(d)) < 0.01 { num = n; den = d; return }
        num = Int(v.rounded()); den = 1
    }
    var value: Double { den == 0 ? 0 : Double(num) / Double(den) }
    var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }
}

// MARK: - IMF packages (SMPTE ST 2067): ASSETMAP + CPL

struct IMFResource: Equatable {
    let file: URL
    let entryPoint: Int       // first edit unit used, inside the track file
    let duration: Int         // edit units used (SourceDuration)
    let intrinsic: Int        // edit units in the track file
    let repeatCount: Int
    let editRate: Rational
    var frames: Int { duration * repeatCount }
}

enum IMFKind { case image, pcm, iab, dolbyVision, subtitle, other }

struct IMFSequence {
    let kind: IMFKind
    let name: String
    let trackID: String
    var resources: [IMFResource]
    var frames: Int { resources.reduce(0) { $0 + $1.frames } }
}

struct IMFPackage {
    let folder: URL
    let cpl: URL
    let title: String
    let editRate: Rational
    let timecode: String?
    let sequences: [IMFSequence]
    var notes: [String] = []
    func first(_ k: IMFKind) -> IMFSequence? { sequences.first { $0.kind == k } }
    func all(_ k: IMFKind) -> [IMFSequence] { sequences.filter { $0.kind == k } }
}

enum IMF {
    /// The package folder for a dropped folder, ASSETMAP or CPL (nil if it isn't an IMF package)
    static func packageFolder(for url: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        if !isDir.boolValue {
            let n = url.lastPathComponent.uppercased()
            guard url.pathExtension.lowercased() == "xml", n.hasPrefix("ASSETMAP") || n.hasPrefix("CPL") || rootName(url) == "CompositionPlaylist" else { return nil }
        }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.uppercased().hasPrefix("ASSETMAP") } ? folder : nil
    }

    static func rootName(_ url: URL) -> String? {
        (try? XMLDocument(contentsOf: url, options: []))?.rootElement()?.localName
    }

    static func uuid(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "urn:uuid:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func kids(_ e: XMLElement?, _ name: String) -> [XMLElement] {
        (e?.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }
    static func all(_ e: XMLElement?, _ name: String) -> [XMLElement] {
        guard let e else { return [] }
        var out: [XMLElement] = []
        for c in (e.children ?? []).compactMap({ $0 as? XMLElement }) {
            if c.localName == name { out.append(c) }
            out += all(c, name)
        }
        return out
    }
    static func text(_ e: XMLElement?, _ name: String) -> String? {
        kids(e, name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func kind(_ sequenceName: String) -> IMFKind {
        let n = sequenceName.lowercased()
        if n.contains("mainimage") { return .image }
        if n.contains("mainaudio") { return .pcm }
        if n.contains("iab") { return .iab }
        if n.contains("isxd") || n.contains("dolbyvision") || n.contains("dvmetadata") { return .dolbyVision }
        if n.contains("subtitle") || n.contains("timedtext") { return .subtitle }
        return .other
    }

    static func load(_ url: URL) throws -> IMFPackage {
        guard let folder = packageFolder(for: url) else { throw AppError("“\(url.lastPathComponent)” isn't an IMF package (no ASSETMAP.xml next to it).") }
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: folder.path)
        guard let amName = names.first(where: { $0.uppercased().hasPrefix("ASSETMAP") }) else { throw AppError("No ASSETMAP.xml in the IMF package.") }
        let am = try XMLDocument(contentsOf: folder.appendingPathComponent(amName), options: [])
        var assets: [String: URL] = [:]
        for a in all(am.rootElement(), "Asset") {
            guard let id = text(a, "Id"), let path = all(a, "Path").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            assets[uuid(id)] = folder.appendingPathComponent(path)
        }
        // the CPL the person dropped, or the package's CPLs (newest first)
        var cpls: [(URL, String)] = []
        let dropped = url.pathExtension.lowercased() == "xml" && rootName(url) == "CompositionPlaylist" ? url : nil
        for n in names where n.lowercased().hasSuffix(".xml") {
            let u = folder.appendingPathComponent(n)
            guard let doc = try? XMLDocument(contentsOf: u, options: []), doc.rootElement()?.localName == "CompositionPlaylist" else { continue }
            cpls.append((u, text(doc.rootElement(), "IssueDate") ?? ""))
        }
        cpls.sort { $0.1 > $1.1 }
        guard let cplURL = dropped ?? cpls.first?.0 else { throw AppError("No Composition Playlist (CPL) found in the IMF package.") }
        var notes: [String] = []
        if dropped == nil && cpls.count > 1 {
            notes.append("This IMF package has \(cpls.count) CPLs — using the newest, “\(cplURL.lastPathComponent)”. Drop another CPL file to use it instead.")
        }

        let root = try XMLDocument(contentsOf: cplURL, options: []).rootElement()
        let editRate = Rational(text(root, "EditRate") ?? "") ?? Rational(24, 1)
        let title = text(root, "ContentTitle") ?? text(root, "ContentTitleText") ?? cplURL.deletingPathExtension().lastPathComponent
        let tc = all(root, "TimecodeStartAddress").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var seqs: [String: IMFSequence] = [:]
        var order: [String] = []
        var missing = Set<String>()
        for seg in all(root, "Segment") {
            for list in kids(seg, "SequenceList") {
                for s in (list.children ?? []).compactMap({ $0 as? XMLElement }) {
                    let name = s.localName ?? s.name ?? "?"
                    let trackID = uuid(text(s, "TrackId") ?? name)
                    var resources: [IMFResource] = []
                    for r in all(s, "Resource") {
                        guard let fid = text(r, "TrackFileId") else { continue }       // markers have no track file
                        guard let file = assets[uuid(fid)], fm.fileExists(atPath: file.path) else { missing.insert(uuid(fid)); continue }
                        let rate = Rational(text(r, "EditRate") ?? "") ?? editRate
                        let intrinsic = Int(text(r, "IntrinsicDuration") ?? "") ?? 0
                        let entry = Int(text(r, "EntryPoint") ?? "") ?? 0
                        let duration = Int(text(r, "SourceDuration") ?? "") ?? max(0, intrinsic - entry)
                        let repeats = max(1, Int(text(r, "RepeatCount") ?? "") ?? 1)
                        resources.append(IMFResource(file: file, entryPoint: entry, duration: duration, intrinsic: intrinsic, repeatCount: repeats, editRate: rate))
                    }
                    let key = name + "|" + trackID
                    if seqs[key] == nil { order.append(key); seqs[key] = IMFSequence(kind: kind(name), name: name, trackID: trackID, resources: []) }
                    seqs[key]?.resources += resources
                }
            }
        }
        if !missing.isEmpty { notes.append("\(missing.count) file(s) listed in the CPL are missing from the package folder.") }
        let sequences = order.compactMap { seqs[$0] }.filter { !$0.resources.isEmpty }
        guard sequences.contains(where: { $0.kind == .image }) else { throw AppError("The CPL has no picture track (or its MXF file is missing).") }
        return IMFPackage(folder: folder, cpl: cplURL, title: title, editRate: editRate, timecode: tc, sequences: sequences, notes: notes)
    }
}

// MARK: - Dolby Vision metadata

enum DolbyVisionMeta {
    /// One stretch of an IMF Dolby Vision (ISXD) track file used by the CPL
    struct ISXDPart: Equatable { let file: URL; let entry: Int; let count: Int }

    /// Where the Dolby Vision metadata comes from
    enum Source: Equatable {
        case xml(URL)                 // the colorist's XML (e.g. DaVinci Resolve export, CM v2.9 / v4.0)
        case isxd([ISXDPart])         // an IMF package's Dolby Vision metadata track (one XML document per frame, in MXF)
        var label: String {
            switch self {
            case .xml(let u): return u.lastPathComponent
            case .isxd(let p): return (p.first?.file.lastPathComponent ?? "MXF") + " (IMF)"
            }
        }
    }

    struct Summary: Equatable {
        var frames = 0
        var cm = ""
        var shots = 0
        var masterMin: Double?
        var masterMax: Double?
        var maxCLL: Int?
        var maxFALL: Int?
        var trims = ""
        var mdp = ""
        // Beta 2.0.0: parsed from dovi_tool 2.3.4 output / the XML; nil when absent (wave 0: not filled yet)
        var level5: String?
        var profile: String?
        var l1MaxCLL: Int?
        var l1MaxFALL: Int?
        var rate: Double?
        var primaries: String?
        var line: String {
            var p = ["\(Fmt.int(frames)) frames"]
            if !cm.isEmpty { p.append(cm) }
            if shots > 0 { p.append("\(Fmt.int(shots)) shots") }
            if let a = masterMin, let b = masterMax { p.append("mastered \(nits(a))–\(nits(b)) nits" + (mdp.isEmpty ? "" : " \(mdp)")) }
            if !trims.isEmpty { p.append("trims for \(trims)") }
            if let c = maxCLL, let f = maxFALL { p.append("MaxCLL \(c) · MaxFALL \(f)") }
            return p.joined(separator: " · ")
        }
    }

    static func nits(_ v: Double) -> String {
        v >= 10 ? String(format: "%.0f", v) : v >= 0.1 ? String(format: "%.2f", v) : String(format: "%.4f", v)
    }

    /// Every KLV value of an MXF file that is an XML document, in file order
    static func xmlDocuments(in d: Data) -> [Range<Int>] {
        var out: [Range<Int>] = []
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            func isKey(_ o: Int) -> Bool { o + 4 <= n && b[o] == 0x06 && b[o + 1] == 0x0e && b[o + 2] == 0x2b && b[o + 3] == 0x34 }
            var o = 0
            if !isKey(0) { while o < min(n, 65536) && !isKey(o) { o += 1 } }   // a run-in before the header partition
            while o + 17 <= n, isKey(o) {
                var p = o + 16
                let first = Int(b[p]); p += 1
                var len = 0
                if first < 0x80 { len = first }
                else {
                    let k = first & 0x7f
                    guard k >= 1, k <= 8, p + k <= n else { break }
                    for _ in 0..<k { len = (len << 8) | Int(b[p]); p += 1 }
                }
                guard len >= 0, p + len <= n else { break }
                let end = p + len
                var q = p
                if q + 3 <= end, b[q] == 0xEF, b[q + 1] == 0xBB, b[q + 2] == 0xBF { q += 3 }
                while q < end, b[q] == 0x20 || b[q] == 0x0a || b[q] == 0x0d || b[q] == 0x09 { q += 1 }
                if q < end, b[q] == 0x3C { out.append(p..<end) }
                o = end
            }
        }
        return out
    }

    private static func open(_ name: String) -> String { "<([A-Za-z_][\\w.-]*:)?\(name)(?=[\\s>/])[^>]*>" }
    private static func close(_ name: String) -> String { "</([A-Za-z_][\\w.-]*:)?\(name)\\s*>" }

    /// The first `name` element in `s`: the whole element and what's inside it
    static func element(_ name: String, in s: String) -> (whole: Range<String.Index>, inner: Range<String.Index>)? {
        guard let o = s.range(of: open(name), options: .regularExpression),
              let c = s.range(of: close(name), options: .regularExpression, range: o.upperBound..<s.endIndex) else { return nil }
        return (o.lowerBound..<c.upperBound, o.upperBound..<c.lowerBound)
    }

    /// Reads the per-frame Dolby Vision XML documents of IMF ISXD track files and writes one Dolby Vision XML
    /// for the frames the CPL uses: consecutive frames of the same shot become one <Shot>, frames whose values change
    /// inside a shot become <Frame> edits — the same structure the colorist's XML has.
    static func xmlFromISXD(_ parts: [ISXDPart], to out: URL, log: (String) -> Void = { _ in }) throws -> (frames: Int, shots: Int) {
        struct FrameMeta { let uid: String?; let plugin: String }
        var header: (before: String, after: String)?
        var metas: [FrameMeta] = []
        for part in parts {
            let data = try Data(contentsOf: part.file, options: .alwaysMapped)
            let docs = xmlDocuments(in: data).map { String(decoding: data[$0], as: UTF8.self) }
            let frameDocs = docs.filter { $0.range(of: open("Shot"), options: .regularExpression) != nil }
            if frameDocs.isEmpty {
                let sample = docs.prefix(2).map { String($0.prefix(400)) }.joined(separator: "\n---\n")
                log("Dolby Vision MXF \(part.file.lastPathComponent): \(docs.count) XML documents, none with <Shot>. Start of the first ones:\n\(sample)\n")
                throw AppError("Couldn't read the Dolby Vision metadata in “\(part.file.lastPathComponent)”: \(docs.count) XML documents found but none in the expected Dolby Vision format. Export the Dolby Vision XML from DaVinci Resolve and choose it instead.")
            }
            // a single document that already lists every shot (whole-timeline XML)
            if frameDocs.count == 1, parts.count == 1, part.entry == 0 {
                try frameDocs[0].write(to: out, atomically: true, encoding: .utf8)
                let shots = (try? NSRegularExpression(pattern: close("Shot")))?.numberOfMatches(in: frameDocs[0], range: NSRange(frameDocs[0].startIndex..., in: frameDocs[0])) ?? 0
                return (part.count, shots)
            }
            guard part.entry >= 0, part.entry + part.count <= frameDocs.count else {
                throw AppError("“\(part.file.lastPathComponent)” has \(Fmt.int(frameDocs.count)) frames of Dolby Vision metadata but the CPL uses frames \(part.entry)…\(part.entry + part.count - 1).")
            }
            for doc in frameDocs[part.entry..<(part.entry + part.count)] {
                guard let shot = element("Shot", in: doc) else { continue }
                let shotText = String(doc[shot.whole])
                if header == nil { header = (String(doc[..<shot.whole.lowerBound]), String(doc[shot.whole.upperBound...])) }
                let uid = element("UniqueID", in: shotText).map { String(shotText[$0.inner]).trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let plugin = element("PluginNode", in: shotText) else {
                    throw AppError("A Dolby Vision frame in “\(part.file.lastPathComponent)” has no metadata (PluginNode).")
                }
                metas.append(FrameMeta(uid: uid, plugin: String(shotText[plugin.whole])))
            }
        }
        guard let header, !metas.isEmpty else { throw AppError("No Dolby Vision frames found.") }
        // shot identity: the UniqueID when it repeats across frames, else frames with identical values
        let uids = metas.compactMap(\.uid)
        let byUID = uids.count == metas.count && Set(uids).count < metas.count
        var shots: [String] = []
        var i = 0
        while i < metas.count {
            var j = i + 1
            while j < metas.count && (byUID ? metas[j].uid == metas[i].uid : metas[j].plugin == metas[i].plugin) { j += 1 }
            var s = "<Shot><UniqueID>\(metas[i].uid ?? UUID().uuidString.lowercased())</UniqueID><Record><In>\(i)</In><Duration>\(j - i)</Duration></Record>\(metas[i].plugin)"
            for k in (i + 1)..<max(i + 1, j) where metas[k].plugin != metas[i].plugin {
                s += "<Frame><EditOffset>\(k - i)</EditOffset>\(metas[k].plugin)</Frame>"
            }
            shots.append(s + "</Shot>")
            i = j
        }
        try (header.before + shots.joined(separator: "\n") + header.after).write(to: out, atomically: true, encoding: .utf8)
        return (metas.count, shots.count)
    }

    /// XML → binary RPU (one per frame) with dovi_tool
    static func generateRPU(xml: URL, width: Int, height: Int, to rpu: URL) throws {
        guard let tool = Tools.doviTool else { throw AppError("dovi_tool isn't installed. Run: brew install dovi_tool") }
        var args = ["generate", "--xml", xml.path, "-p", "8.1", "-o", rpu.path]
        if width > 0 && height > 0 { args += ["--canvas-width", "\(width)", "--canvas-height", "\(height)"] }
        let r = Tools.runAll(tool, args)
        guard r.status == 0, FileManager.default.fileExists(atPath: rpu.path) else {
            let why = r.text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("Parsing") && !$0.hasPrefix("Generating") }.joined(separator: " ")
            throw AppError("dovi_tool couldn't read the Dolby Vision metadata: \(why.isEmpty ? "error \(r.status)" : why)")
        }
    }

    static func summary(_ rpu: URL) -> Summary? {
        guard let tool = Tools.doviTool else { return nil }
        let r = Tools.runAll(tool, ["info", "-s", rpu.path])
        guard r.status == 0 else { return nil }
        var s = Summary()
        func num(_ pattern: String, in l: String) -> [Double] {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) else { return [] }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: l).flatMap { Double(l[$0]) } }
        }
        for raw in r.text.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            func after(_ p: String) -> String? { l.hasPrefix(p) ? String(l.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) : nil }
            if let v = after("Frames:") { s.frames = Int(v) ?? 0 }
            else if let v = after("DM version:") { s.cm = v.components(separatedBy: "(").last?.replacingOccurrences(of: ")", with: "") ?? v }
            else if let v = after("Scene/shot count:") { s.shots = Int(v) ?? 0 }
            else if let v = after("L6 metadata:") {
                let md = num("([\\d.]+)/([\\d.]+) nits", in: v)
                if md.count == 2 { s.masterMin = md[0]; s.masterMax = md[1] }
                if let c = num("MaxCLL: ([\\d.]+)", in: v).first { s.maxCLL = Int(c) }
                if let f = num("MaxFALL: ([\\d.]+)", in: v).first { s.maxFALL = Int(f) }
            }
            else if let v = after("RPU mastering display:"), s.masterMax == nil {
                let md = num("([\\d.]+)/([\\d.]+) nits", in: v)
                if md.count == 2 { s.masterMin = md[0]; s.masterMax = md[1] }
            }
            else if let v = after("L8 trims:") { s.trims = v }
            else if let v = after("L2 trims:"), s.trims.isEmpty { s.trims = v }
            else if let v = after("L9 MDP:") { s.mdp = v }
            // Beta 2.0.0 (dovi_tool 2.3.4): "Profile: 8", "RPU content light level (L1): MaxCLL: 621.58 nits, MaxFALL: 18.42 nits",
            // "L5 offsets: top=0, bottom=0, left=0, right=0" — read for the Video tab's analysis, nothing else uses them
            else if let v = after("Profile:"), s.profile == nil { s.profile = v }
            else if let v = after("RPU content light level (L1):") {
                if let c = num("MaxCLL: ([\\d.]+)", in: v).first { s.l1MaxCLL = Int(c.rounded()) }
                if let f = num("MaxFALL: ([\\d.]+)", in: v).first { s.l1MaxFALL = Int(f.rounded()) }
            }
            else if let v = after("L5 offsets:"), s.level5 == nil { s.level5 = v }
        }
        return s
    }

    /// The four Level 5 offsets of `Summary.level5` ("top=63, bottom=64, left=0, right=0"), nil when the text isn't that
    static func level5Offsets(_ text: String?) -> (top: Int, bottom: Int, left: Int, right: Int)? {
        guard let text else { return nil }
        func v(_ k: String) -> Int? {
            guard let r = text.range(of: k + #"\s*=\s*(-?\d+)"#, options: .regularExpression) else { return nil }
            return Int(text[r].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        guard let t = v("top"), let b = v("bottom"), let l = v("left"), let r = v("right") else { return nil }
        return (t, b, l, r)
    }

    /// The track header of a Dolby Vision XML — what comes before the first <Shot>: the edit rate ("24 1") and the master's
    /// primaries (<ColorEncoding><Primaries>, named by their coordinates). Only the head of the file is read (the 2DIE4 XML
    /// is 127 MB; its header is the first 5 KB).
    static func xmlHeader(_ xml: URL) -> (rate: Double?, primaries: String?) {
        guard let fh = try? FileHandle(forReadingFrom: xml) else { return (nil, nil) }
        defer { try? fh.close() }
        var head = Data()
        let marks = ["<Shot>", "<Shot ", ":Shot>", ":Shot "].map { Data($0.utf8) }
        while head.count < 8 << 20 {
            let d = fh.readData(ofLength: 256 << 10)
            if d.isEmpty { break }
            let from = max(0, head.count - 8)
            head.append(d)
            let tail = head.subdata(in: from..<head.count)
            if marks.contains(where: { tail.range(of: $0) != nil }) { break }
        }
        let s = String(decoding: head, as: UTF8.self)
        let h = String(s[..<(s.range(of: open("Shot"), options: .regularExpression)?.lowerBound ?? s.endIndex)])
        func inner(_ name: String, in t: String) -> String? {
            element(name, in: t).map { String(t[$0.inner]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let rate = inner("EditRate", in: h).flatMap { Rational($0) }?.value
        var primaries: String?
        if let enc = inner("ColorEncoding", in: h), let p = inner("Primaries", in: enc) {
            func xy(_ t: String?) -> (Double, Double)? {
                let v = (t ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "," }).compactMap { Double($0) }
                return v.count == 2 ? (v[0], v[1]) : nil
            }
            if let r = xy(inner("Red", in: p)), let g = xy(inner("Green", in: p)), let b = xy(inner("Blue", in: p)) {
                primaries = primariesName(red: r, green: g, blue: b, white: xy(inner("WhitePoint", in: enc)))
            }
        }
        return (rate, primaries)
    }

    /// "P3-D65", "DCI-P3", "BT.2020", "BT.709" from CIE xy coordinates (±0.002), else the coordinates themselves
    static func primariesName(red r: (Double, Double), green g: (Double, Double), blue b: (Double, Double), white w: (Double, Double)?) -> String {
        let d65 = (0.3127, 0.3290), dci = (0.314, 0.351)
        let known: [(String, (Double, Double), (Double, Double), (Double, Double), (Double, Double))] = [
            ("P3-D65", (0.680, 0.320), (0.265, 0.690), (0.150, 0.060), d65),
            ("DCI-P3", (0.680, 0.320), (0.265, 0.690), (0.150, 0.060), dci),
            ("BT.2020", (0.708, 0.292), (0.170, 0.797), (0.131, 0.046), d65),
            ("BT.709", (0.640, 0.330), (0.300, 0.600), (0.150, 0.060), d65),
        ]
        func near(_ a: (Double, Double), _ b: (Double, Double)) -> Bool { abs(a.0 - b.0) <= 0.002 && abs(a.1 - b.1) <= 0.002 }
        for k in known where near(r, k.1) && near(g, k.2) && near(b, k.3) && (w.map { near($0, k.4) } ?? true) { return k.0 }
        func f(_ p: (Double, Double)) -> String { String(format: "%.4g %.4g", p.0, p.1) }
        return "custom (R \(f(r)), G \(f(g)), B \(f(b))" + (w.map { ", W \(f($0))" } ?? "") + ")"
    }
}

/// HDR as MediaInfo reports it (one entry per format, " / "-separated), in plain words
enum HDRInfo {
    static func rows(_ t: MITrack) -> [(String, String)] {
        guard let formats = t["HDR_Format"]?.components(separatedBy: " / "), !formats.isEmpty else { return [] }
        func field(_ k: String, _ i: Int) -> String {
            let parts = (t[k] ?? "").components(separatedBy: " / ")
            return i < parts.count ? parts[i].trimmingCharacters(in: .whitespaces) : ""
        }
        var rows: [(String, String)] = []
        for (i, f) in formats.enumerated() {
            let compat = field("HDR_Format_Compatibility", i)
            if f.contains("Dolby Vision") {
                let profile = field("HDR_Format_Profile", i), level = field("HDR_Format_Level", i)
                var v = [profile.isEmpty ? "" : profile + (level.isEmpty ? "" : ".\(level)"), field("HDR_Format_Settings", i)].filter { !$0.isEmpty }
                if profile.hasSuffix(".08") { v.insert("profile 8" + (compat.contains("HDR10") ? ".1" : compat.contains("HLG") ? ".4" : ""), at: 0) }
                else if profile.hasSuffix(".05") { v.insert("profile 5", at: 0) }
                else if profile.hasSuffix(".07") { v.insert("profile 7", at: 0) }
                if !compat.isEmpty { v.append("\(compat) compatible") }
                rows.append(("Dolby Vision", v.joined(separator: " · ")))
            } else if f.contains("2086") {
                var v = ["SMPTE ST 2086"]
                if let p = t["MasteringDisplay_ColorPrimaries"] { v.append("mastered on \(p)") }
                if let mn = t["MasteringDisplay_Luminance_Min"], let mx = t["MasteringDisplay_Luminance_Max"] { v.append("\(mn)–\(mx) nits") }
                if let c = t["MaxCLL"], let fa = t["MaxFALL"] { v.append("MaxCLL \(c) · MaxFALL \(fa)") }
                rows.append(("HDR10", v.joined(separator: " · ")))
            } else if f.contains("2094") {
                rows.append(("HDR10+", "SMPTE ST 2094-40 (dynamic)" + (compat.isEmpty ? "" : " · \(compat)")))
            } else {
                rows.append(("HDR", f))
            }
        }
        return rows
    }
}

enum HDR10Plus {
    /// Frames in an HDR10+ JSON (one SceneInfo entry per frame)
    static func frames(_ json: URL) -> Int? {
        guard let d = try? Data(contentsOf: json),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let info = j["SceneInfo"] as? [Any] else { return nil }
        return info.count
    }

    /// The display the HDR10+ metadata targets (the first SceneInfo's TargetedSystemDisplayMaximumLuminance, nits) and the
    /// profile — read from the head of the JSON only (a feature film's JSON has one entry per frame), cached per file
    static func info(_ json: URL) -> (targetNits: Int?, profile: String?) {
        let mtime = (try? json.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let key = json.path + "|\(mtime.timeIntervalSince1970)"
        infoLock.lock(); let cached = infoCache[key]; infoLock.unlock()
        if let cached { return cached }
        guard let fh = try? FileHandle(forReadingFrom: json) else { return (nil, nil) }
        defer { try? fh.close() }
        let s = String(decoding: fh.readData(ofLength: 512 << 10), as: UTF8.self)
        func first(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }
        let r = (first(#""TargetedSystemDisplayMaximumLuminance"\s*:\s*([0-9.]+)"#).flatMap { Double($0) }.map { Int($0.rounded()) },
                 first(#""HDR10plusProfile"\s*:\s*"([^"]*)""#))
        infoLock.lock(); infoCache[key] = r; infoLock.unlock()
        return r
    }
    private static let infoLock = NSLock()
    private static var infoCache: [String: (targetNits: Int?, profile: String?)] = [:]
}

// MARK: - Settings (Mux tab)

struct MasteringDisplay: Equatable {
    enum Gamut: String, CaseIterable, Identifiable {
        case p3d65 = "P3-D65", bt2020 = "BT.2020"
        var id: String { rawValue }
    }
    var gamut: Gamut = .p3d65
    var maxNits: Double = 1000
    var minNits: Double = 0.0001
    /// x265's master-display (chromaticities in 0.00002 units, luminance in 0.0001 cd/m²)
    var x265: String {
        let primaries = gamut == .p3d65 ? "G(13250,34500)B(7500,3000)R(34000,16000)" : "G(8500,39850)B(6550,2300)R(35400,14600)"
        return primaries + "WP(15635,16450)L(\(Int((maxNits * 10000).rounded())),\(Int((minNits * 10000).rounded())))"
    }
    var text: String { "\(gamut.rawValue) · \(DolbyVisionMeta.nits(minNits))–\(DolbyVisionMeta.nits(maxNits)) nits" }
}

@Observable
final class HDRSettings {
    enum Quality: String, CaseIterable, Identifiable {
        case master, maximum, high, compact
        var id: String { rawValue }
        var label: String { switch self { case .master: return "Master"; case .maximum: return "Maximum"; case .high: return "High"; case .compact: return "Compact" } }
        var crf: Double { switch self { case .master: return 4; case .maximum: return 14; case .high: return 16; case .compact: return 19 } }
        var maxMbps: Int { switch self { case .master: return 160; case .maximum: return 100; case .high: return 70; case .compact: return 40 } }
        var averageMbps: Double { switch self { case .master: return 100; case .maximum: return 60; case .high: return 40; case .compact: return 22 } }
        var detail: String {
            switch self {
            case .master: return "≈ 50–160 Mbps (CRF 4; about 100 Mbps on the 2DIE4 master), well above a UHD Blu-ray — as close to the master as a player can play (Level 5.1 High tier)"
            case .maximum: return "≈ 40–90 Mbps, like a UHD Blu-ray"
            case .high: return "≈ 30–60 Mbps, above the best streaming"
            case .compact: return "≈ 15–35 Mbps, like 4K streaming"
            }
        }
    }
    enum Speed: String, CaseIterable, Identifiable {
        case slow, medium, fast, draft
        var id: String { rawValue }
        var label: String { switch self { case .slow: return "Slow (best)"; case .medium: return "Medium"; case .fast: return "Fast"; case .draft: return "Draft" } }
        var preset: String { switch self { case .slow: return "slow"; case .medium: return "medium"; case .fast: return "fast"; case .draft: return "ultrafast" } }
        /// rough x265 speed for 4K on Apple Silicon (frames per second)
        var fps4K: Double { switch self { case .slow: return 3.5; case .medium: return 7; case .fast: return 13; case .draft: return 40 } }
    }
    /// How the HEVC encoder spends its bits
    enum RateMode: String, CaseIterable, Identifiable {
        case quality, average, constant
        var id: String { rawValue }
        var label: String { switch self { case .quality: return "Quality (CRF)"; case .average: return "Average (2-pass VBR)"; case .constant: return "Constant (CBR)" } }
        /// `--rate` names on the command line
        static func named(_ s: String) -> RateMode? {
            switch s.lowercased() { case "crf", "quality": return .quality; case "2pass", "twopass", "average", "vbr": return .average; case "cbr", "constant": return .constant; default: return nil }
        }
        var detail: String {
            switch self {
            case .quality: return "A fixed quality level; the bitrate follows the picture — less on easy scenes, more on hard ones, never above the ceiling. What UHD Blu-ray encoders do."
            case .average: return "A target average in Mbps over the whole film: a first pass measures the picture, a second spends the bits where they are needed. Predictable size, quality still follows the scenes."
            case .constant: return "The same bitrate from the first frame to the last (x265 strict CBR), whatever the scene. The most predictable size; bits are wasted on easy scenes."
            }
        }
    }
    /// Reference bitrates for the Average and Constant modes (picture only, Mbps)
    enum BitratePreset: String, CaseIterable, Identifiable {
        case streaming4K, bluray, uhdBluray, kaleidescapeCinematic, masterFile, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .streaming4K: return "Streaming 4K"
            case .bluray: return "Blu-ray"
            case .uhdBluray: return "UHD Blu-ray"
            case .kaleidescapeCinematic: return "Kaleidescape 4K Cinematic"
            case .masterFile: return "Master file"
            case .custom: return "Custom (type the Mbps)"
            }
        }
        /// the average (2-pass) or the constant bitrate
        var mbps: Int { switch self { case .streaming4K: return 25; case .bluray: return 35; case .uhdBluray: return 80; case .kaleidescapeCinematic: return 110; case .masterFile: return 200; case .custom: return 0 } }
        /// the peak the 2-pass encode may reach
        var maxMbps: Int { switch self { case .streaming4K: return 40; case .bluray: return 40; case .uhdBluray: return 100; case .kaleidescapeCinematic: return 160; case .masterFile: return 240; case .custom: return 0 } }
        var detail: String {
            switch self {
            case .streaming4K: return "25 Mbps — what the best 4K services stream (Apple TV+ averages 26–29 Mbps, Netflix about 16)"
            case .bluray: return "35 Mbps — a full-rate Blu-ray (its H.264 tops out at 40 Mbps)"
            case .uhdBluray: return "80 Mbps — a high-rate UHD Blu-ray (the disc's HEVC limit is 100 Mbps)"
            case .kaleidescapeCinematic: return "110 Mbps — Kaleidescape's 4K Cinematic tier, its own figure (Strato K only)"
            case .masterFile: return "200 Mbps — twice a UHD Blu-ray, for the screening room; HEVC Level 5.2, beyond what most players are rated for"
            case .custom: return "Your own figures: the average (or the constant bitrate) and, for 2-pass, the peak"
            }
        }
    }
    /// What the job encodes with (frozen in the plan)
    struct Rate: Equatable {
        var mode: RateMode = .quality
        var targetMbps = 100               // Average / Constant: the average or the constant bitrate
        var maxMbps = 160                  // Average: the peak (VBV); Constant: = targetMbps
        var floor = true                   // Average / Constant: no frame worse than QP `floorQP`, however easy the scene
        static let floorQP = 16
        /// `--rate MODE --mbps N [--max-mbps N] [--no-floor]`: nil when no rate option was given
        static func fromCLI(mode: RateMode?, mbps: Int?, maxMbps: Int?, floor: Bool) -> Rate? {
            guard let mode, mode != .quality else { return mode == nil ? nil : Rate() }
            let t = max(mbps ?? 100, 1)
            return Rate(mode: mode, targetMbps: t, maxMbps: mode == .constant ? t : max(maxMbps ?? Int(Double(t) * 1.5), t), floor: floor)
        }
        /// above this VBV the stream leaves HEVC Level 5.1 High tier (the UHD Blu-ray envelope)
        static let level51Mbps = 160
        var beyondLevel51: Bool { mode != .quality && maxMbps > Rate.level51Mbps }
        /// for the log and the result lines
        func text(_ q: Quality) -> String {
            switch mode {
            case .quality: return "CRF \(Int(q.crf)) (max \(q.maxMbps) Mbps)"
            case .average: return "2-pass average \(targetMbps) Mbps (peak \(maxMbps) Mbps" + (floor ? ", floor QP \(Rate.floorQP))" : ")")
            case .constant: return "CBR \(targetMbps) Mbps" + (floor ? " (floor QP \(Rate.floorQP))" : "")
            }
        }
        /// for the panels
        var summary: String {
            let level = beyondLevel51 ? "HEVC Level 5.2 — beyond the Level 5.1 envelope of UHD Blu-ray and most players; fine on the Zidoo, test anything else"
                                      : "HEVC Level 5.1 High tier, the UHD Blu-ray envelope"
            switch mode {
            case .quality: return ""
            case .average: return "2-pass VBR · average \(targetMbps) Mbps · peak \(maxMbps) Mbps" + (floor ? " · floor QP \(Rate.floorQP)" : "") + " · " + level
            case .constant: return "CBR · \(targetMbps) Mbps from start to end" + (floor ? " · floor QP \(Rate.floorQP)" : "") + " · " + level
            }
        }
    }

    var encode = false
    var dolbyVision = true
    var hdr10plus = false
    var dvSource: DolbyVisionMeta.Source?
    var dvSummary: DolbyVisionMeta.Summary?
    var dvProblem: String?
    var dvChecking = false
    var dvXMLReady: URL?                 // the Dolby Vision XML ready to use (the colorist's or the one rebuilt from the IMF)
    var hdr10plusJSON: URL?
    var hdr10plusFrames: Int?
    var quality: Quality = .maximum
    var speed: Speed = .medium   // padrao do dono (2026-11-04): slow dobra o tempo e some a 110+ Mbps
    var rateMode: RateMode = .quality
    var bitratePreset: BitratePreset = .kaleidescapeCinematic
    var customMbps = 100
    var customMaxMbps = 160
    var qualityFloor = true
    var convertGamut = true              // a P3-D65 / BT.709 master is carried in BT.2020 (HDR10 / Dolby Vision); off = tagged as it came
    /// The bitrate control the next encode uses
    var rate: Rate {
        let t = max(bitratePreset == .custom ? customMbps : bitratePreset.mbps, 1)
        let m = rateMode == .constant ? t : max(bitratePreset == .custom ? customMaxMbps : bitratePreset.maxMbps, t)
        return Rate(mode: rateMode, targetMbps: t, maxMbps: m, floor: qualityFloor)
    }
    var mastering = MasteringDisplay()
    var maxCLL = 0
    var maxFALL = 0
    var masteringSource = "defaults — check them"
    var imf: IMFPackage?
    /// Who turned the re-encoding on: the file that made it necessary (an IMF package, a Dolby Vision XML, an HDR10+ JSON),
    /// or nil when the person switched it on by hand. The Mux tab's banner says so.
    var autoEnabledBy: URL?
    var autoReason: String?
    var bannerCollapsed = false            // "Got it": the banner shrinks to one line, but never goes away while encode is on
    var confirmSkipped = false             // "Don't ask again for this project" on the confirmation before muxing
    @ObservationIgnored private var checkID = UUID()

    var formatsText: String {
        var f: [String] = []
        if dolbyVision && dvSource != nil { f.append("Dolby Vision 8.1") }
        f.append("HDR10")
        if hdr10plus && hdr10plusJSON != nil { f.append("HDR10+") }
        return f.joined(separator: " + ")
    }

    func reset() {
        encode = false; dolbyVision = true; hdr10plus = false; dvSource = nil; dvSummary = nil; dvProblem = nil; dvChecking = false
        dvXMLReady = nil; hdr10plusJSON = nil; hdr10plusFrames = nil; mastering = MasteringDisplay(); maxCLL = 0; maxFALL = 0
        masteringSource = "defaults — check them"; imf = nil; checkID = UUID()
        autoEnabledBy = nil; autoReason = nil; bannerCollapsed = false; confirmSkipped = false
    }

    /// HDR10 defaults from the source's own metadata (MediaInfo)
    func applySourceMastering(_ mi: MITrack?) {
        guard let mi, dvSummary == nil else { return }
        var found = false
        if let p = mi["MasteringDisplay_ColorPrimaries"] { mastering.gamut = p.contains("2020") ? .bt2020 : .p3d65; found = true }
        // MediaInfo gives "min: 0.0001 cd/m2, max: 1000 cd/m2": the "2" of "m2" is not a number to be taken
        let mn = mi["MasteringDisplay_Luminance_Min"].flatMap { Double($0.components(separatedBy: " ").first ?? "") }
        let mx = mi["MasteringDisplay_Luminance_Max"].flatMap { Double($0.components(separatedBy: " ").first ?? "") }
        if let mn, let mx, mx > mn { mastering.minNits = mn; mastering.maxNits = mx; found = true }
        else if let l = mi["MasteringDisplay_Luminance"],
                let re = try? NSRegularExpression(pattern: #"min:\s*([\d.]+).*max:\s*([\d.]+)"#),
                let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                let a = Range(m.range(at: 1), in: l), let b = Range(m.range(at: 2), in: l),
                let lo = Double(l[a]), let hi = Double(l[b]), hi > lo {
            mastering.minNits = lo; mastering.maxNits = hi; found = true
        }
        if let c = mi["MaxCLL"].flatMap({ Int($0.components(separatedBy: " ").first ?? "") }) { maxCLL = c; found = true }
        if let f = mi["MaxFALL"].flatMap({ Int($0.components(separatedBy: " ").first ?? "") }) { maxFALL = f; found = true }
        if found { masteringSource = "from the source file" }
    }

    /// Reads the Dolby Vision metadata (rebuilding the XML from an IMF if needed) and checks it against the picture
    static func inspect(_ src: DolbyVisionMeta.Source, width: Int, height: Int, frames: Int) -> (summary: DolbyVisionMeta.Summary?, problem: String?, xml: URL?) {
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BROS-MUX-DV-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let x: URL
            switch src {
            case .xml(let u): x = u
            case .isxd(let parts):
                x = dir.appendingPathComponent("DolbyVision_from_IMF.xml")
                _ = try DolbyVisionMeta.xmlFromISXD(parts, to: x)
            }
            let rpu = dir.appendingPathComponent("check.rpu")
            try DolbyVisionMeta.generateRPU(xml: x, width: width, height: height, to: rpu)
            var summary = DolbyVisionMeta.summary(rpu)
            try? FileManager.default.removeItem(at: rpu)
            if summary != nil {       // Beta 2.0.0: the edit rate and the master's primaries, from the XML's own header
                let h = DolbyVisionMeta.xmlHeader(x)
                summary?.rate = h.rate; summary?.primaries = h.primaries
            }
            if let s = summary, frames > 0, s.frames != frames {
                return (summary, "The Dolby Vision metadata covers \(Fmt.int(s.frames)) frames but the picture has \(Fmt.int(frames)) — they must match frame for frame.", nil)
            }
            return (summary, summary == nil ? "dovi_tool couldn't summarize the metadata." : nil, x)
        } catch { return (nil, error.localizedDescription, nil) }
    }

    func apply(_ r: (summary: DolbyVisionMeta.Summary?, problem: String?, xml: URL?)) {
        dvChecking = false; dvSummary = r.summary; dvProblem = r.problem; dvXMLReady = r.xml
        guard let s = r.summary else { return }
        if let a = s.masterMin, let b = s.masterMax { mastering.minNits = a; mastering.maxNits = b }
        if s.mdp.contains("2020") { mastering.gamut = .bt2020 } else if s.mdp.contains("P3") { mastering.gamut = .p3d65 }
        if let c = s.maxCLL { maxCLL = c }
        if let f = s.maxFALL { maxFALL = f }
        masteringSource = "from the Dolby Vision metadata (L6)"
    }

    func checkDolbyVision(width: Int, height: Int, frames: Int) {
        guard let src = dvSource else { return }
        let id = UUID(); checkID = id
        dvChecking = true; dvProblem = nil; dvSummary = nil; dvXMLReady = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.inspect(src, width: width, height: height, frames: frames)
            DispatchQueue.main.async { if self.checkID == id { self.apply(r) } }
        }
    }

    /// synchronous version (command line)
    func checkDolbyVisionNow(width: Int, height: Int, frames: Int) {
        guard let src = dvSource else { return }
        apply(Self.inspect(src, width: width, height: height, frames: frames))
    }

    func chooseDolbyVision(width: Int, height: Int, frames: Int) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.xml, UTType(filenameExtension: "mxf") ?? .data]
        p.message = "Choose the Dolby Vision metadata: the XML exported from DaVinci Resolve, or an IMF DOLBY_….mxf"
        guard p.runModal() == .OK, let u = p.url else { return }
        dvSource = u.pathExtension.lowercased() == "mxf" ? .isxd([.init(file: u, entry: 0, count: frames)]) : .xml(u)
        dolbyVision = true
        checkDolbyVision(width: width, height: height, frames: frames)
    }

    func chooseHDR10Plus(frames: Int) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.message = "Choose the HDR10+ metadata (JSON — e.g. exported from DaVinci Resolve Studio)"
        guard p.runModal() == .OK, let u = p.url else { return }
        hdr10plusJSON = u; hdr10plus = true; hdr10plusFrames = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let n = HDR10Plus.frames(u)
            DispatchQueue.main.async { if self.hdr10plusJSON == u { self.hdr10plusFrames = n ?? -1 } }
        }
    }

    var hdr10plusProblem: String? {
        guard hdr10plus, hdr10plusJSON != nil, let n = hdr10plusFrames else { return nil }
        return n < 0 ? "This JSON isn't HDR10+ metadata (no SceneInfo list)." : nil
    }
}

// MARK: - Encoding: see Transcode.swift (TranscodePlan, Transcode.encodeElementary / verifyElementary)

// MARK: - Metadata analysis (Beta 2.0.0): the lines of the Video tab's Dolby Vision / HDR10+ pop-up

/// One line of the metadata analysis shown in the Video tab's popup
struct MetadataCheck: Identifiable, Equatable {
    let id = UUID()
    var level: CheckLevel
    var title: String
    var detail: String
    var fix: Fix?
    enum Fix: Equatable { case convertGamut, keepSourcePrimaries, useMeasuredLight, qualityFloorOff, removeMetadata, copyText(String) }
}

/// The analysis behind the Video tab's Dolby Vision / HDR10+ pop-up: one line per rule of PLANO-BETA-2.0.0 Parte 1 §01
/// item 3, each DETECTED (title) → RECOMMENDED (detail) → an optional one-click fix. Pure and quick (it reads what
/// `HDRSettings.inspect` already measured — no process is started), so the Video tab can call it on the main thread;
/// only `measureLetterbox` runs ffmpeg and belongs on a background queue. A ✕ (.fail) line blocks the Delivery.
enum MetadataAnalysis {
    struct Letterbox: Equatable, Codable { var width: Int; var height: Int; var top: Int; var bottom: Int; var left: Int; var right: Int }

    static let waiting = "Waiting for the picture…"

    /// cropdetect on a few frames spread over the film (background queue; a few seconds)
    /// 6 points × 24 frames between 12 % and 88 % of the film (heads and tails are logos and credits), each point read
    /// with ffmpeg's cropdetect (limit 24/255 of the code range, scaled to the bit depth; even values); a point that is
    /// almost all black (a dark shot or a fade) is dropped, and the crop most points agree on wins (a tie: the larger one).
    /// nil when nothing could be measured. The source is only read.
    static func measureLetterbox(video: URL, index: Int, duration: Double, cancel: CancelFlag) -> Letterbox? {
        guard let ffmpeg = Tools.ffmpeg, duration > 0,
              let s = Probe.raw(video)?.streams?.first(where: { $0.index == index }),
              let W = s.width, let H = s.height, W > 0, H > 0 else { return nil }
        let fps = Rational((s.avg_frame_rate ?? s.r_frame_rate ?? "24").replacingOccurrences(of: "/", with: " "))?.value ?? 24
        let window = 24 / max(fps, 1)
        let points = 6
        var crops: [Letterbox] = []
        for k in 0..<points {
            if cancel.isSet { return nil }
            let t = max(0, min(duration - window - 0.1, duration * (0.12 + 0.76 * Double(k) / Double(points - 1))))
            let args = ["-nostdin", "-hide_banner", "-v", "info", "-ss", String(format: "%.3f", t), "-i", video.path,
                        "-map", "0:\(index)", "-frames:v", "24", "-an", "-sn", "-dn",
                        "-vf", "cropdetect=limit=0.094:round=2:reset=0", "-f", "null", "-"]
            guard let d = Tools.runCancellable(ffmpeg, args, cancel: cancel, stderr: true) else { continue }
            let text = String(decoding: d, as: UTF8.self)
            // the last line holds the area seen over all 24 frames (reset=0): crop=W:H:X:Y
            guard let r = text.range(of: #"crop=(-?\d+):(-?\d+):(-?\d+):(-?\d+)"#, options: [.regularExpression, .backwards]) else { continue }
            let v = text[r].dropFirst(5).split(separator: ":").compactMap { Int($0) }
            guard v.count == 4 else { continue }
            let (w, h, x, y) = (v[0], v[1], v[2], v[3])
            guard w >= W * 2 / 5, h >= H * 2 / 5, x >= 0, y >= 0, x + w <= W, y + h <= H else { continue }   // a black point says nothing
            crops.append(Letterbox(width: w, height: h, top: y, bottom: H - y - h, left: x, right: W - x - w))
        }
        guard !crops.isEmpty else { return nil }
        var count: [String: (Letterbox, Int)] = [:]
        for c in crops { let k = "\(c.width)x\(c.height)+\(c.left)+\(c.top)"; count[k] = (c, (count[k]?.1 ?? 0) + 1) }
        return count.values.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.width * a.0.height < b.0.width * b.0.height }?.0
    }

    static func fpsText(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.001 ? String(format: "%.0f", v) : String(format: "%.3f", v)
    }
    private static func line(_ level: CheckLevel, _ title: String, _ detail: String, _ fix: MetadataCheck.Fix? = nil) -> MetadataCheck {
        MetadataCheck(level: level, title: title, detail: detail, fix: fix)
    }
    /// The picture's colour as the master is described: "P3-D65 / PQ"
    private static func masterText(_ c: SourceColor) -> String {
        let p: String
        switch c.primaries {
        case "smpte432": p = "P3-D65"
        case "smpte431": p = "DCI-P3"
        case "bt2020": p = "BT.2020"
        case "bt709": p = "BT.709"
        case nil: p = "untagged primaries"
        case .some(let x): p = SourceColor.name(x)
        }
        return p + " / " + (c.transfer == nil ? "untagged transfer" : SourceColor.name(c.transfer))
    }

    /// waitingForPicture == true → lines that need the picture say "Waiting for the picture…" (level .info, never ✓)
    static func dolbyVision(_ hdr: HDRSettings, picture: SourceVideo?, frames: Int, fps: Double, letterbox: Letterbox?) -> [MetadataCheck] {
        guard let src = hdr.dvSource else { return [line(.info, "No Dolby Vision metadata", "Add the Dolby Vision XML on the Video tab.")] }
        if hdr.dvChecking { return [line(.info, "Reading \(src.label)…", "dovi_tool is reading the Dolby Vision metadata.")] }
        // 1. the XML can be read
        guard let s = hdr.dvSummary else {
            let why = hdr.dvProblem ?? "dovi_tool couldn't read the Dolby Vision metadata."
            return [line(.fail, "XML can't be read: \(src.label)", "\(why) — this can't be fixed here: send the error to the colourist.", .copyText(why))]
        }
        var out: [MetadataCheck] = []
        out.append(line(.ok, "XML readable: \(src.label)", "dovi_tool read \(Fmt.int(s.frames)) frames" + (s.shots > 0 ? " in \(Fmt.int(s.shots)) shots" : "") + "."))
        let waitingForPicture = picture == nil || frames <= 0
        let fpsShown = fpsText(fps > 0 ? fps : (s.rate ?? 24))
        let ask = "Please send a Dolby Vision XML of \(Fmt.int(frames)) frames at \(fpsShown) fps"
        // 2. frames
        if waitingForPicture {
            out.append(line(.info, "Frames: \(Fmt.int(s.frames)) in the XML", waiting))
        } else if s.frames == frames {
            out.append(line(.ok, "Frames: \(Fmt.int(s.frames)) = the picture", "Frame for frame with the picture."))
        } else {
            out.append(line(.fail, "Frames: \(Fmt.int(s.frames)) in the XML, \(Fmt.int(frames)) in the picture",
                            "They must match frame for frame — ask the colourist for an XML of \(Fmt.int(frames)) frames at \(fpsShown) fps.", .copyText(ask)))
        }
        // 3. frame rate
        if let r = s.rate {
            if waitingForPicture { out.append(line(.info, "Frame rate: \(fpsText(r)) fps in the XML", waiting)) }
            else if fps <= 0 || abs(r - fps) < 0.01 { out.append(line(.ok, "Frame rate: \(fpsText(r)) fps = the picture", "The XML's edit rate is the picture's.")) }
            else {
                out.append(line(.fail, "Frame rate: \(fpsText(r)) fps in the XML, \(fpsShown) fps in the picture",
                                "The metadata was made for another frame rate — ask the colourist for an XML of \(Fmt.int(frames)) frames at \(fpsShown) fps.", .copyText(ask)))
            }
        } else {
            out.append(line(.info, "Frame rate: not stated in the XML", "The XML has no <EditRate>; the frames are compared one by one instead."))
        }
        // 4. Level 5 (active area) against the letterbox measured in the picture
        let l5 = DolbyVisionMeta.level5Offsets(s.level5)
        let l5Text = l5.map { "top \($0.top) · bottom \($0.bottom) · left \($0.left) · right \($0.right)" } ?? "none (full frame)"
        if waitingForPicture {
            out.append(line(.info, "Level 5 (active area): \(l5Text)", waiting))
        } else if let lb = letterbox {
            let o = l5 ?? (0, 0, 0, 0)
            let tol = 4      // cropdetect finds even edges; dovi_tool rounds the XML's aspect ratio (2DIE4: 63/64 vs 64/64)
            let same = abs(o.top - lb.top) <= tol && abs(o.bottom - lb.bottom) <= tol && abs(o.left - lb.left) <= tol && abs(o.right - lb.right) <= tol
            let measured = "\(lb.width)×\(lb.height) (top \(lb.top) · bottom \(lb.bottom) · left \(lb.left) · right \(lb.right))"
            if same {
                out.append(line(.ok, "Level 5 (active area): \(l5Text)", "Matches the picture's letterbox, measured \(measured)."))
            } else {
                out.append(line(.warn, "Level 5 (active area): \(l5Text) in the XML, \(measured) in the picture",
                                "Level 5 tells the TV where the picture is inside the frame. Ask the colourist to check the aspect ratio (Level 5) of the export."))
            }
        } else {
            out.append(line(.info, "Level 5 (active area): \(l5Text)", "The picture's letterbox isn't measured yet."))
        }
        // 5. profile and CM version (information: the file is always written as 8.1)
        out.append(line(.info, "Profile \(s.profile ?? "?")" + (s.cm.isEmpty ? "" : " · \(s.cm)"), "Written as Dolby Vision 8.1 (HDR10-compatible)."))
        // 6. L6 MaxCLL / MaxFALL (what the HDR10 layer will say)
        let l1 = (s.l1MaxCLL ?? 0) > 0 && (s.l1MaxFALL ?? 0) > 0 ? (s.l1MaxCLL!, s.l1MaxFALL!) : nil
        let l1Text = l1.map { "MaxCLL \($0.0) · MaxFALL \($0.1) nits" }
        if let c = s.maxCLL, let f = s.maxFALL, c > 0, f > 0 {
            out.append(line(.ok, "L6 MaxCLL \(c) · MaxFALL \(f) nits", c == hdr.maxCLL && f == hdr.maxFALL ? "Written into the HDR10 layer."
                            : "HDR10 gets MaxCLL \(hdr.maxCLL) · MaxFALL \(hdr.maxFALL) nits — the values set on the Video tab."))
        } else {
            let l6 = s.maxCLL == nil && s.maxFALL == nil ? "no L6 light levels" : "L6 MaxCLL \(s.maxCLL ?? 0) · MaxFALL \(s.maxFALL ?? 0)"
            if hdr.maxCLL > 0 && hdr.maxFALL > 0 {
                let src = l1.map { $0.0 == hdr.maxCLL && $0.1 == hdr.maxFALL } == true ? "the values measured from L1" : "the values set on the Video tab"
                out.append(line(.ok, "\(l6) in the XML", "HDR10 gets MaxCLL \(hdr.maxCLL) · MaxFALL \(hdr.maxFALL) nits — \(src)."))
            } else if let l1Text {
                out.append(line(.warn, "\(l6) in the XML", "The HDR10 layer would say the film has no light level. Use the values measured from L1: \(l1Text).", .useMeasuredLight))
            } else {
                out.append(line(.warn, "\(l6) in the XML", "The HDR10 layer would say the film has no light level, and the XML has no L1 measurement to take them from — ask the colourist."))
            }
        }
        // 7. the master's primaries → BT.2020 (the picture's tags decide what the encode does; the XML is the cross-check)
        if waitingForPicture {
            out.append(line(.info, "Master: \(s.primaries ?? "primaries not stated") (from the XML)", waiting))
        } else if let c = picture?.color {
            let master = masterText(c)
            let xmlSays = s.primaries.map { " · the XML says \($0)" } ?? ""
            if c.isHLG {
                out.append(line(.warn, "Master: \(master)\(xmlSays)", "HLG can't be converted in this app — Dolby Vision 8.1 here is PQ."))
            } else if c.transfer != nil && !c.isPQ {
                out.append(line(.fail, "Master: \(master)\(xmlSays)", "The picture is tagged SDR: HDR10 and Dolby Vision metadata can't describe it. Check the source."))
            } else if c.primaries == "bt2020" {
                out.append(line(.ok, "Master: \(master)\(xmlSays)", "Already BT.2020: written as it is."))
            } else if let p = c.primaries, ColorLUT.primaries(p) != nil {
                if hdr.convertGamut {
                    out.append(line(.ok, "Master: \(master)\(xmlSays)", "Will be converted to BT.2020 in the new file (recommended) — your master isn't changed", .keepSourcePrimaries))
                } else {
                    out.append(line(.warn, "Master: \(master)\(xmlSays)", "Stays tagged \(ColorLUT.label(p)): HDR10 and Dolby Vision streams are BT.2020, so players that assume BT.2020 will shift the hues. Convert to BT.2020 (recommended) — your master isn't changed.", .convertGamut))
                }
            } else if c.primaries == nil {
                out.append(line(.warn, "Master: \(master)\(xmlSays)", "The picture carries no primaries tag, so nothing can be converted: the new file is tagged BT.2020 as it is. Check the source's colour tags."))
            } else {
                out.append(line(.warn, "Master: \(master)\(xmlSays)", "\(SourceColor.name(c.primaries)) can't be converted in this app — only P3-D65 and BT.709 masters go to BT.2020."))
            }
        }
        // 8. the quality floor against the HEVC Level 5.1 cap
        let rate = hdr.rate
        if hdr.rateMode != .quality && hdr.qualityFloor {
            out.append(line(.warn, "Quality floor: on (QP \(HDRSettings.Rate.floorQP)) · \(hdr.rateMode.label)",
                            "The quality floor (QP \(HDRSettings.Rate.floorQP)) can push the peak past the \(HDRSettings.Rate.level51Mbps) Mbps cap (measured 274–305 Mbps on the 2DIE4's heaviest scene) — players built for HEVC Level 5.1 may refuse it",
                            .qualityFloorOff))
        } else if rate.beyondLevel51 {
            out.append(line(.warn, "Peak bitrate: \(rate.maxMbps) Mbps · \(hdr.rateMode.label)",
                            "Beyond the \(HDRSettings.Rate.level51Mbps) Mbps of HEVC Level 5.1 — fine on the Zidoo; players built for HEVC Level 5.1 may refuse it."))
        } else {
            let peak = hdr.rateMode == .quality ? hdr.quality.maxMbps : rate.maxMbps
            out.append(line(.ok, "Peak bitrate: up to \(peak) Mbps · \(hdr.rateMode.label)", "Within HEVC Level 5.1 (\(HDRSettings.Rate.level51Mbps) Mbps), what UHD players are built for."))
        }
        return out
    }

    static func hdr10Plus(_ hdr: HDRSettings, picture: SourceVideo?, frames: Int, fps: Double) -> [MetadataCheck] {
        guard let json = hdr.hdr10plusJSON else { return [line(.info, "No HDR10+ metadata", "Add the HDR10+ JSON on the Video tab.")] }
        let name = json.lastPathComponent
        // 1. readable (a SceneInfo list)
        guard let n = hdr.hdr10plusFrames else { return [line(.info, "Reading \(name)…", "Counting the HDR10+ frames.")] }
        guard n >= 0 else {
            return [line(.fail, "JSON can't be read: \(name)", "It isn't HDR10+ metadata (no SceneInfo list) — this can't be fixed here.", .removeMetadata)]
        }
        var out = [line(.ok, "JSON readable: \(name)", "\(Fmt.int(n)) frames of HDR10+ (SceneInfo).")]
        let waitingForPicture = picture == nil || frames <= 0
        // 2. frames
        if waitingForPicture { out.append(line(.info, "Frames: \(Fmt.int(n)) in the JSON", waiting)) }
        else if n == frames { out.append(line(.ok, "Frames: \(Fmt.int(n)) = the picture", "Frame for frame with the picture.")) }
        else {
            let f = fpsText(fps > 0 ? fps : 24)
            out.append(line(.fail, "Frames: \(Fmt.int(n)) in the JSON, \(Fmt.int(frames)) in the picture",
                            "They must match frame for frame — ask the colourist for an HDR10+ JSON of \(Fmt.int(frames)) frames at \(f) fps.",
                            .copyText("Please send an HDR10+ JSON of \(Fmt.int(frames)) frames at \(f) fps")))
        }
        // 3. the reference display (information)
        let info = HDR10Plus.info(json)
        if let t = info.targetNits {
            out.append(line(.info, "Reference display: \(t) nits", "The display the HDR10+ metadata was made for" + (info.profile.map { " · profile \($0)" } ?? "") + "."))
        } else {
            out.append(line(.info, "Reference display: not stated", "The JSON has no TargetedSystemDisplayMaximumLuminance."))
        }
        // 4. coherence with the HDR10 (static) mastering written next to it
        let m = hdr.mastering
        if !waitingForPicture, let c = picture?.color, c.transfer != nil, !c.isPQ {
            out.append(line(.fail, "Picture: \(masterText(c))", "HDR10+ describes a PQ picture; this one is tagged \(SourceColor.name(c.transfer)). Check the source."))
        } else if let t = info.targetNits, Double(t) > m.maxNits + 0.5 {
            out.append(line(.warn, "HDR10 mastering: \(m.text) · HDR10+ targets \(t) nits",
                            "The HDR10+ reference display is brighter than the HDR10 mastering display — one of them is wrong. Check the mastering peak on the Video tab."))
        } else if hdr.maxCLL > 0, Double(hdr.maxCLL) > m.maxNits * 1.1 {
            out.append(line(.warn, "HDR10 mastering: \(m.text) · MaxCLL \(hdr.maxCLL)",
                            "MaxCLL is above the mastering display's peak — check the HDR10 values on the Video tab."))
        } else {
            out.append(line(.ok, "HDR10 mastering: \(m.text)" + (hdr.maxCLL > 0 ? " · MaxCLL \(hdr.maxCLL) · MaxFALL \(hdr.maxFALL)" : ""),
                            "Consistent with the HDR10+ metadata."))
        }
        return out
    }
}

// MARK: - Interface: see HDRViews.swift
