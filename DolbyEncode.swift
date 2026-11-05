// BROS-MUX Beta 2.0.1 — 02 · AUDIO: the Dolby encode of a Dolby Atmos master (ADM BWF), made by Dolby Media Encoder.
// BROS-MUX doesn't encode Dolby itself. Dolby Media Encoder (DME 4.0, licensed through iLok) runs a small local server
// that its own window uses: GET /ready (is the licence there?), POST /get-media-info (what is this master?), POST /jobs
// (encode), GET /jobs/:id (how far?), PATCH /jobs/:id (cancel). BROS-MUX sends the very job model DME's window sends
// (DolbyTemplate), with the master, one encoder and the output filled in, then checks what came out (codec, Atmos,
// length) before the mux copies it bit for bit. DME must be installed and licensed; BROS-MUX opens it when it isn't open.

import Foundation
import AppKit
import Observation

extension Track {
    /// A Dolby Atmos master as a broadcast WAV with ADM metadata (beds + objects, more than 16 channels): no player plays it
    var isADMMaster: Bool { kind == .audio && isPCM && channels > 16 }
}

extension AudioDelivery {
    /// The Dolby encodes made by Dolby Media Encoder
    var isDolbyEncode: Bool { self == .ddpAtmos || self == .trueHDAtmos }
    /// The ways a track can be delivered: an Atmos master is only ever copied (as a sync reference) or Dolby-encoded;
    /// every other track never sees the Dolby encodes
    static func options(for t: Track) -> [AudioDelivery] {
        t.isADMMaster ? [.ddpAtmos, .trueHDAtmos] : [.copy, .aac, .pcm24]
    }
}

enum DolbyEncode {
    static let bundleID = "com.dolby.dme"
    static let defaultPath = "/Applications/Dolby/Dolby Media Encoder/Dolby Media Encoder.app"
    /// DD+ Atmos (E-AC-3 JOC) at 768 Kbps: what the Academy and Apple TV ask for
    static let ddpKbps = 768
    /// TrueHD Atmos for the estimates (VBR; 30 s of the 2DIE4 master came to 4.6 Mbps)
    static let trueHDEstimateMbps = 6.0

    // MARK: where DME is

    static var appURL: URL? {
        if FileManager.default.fileExists(atPath: defaultPath) { return URL(fileURLWithPath: defaultPath) }
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), u.pathExtension == "app" { return u }
        return nil
    }
    static var version: String? { appURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } }
    static var name: String { "Dolby Media Encoder" + (version.map { " \($0)" } ?? "") }

    static func runningPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.bundleURL?.pathExtension == "app" && !$0.isTerminated }?.processIdentifier
    }

    /// The port DME's server listens on (it picks a free one each time it opens)
    static func port(of pid: pid_t) -> Int? {
        guard let d = Tools.runSync("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-Fn"]) else { return nil }
        for line in String(decoding: d, as: UTF8.self).split(separator: "\n") where line.hasPrefix("n") {
            if let p = line.split(separator: ":").last.flatMap({ Int($0) }) { return p }
        }
        return nil
    }

    // MARK: talking to the server (curl: the same plain HTTP on localhost DME's window uses)

    struct Server {
        let port: Int
        /// The decoded "message" of DME's answer, or the error it gave
        func call(_ method: String, _ path: String, body: Any? = nil, timeout: Int = 60) throws -> Any {
            var args = ["-sS", "-m", "\(timeout)", "-X", method, "-w", "\n%{http_code}"]
            var bodyFile: URL?
            defer { if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) } }
            if let body {
                let f = FileManager.default.temporaryDirectory.appendingPathComponent("bros-dme-\(UUID().uuidString).json")
                try JSONSerialization.data(withJSONObject: body).write(to: f)
                bodyFile = f
                args += ["-H", "Content-Type: application/json", "--data-binary", "@\(f.path)"]
            }
            args.append("http://127.0.0.1:\(port)\(path)")
            let r = Tools.runAll("/usr/bin/curl", args)
            guard r.status == 0 else { throw AppError("\(DolbyEncode.name) didn't answer (\(path)): \(r.text.trimmingCharacters(in: .whitespacesAndNewlines))") }
            let parts = r.text.split(separator: "\n", omittingEmptySubsequences: false)
            let code = Int(parts.last ?? "") ?? 0
            let json = parts.dropLast().joined(separator: "\n")
            let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            guard (200..<300).contains(code), let obj, obj["success"] as? Bool != false else {
                let msg = (obj?["message"] as? String) ?? (obj?["error"] as? String) ?? json.prefix(300).description
                throw AppError("\(DolbyEncode.name) refused \(method) \(path) (HTTP \(code)): \(msg)")
            }
            return obj["message"] ?? [:]
        }
    }

    /// DME's server, opening DME (in the background) when it isn't open
    static func server(launch: Bool, cancel: CancelFlag? = nil, wait: TimeInterval = 120) throws -> Server {
        guard let app = appURL else { throw AppError(notInstalledText) }
        if let pid = runningPID(), let p = port(of: pid) { return Server(port: p) }
        guard launch else { throw AppError("\(name) isn't open.") }
        _ = Tools.runAll("/usr/bin/open", ["-g", "-a", app.path])
        let until = Date().addingTimeInterval(wait)
        while Date() < until {
            if cancel?.isSet == true { throw Cancelled() }
            if let pid = runningPID(), let p = port(of: pid) { return Server(port: p) }
            Thread.sleep(forTimeInterval: 1)
        }
        throw AppError("\(name) was opened but its server didn't start in \(Int(wait)) s. Open it by hand, check that its window isn't grey, and try again.")
    }

    static let notInstalledText = "Dolby Media Encoder isn't installed. It's what makes the Dolby encode (BROS-MUX doesn't encode Dolby itself): install it from the Dolby Professional Store and activate its licence in iLok License Manager."

    struct Licence { var ready: Bool; var errors: [String]; var userType: String?; var expires: String? }

    /// GET /ready: DME runs its own encoder with `--morehelp license` and says whether the iLok licence is there
    static func licence(_ s: Server) throws -> Licence {
        let m = try s.call("GET", "/ready", timeout: 120) as? [String: Any] ?? [:]
        return Licence(ready: m["ready"] as? Bool ?? false, errors: (m["errors"] as? [Any] ?? []).map { "\($0)" },
                       userType: m["userType"] as? String, expires: m["expirationDate"] as? String)
    }

    /// "licence active until 3 Feb 2027"
    static func licenceText(_ l: Licence) -> String {
        guard l.ready else { return "no licence: " + (l.errors.first ?? "DME says it isn't ready") }
        guard let e = l.expires, e != "unlimited" else { return "licence active" }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: e) ?? ISO8601DateFormatter().date(from: e) else { return "licence active until \(e)" }
        return "licence active until " + d.formatted(.dateTime.day().month(.abbreviated).year())
    }

    // MARK: what can be encoded

    /// Why `t` can't become `to` through DME (nil = it can). Quick: nothing is read.
    static func problem(_ t: Track, to: AudioDelivery) -> String? {
        let name = "“\(t.title)”"
        guard t.isADMMaster else {
            return "Only a Dolby Atmos master (ADM BWF) is encoded to Dolby here — \(name) is \(t.codecName) \(Probe.channelText(t.channels, t.channelLayout))."
        }
        guard appURL != nil else { return notInstalledText }
        if case .notReady(let why) = DolbyStatus.shared.state { return "\(name) can't be encoded: \(why)" }
        return nil
    }

    /// "DD+ Atmos (E-AC-3 JOC) · 768 Kbps" / "TrueHD Atmos · lossless"
    static func target(_ to: AudioDelivery) -> String {
        to == .trueHDAtmos ? "TrueHD Atmos · lossless" : "DD+ Atmos (E-AC-3 JOC) · \(ddpKbps) Kbps"
    }

    static func estimatedBytes(_ t: Track, to: AudioDelivery) -> Double {
        let d = max(t.duration, 0)
        return to == .trueHDAtmos ? trueHDEstimateMbps * 1_000_000 / 8 * d : Double(ddpKbps) * 1000 / 8 * d
    }

    // MARK: the encode

    struct Made {
        let url: URL              // what the mux copies: audio-N.ec3 (DD+ JOC) or audio-N.mka (the TrueHD stream in Matroska)
        let command: String       // the Dolby encoder and its arguments, as DME ran them (for the report)
        let lines: [String]       // what was checked on the encode itself
    }

    /// Hands the whole master to DME, waits, and checks the result. The master is only read.
    static func encode(_ t: Track, plan: TrimPlan?, to: AudioDelivery, folder: URL, index: Int, cancel: CancelFlag,
                       stage: @escaping (String, Double) -> Void) throws -> Made {
        if let p = problem(t, to: to) { throw AppError(p) }
        if let plan, plan.pad > 0 || plan.cut > 0 { throw AppError(headTrimText(t)) }
        stage("Opening \(name)…", 0)
        let s = try server(launch: true, cancel: cancel)
        stage("Checking the \(name) licence…", 0.005)
        let lic = try licence(s)
        guard lic.ready else { throw AppError("\(name) has no active licence: \(lic.errors.joined(separator: " · ")). Open iLok License Manager and activate it, then try again.") }
        if cancel.isSet { throw Cancelled() }

        // what DME reads in the master (its window fills the job with the same answers)
        stage("\(name) is reading the master…", 0.01)
        let infos = try s.call("POST", "/get-media-info", body: ["input_type": "atmos", "files": [t.url.path]], timeout: 300) as? [[String: Any]] ?? []
        guard let info = infos.first else { throw AppError("\(name) couldn't read “\(t.title)” as a Dolby Atmos master.") }
        let format = info["format"] as? String ?? ""
        guard format.localizedCaseInsensitiveContains("ADM") || format.localizedCaseInsensitiveContains("atmos") else {
            throw AppError("\(name) doesn't see a Dolby Atmos master in “\(t.title)” (it reads “\(format.isEmpty ? "nothing" : format)”). Only an ADM BWF master can be encoded.")
        }
        let fps = "\(info["videoFrameRate"] ?? "24")"
        let rate = "\(info["sampleRate"] ?? "48000")"
        let offsetTC = timecode(seconds: number(info["offset"]) ?? 0, fps: fps)

        // the job: DME's own model, with this master, one encoder and its output
        let fm = FileManager.default
        let raw = folder.appendingPathComponent("audio-\(index).\(to == .trueHDAtmos ? "mlp" : "ec3")")
        for ext in ["", ".mll", ".log.html"] { try? fm.removeItem(atPath: raw.path + ext) }
        guard var job = try JSONSerialization.jsonObject(with: Data(DolbyTemplate.clientJob.utf8)) as? [String: Any] else {
            throw AppError("The Dolby job model inside BROS-MUX can't be read.")
        }
        func set(_ path: [String], _ value: Any, active: Bool = true) {
            job = setting(job, path, ["active": active, "value": value])
        }
        set(["Input", "DolbyAtmos", "FilePath"], t.url.path)
        set(["Input", "DolbyAtmos", "FrameRate"], fps)
        set(["Input", "DolbyAtmos", "SampleRate"], rate)
        set(["Input", "DolbyAtmos", "Offset"], offsetTC)
        set(["CommonParameters", "FrameRate"], fps)
        set(["CommonParameters", "EncodeStart"], offsetTC)
        set(["CommonParameters", "EncodeEndChangedByUser"], false)        // the whole master, to its end…
        if let plan, plan.tail > 0, t.sampleRate > 0 {                     // …or to the end of the picture
            let end = (number(info["offset"]) ?? 0) + Double(plan.keep) / t.sampleRate
            set(["CommonParameters", "EncodeEnd"], timecode(seconds: end, fps: fps))
            set(["CommonParameters", "EncodeEndChangedByUser"], true)
        }
        // qc.sh only (BROS_DME_TEST_RANGE="00:10:00:00-00:10:30:00"): a stretch of a real master, so the QC doesn't encode an hour
        let expected = expectedDuration(t, plan: plan, fps: fps)
        if let range = testRange {
            set(["CommonParameters", "EncodeStart"], range[0])
            set(["CommonParameters", "EncodeEnd"], range[1])
            set(["CommonParameters", "EncodeEndChangedByUser"], true)
        }
        if to == .trueHDAtmos {
            set(["Encoders", "DolbyTrueHD", "Checkbox"], true)
            set(["Encoders", "DolbyTrueHD", "DolbyAtmos", "FrameRate"], fps)
            set(["Encoders", "DolbyTrueHD", "DolbyAtmos", "Offset"], offsetTC)
            set(["Encoders", "DolbyTrueHD", "Output", "mlpPath"], raw.path)
        } else {
            set(["Encoders", "DolbyDigitalPlusOnlineMedia", "Checkbox"], true)
            set(["Encoders", "DolbyDigitalPlusOnlineMedia", "DataRate"], ddpKbps)
            set(["Encoders", "DolbyDigitalPlusOnlineMedia", "Output", "ec3Checkbox"], true)
            set(["Encoders", "DolbyDigitalPlusOnlineMedia", "Output", "ec3Path"], raw.path)
            set(["Encoders", "DolbyDigitalPlusOnlineMedia", "Output", "mp4Checkbox"], false)
        }
        let encoder = to == .trueHDAtmos ? "DolbyTrueHD" : "DolbyDigitalPlusOnlineMedia"
        stage("Sending the encode to \(name)…", 0.02)
        let added = try s.call("POST", "/jobs", body: ["clientJob": job, "start": true]) as? [[String: Any]] ?? []
        guard let id = added.first(where: { $0["encoder"] as? String == encoder })?["id"] as? String ?? added.first?["id"] as? String else {
            throw AppError("\(name) took the job but gave no job number back.")
        }

        // waiting: DME's own progress, its errors and warnings
        var last: [String: Any] = [:]
        var warnings: [String] = []
        while true {
            if cancel.isSet {
                _ = try? s.call("PATCH", "/jobs/\(id)")
                throw Cancelled()
            }
            let m = try s.call("GET", "/jobs/\(id)")
            last = (m as? [String: Any]) ?? (m as? [[String: Any]])?.first ?? [:]
            let phase = last["phase"] as? String ?? ""
            let pct = number(last["progress"]) ?? 0
            warnings = (last["warnings"] as? [Any] ?? []).map { "\($0)" }
            stage("\(name): \(phase.lowercased()) · \(Int(pct)) %", 0.03 + 0.92 * min(1, max(0, pct / 100)))
            if phase == "Finished" || phase == "Canceled" || phase == "Released" { break }
            Thread.sleep(forTimeInterval: 2)
        }
        let code = Int(number(last["code"]) ?? -1)
        let errors = (last["errors"] as? [Any] ?? []).map { "\($0)" }
        guard last["phase"] as? String == "Finished", code == 0, fm.fileExists(atPath: raw.path) else {
            let why = errors.isEmpty ? "it ended as “\(last["phase"] as? String ?? "?")” (code \(code))" : errors.joined(separator: " · ")
            throw AppError("\(name) couldn't encode “\(t.title)”: \(why). Its log is in ~/Library/Application Support/Dolby Media Encoder.")
        }
        let command = commandText(last["config"])

        // TrueHD: DME writes a .mlp with a 16-byte header of its own; the stream itself goes into Matroska, unchanged,
        // so the mux knows its length (a raw TrueHD stream has none)
        var made = raw
        if to == .trueHDAtmos {
            stage("Putting the TrueHD stream in Matroska…", 0.96)
            guard let ffmpeg = Tools.ffmpeg else { throw AppError("ffmpeg isn't installed. Run: brew install ffmpeg") }
            let mka = folder.appendingPathComponent("audio-\(index).mka")
            try? fm.removeItem(at: mka)
            let r = Tools.runAll(ffmpeg, ["-nostdin", "-v", "fatal", "-i", raw.path, "-map", "0:a:0", "-c", "copy", "-y", mka.path])
            guard r.status == 0, fm.fileExists(atPath: mka.path) else { throw AppError("The TrueHD stream DME made couldn't be put in Matroska (ffmpeg error \(r.status)).") }
            made = mka
        }

        // the encode itself, before the mux: the codec, Atmos, and the length against the master
        stage("Checking the Dolby encode…", 0.98)
        var lines = [(to == .trueHDAtmos ? "TrueHD Atmos" : "DD+ Atmos") + " encoded by \(name) (\(licenceText(lic))) from \(t.url.lastPathComponent)"]
        lines += warnings.map { "⚠ \(name): \($0)" }
        if expected != t.duration { lines.append("⚠ QC test range \(ProcessInfo.processInfo.environment["BROS_DME_TEST_RANGE"] ?? ""): only a stretch of the master was encoded") }
        let check = checkStream(made, ordinal: 0, to: to, sourceDuration: expected)
        lines += check.lines
        if !check.ok { throw AppError("The encode \(name) made isn't right: " + check.lines.filter { $0.contains("✗") }.joined(separator: " · ")) }
        stage("Checking the Dolby encode…", 1)
        return Made(url: made, command: command, lines: lines)
    }

    /// Codec, Atmos (and JOC for DD+), channels of the core and the length, read from a file: ✓/✗ lines
    static func checkStream(_ url: URL, ordinal: Int, to: AudioDelivery, sourceDuration: Double) -> (ok: Bool, lines: [String]) {
        var lines: [String] = [], ok = true
        let streams = Probe.raw(url)?.streams?.filter { $0.codec_type == "audio" } ?? []
        let mis = MediaInfo.tracks(url).filter { $0.type == "Audio" }
        guard ordinal < streams.count else { return (false, ["The Dolby track isn't in \(url.lastPathComponent) ✗"]) }
        let s = streams[ordinal]
        let mi = ordinal < mis.count ? mis[ordinal] : nil
        let wantCodec = to == .trueHDAtmos ? "truehd" : "eac3"
        let codecOK = s.codec_name == wantCodec
        lines.append("Codec: \(s.codec_name ?? "?") (\(to == .trueHDAtmos ? "Dolby TrueHD" : "E-AC-3")) \(codecOK ? "✓" : "✗")"); if !codecOK { ok = false }
        let commercial = mi?["Format_Commercial_IfAny"] ?? s.profile ?? ""
        let atmos = commercial.contains("Atmos") || (s.profile ?? "").contains("Atmos")
        lines.append("Dolby Atmos: \(atmos ? commercial : "not signalled") \(atmos ? "✓" : "✗")"); if !atmos { ok = false }
        if to == .ddpAtmos {
            let joc = (mi?["Format_AdditionalFeatures"] ?? "").contains("JOC")
            let ci = mi?["ComplexityIndex"].map { " · complexity index \($0)" } ?? ""
            let kbps = (Double(mi?["BitRate"] ?? s.bit_rate ?? "") ?? 0) / 1000
            lines.append("JOC (objects in the E-AC-3)\(ci) · \(Int(kbps.rounded())) Kbps \(joc ? "✓" : "✗")"); if !joc { ok = false }
        } else if let f = mi?["Format_AdditionalFeatures"], !f.isEmpty {
            lines.append("Atmos elements: \(f)")
        }
        lines.append("Core: \(s.channels ?? 0) channels (\(s.channel_layout ?? "?")) — what a player without Atmos plays")
        let d = Double(s.duration ?? "") ?? (Double(mi?["Duration"] ?? "") ?? 0)
        if sourceDuration > 0, d > 0 {
            let diff = d - sourceDuration
            let near = abs(diff) <= 0.05      // a Dolby frame is 32 ms (E-AC-3); an end at the picture is rounded to a whole frame (≤ 21 ms)
            lines.append(String(format: "Length: %@ (expected %@, %+.0f ms) %@", Fmt.duration(d), Fmt.duration(sourceDuration), diff * 1000, near ? "✓" : "✗"))
            if !near { ok = false }
        }
        return (ok, lines)
    }

    // MARK: small pieces

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    /// "00:00:00:00" for an offset in seconds at DME's frame rate
    static func timecode(seconds: Double, fps: String) -> String {
        let rate = max(1, (Double(fps) ?? 24).rounded())
        let frames = Int((max(0, seconds) * rate).rounded())
        let f = frames % Int(rate), s = frames / Int(rate)
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60, f)
    }

    /// qc.sh only: BROS_DME_TEST_RANGE="00:10:00:00-00:10:30:00" encodes that stretch of a real master instead of all of it
    static var testRange: [String]? {
        guard let r = ProcessInfo.processInfo.environment["BROS_DME_TEST_RANGE"]?.split(separator: "-").map(String.init), r.count == 2 else { return nil }
        return r
    }
    /// The length the encode must have: the master's, or the QC's stretch
    static func expectedDuration(_ t: Track, plan: TrimPlan?, fps: String = "24") -> Double {
        if let r = testRange, let a = seconds(timecode: r[0], fps: fps), let b = seconds(timecode: r[1], fps: fps), b > a { return b - a }
        if let plan, plan.tail > 0, t.sampleRate > 0 { return Double(plan.keep) / t.sampleRate }   // ends with the picture
        return t.duration
    }

    /// An Atmos master that is early or late against the picture: the head can't be cut or padded before the encode
    static func headTrimText(_ t: Track) -> String {
        "“\(t.title)” would need its head cut or delayed to line up with the picture, and an Atmos master can't be cut before the Dolby encode (its objects are timed from the head). Make it the sync reference, or line it up in the mix. (A tail that runs past the picture is fine: the encode stops with the picture.)"
    }

    /// "00:10:30:00" → seconds at DME's frame rate
    static func seconds(timecode: String, fps: String) -> Double? {
        let p = timecode.split(separator: ":").compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        return p[0] * 3600 + p[1] * 60 + p[2] + p[3] / max(1, (Double(fps) ?? 24).rounded())
    }

    /// The job dictionary with `value` at `path` (dictionaries all the way down)
    static func setting(_ d: [String: Any], _ path: [String], _ value: Any) -> [String: Any] {
        var d = d
        guard let k = path.first else { return d }
        if path.count == 1 { d[k] = value; return d }
        d[k] = setting(d[k] as? [String: Any] ?? [:], Array(path.dropFirst()), value)
        return d
    }

    /// "dee_dthd_encoder --presentation … --input … --output …", from the job DME reports
    static func commandText(_ config: Any?) -> String {
        guard let c = config as? [String: Any] else { return "" }
        var parts = [c["tool"] as? String ?? "dee"]
        for key in ["commonProps", "outputProps", "encoderConfigProps", "commonFlags"] {
            for p in c[key] as? [[String: Any]] ?? [] {
                guard let k = p["key"] as? String, k != "--temp-dir" else { continue }
                let v = "\(p["value"] ?? "")"
                parts += [k, v.contains(" ") ? "\"\(v)\"" : v]
            }
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - What the Audio tab shows about DME (refreshed in the background, never on the main thread)

@Observable final class DolbyStatus {
    static let shared = DolbyStatus()
    enum State: Equatable {
        case unknown
        case notInstalled
        case closed(String)                 // installed, not open: BROS-MUX opens it for the encode
        case checking
        case ready(String)                  // "Dolby Media Encoder 4.0.0 · licence active until 3 Feb 2027"
        case notReady(String)               // why the encode can't run (no licence, no server…)
    }
    var state: State = .unknown
    private var busy = false

    /// Reads DME's state; `open` also opens DME when it's closed, to ask its licence
    func refresh(open: Bool = false) {
        guard !busy else { return }
        busy = true
        if DolbyEncode.appURL == nil { state = .notInstalled; busy = false; return }
        if !open && DolbyEncode.runningPID() == nil { state = .closed(DolbyEncode.name); busy = false; return }
        state = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            let next: State
            do {
                let s = try DolbyEncode.server(launch: open, wait: 90)
                let l = try DolbyEncode.licence(s)
                next = l.ready ? .ready("\(DolbyEncode.name) · \(DolbyEncode.licenceText(l))")
                               : .notReady("\(DolbyEncode.name) has no active licence (\(l.errors.first ?? "it says it isn't ready")) — activate it in iLok License Manager.")
            } catch {
                next = .notReady(error.localizedDescription)
            }
            DispatchQueue.main.async { self.state = next; self.busy = false }
        }
    }
}
