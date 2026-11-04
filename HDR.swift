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
        }
        return s
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
        var crf: Double { switch self { case .master: return 10; case .maximum: return 14; case .high: return 16; case .compact: return 19 } }
        var maxMbps: Int { switch self { case .master: return 160; case .maximum: return 100; case .high: return 70; case .compact: return 40 } }
        var averageMbps: Double { switch self { case .master: return 100; case .maximum: return 60; case .high: return 40; case .compact: return 22 } }
        var detail: String {
            switch self {
            case .master: return "≈ 80–160 Mb/s, well above a UHD Blu-ray — as close to the master as a player can play (Level 5.1 High tier)"
            case .maximum: return "≈ 40–90 Mb/s, like a UHD Blu-ray"
            case .high: return "≈ 30–60 Mb/s, above the best streaming"
            case .compact: return "≈ 15–35 Mb/s, like 4K streaming"
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
    var speed: Speed = .slow
    var mastering = MasteringDisplay()
    var maxCLL = 0
    var maxFALL = 0
    var masteringSource = "defaults — check them"
    var imf: IMFPackage?
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
            let summary = DolbyVisionMeta.summary(rpu)
            try? FileManager.default.removeItem(at: rpu)
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

// MARK: - Encoding (x265) + metadata injection

/// Everything the job needs to encode the picture (frozen when the job starts)
struct VideoEncodePlan {
    struct Segment { let file: URL; let start: Int; let count: Int }
    let segments: [Segment]            // frames to read, in order (an IMF CPL can splice several track files)
    let frames: Int
    let fps: Rational
    let width: Int
    let height: Int
    let rgbSource: Bool
    let quality: HDRSettings.Quality
    let speed: HDRSettings.Speed
    let mastering: MasteringDisplay
    let maxCLL: Int
    let maxFALL: Int
    let dolbyVision: DolbyVisionMeta.Source?
    let dvXML: URL?                    // already checked/rebuilt in the window
    let hdr10plus: URL?
    var seconds: Double { Double(frames) / max(fps.value, 1) }
    var formats: String {
        ((dolbyVision != nil ? ["Dolby Vision 8.1"] : []) + ["HDR10"] + (hdr10plus != nil ? ["HDR10+"] : [])).joined(separator: " + ")
    }
    var estimatedBytes: Double { quality.averageMbps * 1_000_000 / 8 * seconds }
    var estimatedSeconds: Double { Double(frames) / (speed.fps4K * 8_294_400 / Double(max(width * height, 1))) }
    /// MP4Box import options for the encoded stream
    func importOptions(mov: Bool) -> [String] {
        var o = ["fps=\(fps)"]
        if dolbyVision != nil { o.append("dvp=8.1") }
        o.append(mov ? "colr=nclc,9,16,9" : "colr=nclx,9,16,9,no")
        return o
    }
}

enum VideoEncoder {
    static func ffmpegArguments(_ p: VideoEncodePlan, concat: URL?, output: URL) -> [String] {
        var a = ["-nostdin", "-v", "error", "-nostats", "-progress", "pipe:1"]
        if let concat { a += ["-f", "concat", "-safe", "0", "-i", concat.path] }
        else if let s = p.segments.first {
            if s.start > 0 { a += ["-ss", String(format: "%.6f", Double(s.start) / p.fps.value)] }
            a += ["-i", s.file.path]
        }
        a += ["-map", "0:v:0", "-frames:v", "\(p.frames)", "-an", "-sn", "-dn"]
        // 4:2:0 10-bit with UHD chroma siting (top-left = type 2); RGB masters (JPEG 2000) get the BT.2020 matrix
        let matrix = p.rgbSource ? "out_color_matrix=bt2020:" : ""
        a += ["-vf", "scale=\(matrix)out_range=tv:out_h_chr_pos=0:out_v_chr_pos=0:flags=lanczos+accurate_rnd+full_chroma_int+full_chroma_inp,format=yuv420p10le"]
        let vbv = p.quality.maxMbps * 1000
        let x265 = ["log-level=error", "hdr10=1", "hdr10-opt=1", "repeat-headers=1", "aud=1", "hrd=1",
                    "colorprim=bt2020", "transfer=smpte2084", "colormatrix=bt2020nc", "range=limited", "chromaloc=2",
                    "master-display=\(p.mastering.x265)", "max-cll=\(p.maxCLL),\(p.maxFALL)",
                    "vbv-maxrate=\(vbv)", "vbv-bufsize=\(vbv)", "aq-mode=3", "no-sao=1"]
        a += ["-c:v", "libx265", "-preset", p.speed.preset, "-crf", String(format: "%.0f", p.quality.crf), "-x265-params", x265.joined(separator: ":")]
        a += ["-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", "-color_range", "tv",
              "-f", "hevc", "-y", output.path]
        return a
    }

    /// Encodes the picture and injects the metadata. Returns the final HEVC stream (in `tmp`), the RPU that went in, and notes.
    static func run(_ p: VideoEncodePlan, tmp: URL, cancel: CancelFlag,
                    stage: @escaping (String, Double) -> Void, log: @escaping (String) -> Void) throws -> (hevc: URL, rpu: URL?, notes: [String]) {
        guard let ffmpeg = Tools.ffmpeg else { throw AppError("ffmpeg not found") }
        let fm = FileManager.default
        var notes: [String] = []

        // 1. Dolby Vision metadata → RPU (checked against the frame count before hours of encoding)
        var rpu: URL?
        if let src = p.dolbyVision {
            stage("Reading the Dolby Vision metadata…", 0)
            var xml = p.dvXML
            if xml == nil {
                switch src {
                case .xml(let u): xml = u
                case .isxd(let parts):
                    let x = tmp.appendingPathComponent("DolbyVision_from_IMF.xml")
                    let r = try DolbyVisionMeta.xmlFromISXD(parts, to: x, log: log)
                    log("Dolby Vision metadata rebuilt from the IMF: \(r.frames) frames, \(r.shots) shots\n")
                    xml = x
                }
            }
            guard let xml else { throw AppError("No Dolby Vision metadata.") }
            let r = tmp.appendingPathComponent("DolbyVision.rpu")
            try DolbyVisionMeta.generateRPU(xml: xml, width: p.width, height: p.height, to: r)
            guard let s = DolbyVisionMeta.summary(r) else { throw AppError("dovi_tool couldn't summarize the generated metadata.") }
            guard s.frames == p.frames else {
                throw AppError("The Dolby Vision metadata covers \(Fmt.int(s.frames)) frames but the picture has \(Fmt.int(p.frames)) — they must match frame for frame.")
            }
            notes.append("Dolby Vision 8.1 metadata: " + s.line)
            rpu = r
        }
        if let j = p.hdr10plus {
            guard Tools.hdr10plusTool != nil else { throw AppError("hdr10plus_tool isn't installed. Run: brew install hdr10plus_tool") }
            guard let n = HDR10Plus.frames(j) else { throw AppError("“\(j.lastPathComponent)” isn't HDR10+ metadata (no SceneInfo list).") }
            guard n == p.frames else { throw AppError("The HDR10+ metadata has \(Fmt.int(n)) frames but the picture has \(Fmt.int(p.frames)).") }
        }
        if cancel.isSet { throw Cancelled() }

        // 2. picture → HEVC 10-bit HDR10 (x265)
        var concat: URL?
        if p.segments.count > 1 {
            var list = "ffconcat version 1.0\n"
            for s in p.segments {
                list += "file '\(s.file.path.replacingOccurrences(of: "'", with: "'\\''"))'\n"
                // the concat demuxer compares outpoint with the frame's own timestamp: a 6-decimal rounding up lets one
                // frame too many through, so the points sit a quarter frame after the first frame and half a frame before the end
                list += String(format: "inpoint %.6f\noutpoint %.6f\n", (Double(s.start) + 0.25) / p.fps.value, (Double(s.start + s.count) - 0.5) / p.fps.value)
            }
            let u = tmp.appendingPathComponent("segments.ffconcat")
            try list.write(to: u, atomically: true, encoding: .utf8)
            concat = u
        }
        let base = tmp.appendingPathComponent("video.hevc")
        let args = ffmpegArguments(p, concat: concat, output: base)
        log("ffmpeg " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + "\n")
        let started = Date()
        var done = 0
        let label = "Encoding the picture (x265 \(p.speed.preset), quality \(p.quality.label.lowercased()))"
        stage(label + "…", 0)
        let status = Tools.runStreaming(ffmpeg, args, cancel: cancel, line: { l in
            guard l.hasPrefix("frame="), let f = Int(l.dropFirst(6).trimmingCharacters(in: .whitespaces)) else { return }
            done = f
            let elapsed = Date().timeIntervalSince(started)
            let fps = elapsed > 0 ? Double(f) / elapsed : 0
            let left = fps > 0 ? Double(p.frames - f) / fps : 0
            stage("\(label): frame \(Fmt.int(f)) of \(Fmt.int(p.frames)) · \(String(format: "%.1f", fps)) fps · \(Fmt.hm(left)) left", Double(f) / Double(max(p.frames, 1)))
        }, log: log)
        if cancel.isSet { throw Cancelled() }
        guard status == 0, fm.fileExists(atPath: base.path) else { throw AppError("The picture encode failed (ffmpeg error \(status)). See the log.") }
        guard done == p.frames else { throw AppError("The encode produced \(Fmt.int(done)) frames, \(Fmt.int(p.frames)) were expected — the source is shorter than its metadata says.") }
        notes.append("Picture: HEVC Main 10 4:2:0 PQ BT.2020 · x265 \(p.speed.preset), CRF \(Int(p.quality.crf)) (max \(p.quality.maxMbps) Mb/s) · \(Fmt.int(done)) frames in \(Fmt.hm(Date().timeIntervalSince(started))) · HDR10 \(p.mastering.text), MaxCLL \(p.maxCLL), MaxFALL \(p.maxFALL)")

        // 3. HDR10+ (SEI) and Dolby Vision (RPU NAL units) go into the stream, frame by frame
        var current = base
        if let j = p.hdr10plus, let tool = Tools.hdr10plusTool {
            stage("Adding the HDR10+ metadata…", 0.5)
            let next = tmp.appendingPathComponent("video.hdr10plus.hevc")
            let r = Tools.runAll(tool, ["inject", "-i", current.path, "-j", j.path, "-o", next.path])
            log(r.text)
            guard r.status == 0, fm.fileExists(atPath: next.path) else { throw AppError("hdr10plus_tool couldn't add the HDR10+ metadata. See the log.") }
            try? fm.removeItem(at: current); current = next
            notes.append("HDR10+ metadata added from \(j.lastPathComponent)")
        }
        if cancel.isSet { throw Cancelled() }
        if let rpu, let tool = Tools.doviTool {
            stage("Adding the Dolby Vision metadata…", 0.8)
            let next = tmp.appendingPathComponent("video.dv.hevc")
            let r = Tools.runAll(tool, ["inject-rpu", "-i", current.path, "--rpu-in", rpu.path, "-o", next.path])
            log(r.text)
            guard r.status == 0, fm.fileExists(atPath: next.path) else { throw AppError("dovi_tool couldn't add the Dolby Vision metadata. See the log.") }
            try? fm.removeItem(at: current); current = next
        }
        return (current, rpu, notes)
    }

    /// The final file's picture as an Annex-B HEVC stream, piped into a tool (dovi_tool / hdr10plus_tool reading "-")
    static func pipeVideo(_ file: URL, into exe: String, _ args: [String], cancel: CancelFlag) -> (status: Int32, text: String) {
        guard let ffmpeg = Tools.ffmpeg else { return (-1, "ffmpeg not found") }
        let ff = Process(), tool = Process()
        ff.executableURL = URL(fileURLWithPath: ffmpeg)
        ff.arguments = ["-nostdin", "-v", "error", "-i", file.path, "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", "-"]
        tool.executableURL = URL(fileURLWithPath: exe)
        tool.arguments = args
        let video = Pipe(), out = Pipe()
        ff.standardInput = FileHandle.nullDevice; ff.standardOutput = video; ff.standardError = FileHandle.nullDevice
        tool.standardInput = video; tool.standardOutput = out; tool.standardError = out
        let lock = NSLock()
        var text = Data()
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); text.append(d); lock.unlock() }
        do { try tool.run(); try ff.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return (-1, error.localizedDescription)
        }
        try? video.fileHandleForWriting.close(); try? video.fileHandleForReading.close()   // only the children keep the pipe
        while ff.isRunning || tool.isRunning {
            if cancel.isSet { if ff.isRunning { ff.terminate() }; if tool.isRunning { tool.terminate() } }
            Thread.sleep(forTimeInterval: 0.2)
        }
        out.fileHandleForReading.readabilityHandler = nil
        let rest = out.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); text.append(rest); lock.unlock()
        let ok = ff.terminationStatus == 0 && tool.terminationStatus == 0 && !cancel.isSet
        return (ok ? 0 : max(ff.terminationStatus, tool.terminationStatus, 1), String(decoding: text, as: UTF8.self))
    }

    static func md5(_ u: URL) -> String? {
        guard let d = try? Data(contentsOf: u, options: .alwaysMapped) else { return nil }
        return Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the encoded picture in the final file: frame count and signalling (MediaInfo), then the metadata itself,
    /// read back frame by frame — the Dolby Vision RPU must be byte-identical to the one generated, HDR10+ in every frame.
    static func verify(_ out: URL, plan: VideoEncodePlan, rpu: URL?, tmp: URL, cancel: CancelFlag,
                       stage: (String, Double) -> Void) -> (ok: Bool, lines: [String]) {
        guard let v = MediaInfo.tracks(out).first(where: { $0.type == "Video" }) else { return (false, ["⚠ Video track not found in the final file ✗"]) }
        var ok = true, lines: [String] = []
        let hdr = v["HDR_Format"] ?? ""
        let frames = Int(v["FrameCount"] ?? "") ?? -1
        lines.append("Picture: HEVC \(v["Format_Profile"] ?? "") · \(Fmt.int(frames)) frames (expected \(Fmt.int(plan.frames))) \(frames == plan.frames ? "✓" : "✗")")
        if frames != plan.frames { ok = false }
        func flag(_ name: String, _ present: Bool) {
            lines.append("\(name): \(present ? "signalled" : "MISSING") \(present ? "✓" : "✗")")
            if !present { ok = false }
        }
        flag("HDR10 (BT.2020 · PQ · SMPTE ST 2086 mastering + MaxCLL/MaxFALL)", hdr.contains("2086"))
        if plan.dolbyVision != nil { flag("Dolby Vision 8.1 (HDR10-compatible)", hdr.contains("Dolby Vision")) }
        if plan.hdr10plus != nil { flag("HDR10+ (SMPTE ST 2094-40)", hdr.contains("2094")) }
        if let rpu, let tool = Tools.doviTool, !cancel.isSet {
            stage("Reading the Dolby Vision metadata back from the final file…", 0.5)
            let back = tmp.appendingPathComponent("readback.rpu")
            let r = pipeVideo(out, into: tool, ["extract-rpu", "-", "-o", back.path], cancel: cancel)
            let same = r.status == 0 && md5(back) != nil && md5(back) == md5(rpu)
            let s = DolbyVisionMeta.summary(back)
            lines.append(same ? "Dolby Vision metadata read back from the file: identical to the generated RPU, all \(Fmt.int(s?.frames ?? 0)) frames (\(Fmt.int(s?.shots ?? 0)) shots) ✓"
                              : "Dolby Vision metadata read back from the file: DIFFERENT from the generated RPU ✗")
            if !same { ok = false }
            try? FileManager.default.removeItem(at: back)
        }
        if let json = plan.hdr10plus, let tool = Tools.hdr10plusTool, !cancel.isSet {
            stage("Reading the HDR10+ metadata back from the final file…", 0.8)
            let back = tmp.appendingPathComponent("readback.hdr10plus.json")
            let r = pipeVideo(out, into: tool, ["extract", "-", "-o", back.path], cancel: cancel)
            let n = r.status == 0 ? HDR10Plus.frames(back) : nil
            lines.append("HDR10+ metadata read back from the file: \(n.map { Fmt.int($0) } ?? "none") of \(Fmt.int(plan.frames)) frames (from \(json.lastPathComponent)) \(n == plan.frames ? "✓" : "✗")")
            if n != plan.frames { ok = false }
            try? FileManager.default.removeItem(at: back)
        }
        return (ok, lines)
    }
}

// MARK: - Interface

/// The HDR & Dolby Vision section of the Mux inspector
struct HDRPanel: View {
    @Environment(Project.self) private var project

    var body: some View {
        @Bindable var hdr = project.hdr
        let v = project.videoTrack
        let frames = project.videoFrames
        Section {
            Toggle("Encode the picture for playback", isOn: $hdr.encode)
                .toggleStyle(.switch).disabled(project.busy)
            if let imf = hdr.imf {
                LabeledContent("IMF") {
                    Text("\(imf.title) · \(Fmt.int(frames)) frames @ \(imf.editRate) fps").multilineTextAlignment(.trailing)
                }
            }
            if hdr.encode {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { hdr.dolbyVision && hdr.dvSource != nil }, set: { hdr.dolbyVision = $0 })) {
                        Text("Dolby Vision 8.1")
                    }
                    .toggleStyle(.checkbox).disabled(hdr.dvSource == nil)
                    metaLine(hdr.dvSource?.label ?? "No Dolby Vision metadata",
                             detail: hdr.dvChecking ? "Reading…" : hdr.dvProblem ?? hdr.dvSummary?.line,
                             bad: hdr.dvProblem != nil)
                    Button(hdr.dvSource == nil ? "Choose Dolby Vision XML…" : "Change…") {
                        hdr.chooseDolbyVision(width: project.videoWidth, height: project.videoHeight, frames: frames)
                    }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { hdr.hdr10plus && hdr.hdr10plusJSON != nil }, set: { hdr.hdr10plus = $0 })) {
                        Text("HDR10+")
                    }
                    .toggleStyle(.checkbox).disabled(hdr.hdr10plusJSON == nil)
                    metaLine(hdr.hdr10plusJSON?.lastPathComponent ?? "No HDR10+ metadata (Samsung TVs then use HDR10)",
                             detail: hdr.hdr10plusProblem ?? hdr.hdr10plusFrames.map { $0 >= 0 ? "\(Fmt.int($0)) frames" + ($0 == frames ? " ✓" : " — the picture has \(Fmt.int(frames))") : "" },
                             bad: hdr.hdr10plusProblem != nil || (hdr.hdr10plusFrames.map { $0 >= 0 && $0 != frames } ?? false))
                    Button(hdr.hdr10plusJSON == nil ? "Choose HDR10+ JSON…" : "Change…") { hdr.chooseHDR10Plus(frames: frames) }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("HDR10 (always)")
                    metaLine("\(hdr.mastering.text) · MaxCLL \(hdr.maxCLL) · MaxFALL \(hdr.maxFALL)", detail: hdr.masteringSource, bad: false)
                }
                Picker(selection: $hdr.quality) {
                    ForEach(HDRSettings.Quality.allCases) { Text($0.label).tag($0) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quality")
                        Text(hdr.quality.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(project.busy)
                Picker("Speed", selection: $hdr.speed) {
                    ForEach(HDRSettings.Speed.allCases) { Text($0.label).tag($0) }
                }
                .disabled(project.busy)
                if let plan = project.encodePlan {
                    Label("Output: \(plan.formats) · ~\(Fmt.bytes(plan.estimatedBytes)) of picture · about \(Fmt.hm(plan.estimatedSeconds)) of encoding on this Mac (rough; it can run overnight — the Mac won't sleep)",
                          systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                } else if v == nil {
                    Label("Add the picture (IMF package, or an HDR ProRes/MXF file).", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("HDR · Dolby Vision · HDR10+")
        } footer: {
            Text(hdr.encode
                 ? "The picture is re-encoded to HEVC 10-bit — the only way Dolby Vision, HDR10+ and HDR10 play on TVs, Apple TV, iPhone and Mac. The audio stays bit-exact."
                 : "Masters (ProRes, JPEG 2000, IMF) don't play on TVs or Apple devices. Turn this on to make a playback version: HEVC 10-bit with Dolby Vision, HDR10 and HDR10+.")
        }
    }

    func metaLine(_ title: String, detail: String?, bad: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(bad ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Where the output will play (replaces the Academy seal for playback versions)
struct PlaybackPanel: View {
    @Environment(Project.self) private var project

    var body: some View {
        let audio = project.included.filter { $0.kind == .audio }
        let hdr = project.videoTrack?.mi?["HDR_Format"] ?? ""
        PlaybackRows(dolbyVision: project.encodePlan?.dolbyVision != nil || hdr.contains("Dolby Vision"),
                     hdr10plus: project.encodePlan?.hdr10plus != nil || hdr.contains("2094"),
                     atmosDDP: audio.contains { $0.codecKey == "eac3" && $0.isAtmos },
                     trueHD: audio.contains { $0.codecKey == "truehd" || $0.codecKey == "mlp" },
                     mkv: project.container == .mkv)
        Text("Not for the Academy: it asks for SDR (ProRes 422 HQ / H.264).").font(.caption).foregroundStyle(.secondary)
    }
}

/// File Checker: an HDR playback file is judged by where it plays — the Academy checks are for SDR deliveries
struct HDRFileCard: View {
    let tracks: [MITrack]

    static func isHDR(_ tracks: [MITrack]) -> Bool {
        guard let v = tracks.first(where: { $0.type == "Video" }) else { return false }
        let t = v["transfer_characteristics"] ?? ""
        return v["HDR_Format"] != nil || t == "PQ" || t == "HLG"
    }

    var body: some View {
        let v = tracks.first { $0.type == "Video" }
        let hdr = v?["HDR_Format"] ?? ""
        let audios = tracks.filter { $0.type == "Audio" }
        let formats = [hdr.contains("Dolby Vision") ? "Dolby Vision" : nil, hdr.contains("2086") || v?["transfer_characteristics"] == "PQ" ? "HDR10" : nil,
                       hdr.contains("2094") ? "HDR10+" : nil, v?["transfer_characteristics"] == "HLG" ? "HLG" : nil].compactMap { $0 }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(symbol: "sun.max.fill", color: .orange, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HDR playback file").font(.headline)
                    Text(formats.joined(separator: " + ")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            PlaybackRows(dolbyVision: hdr.contains("Dolby Vision"), hdr10plus: hdr.contains("2094"),
                         atmosDDP: audios.contains { Academy.isEAC3JOC($0) }, trueHD: audios.contains { Academy.isTrueHD($0) },
                         mkv: tracks.first { $0.type == "General" }?["Format"] == "Matroska")
            Text("The Academy checks below are for SDR deliveries — they don't apply to this file.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct PlaybackRows: View {
    let dolbyVision: Bool
    let hdr10plus: Bool
    let atmosDDP: Bool
    let trueHD: Bool
    let mkv: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Apple TV 4K · iPhone · iPad · Mac", mkv ? "no — Apple doesn't open MKV (Infuse does)" :
                    [dolbyVision ? "Dolby Vision" : "HDR10", atmosDDP ? "Atmos (E-AC-3)" : trueHD ? "no TrueHD on Apple" : "audio"].joined(separator: " · "), good: !mkv)
            row("LG · Sony · Philips TVs (USB)", [dolbyVision ? "Dolby Vision" : "HDR10", atmosDDP || trueHD ? "Atmos to the soundbar (eARC)" : "audio"].joined(separator: " · "), good: true)
            row("Samsung TVs", hdr10plus ? "HDR10+" : "HDR10 (add HDR10+ metadata for dynamic HDR)", good: hdr10plus)
            row("Home theater (Zidoo, Shield, Kodi, Plex → receiver)", trueHD ? (mkv ? "TrueHD Atmos (lossless)" : "TrueHD Atmos — MKV is the safest container") :
                    atmosDDP ? "Atmos (E-AC-3)" : "—", good: trueHD ? mkv : atmosDDP)
        }
    }

    func row(_ device: String, _ what: String, good: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: good ? "checkmark.circle.fill" : "minus.circle.fill").foregroundStyle(good ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device).font(.subheadline.weight(.medium))
                Text(what).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
