// BROS-MUX — reads Dolby Atmos object positions (OAMD) from an E-AC-3 JOC stream for the visualizer.
// The bitstream parsing itself lives in AtmosOAMD.swift (written from ETSI TS 102 366 / TS 103 420).

import Foundation

enum AtmosDecoder {
    /// Finds the E-AC-3 JOC track in the file and returns the object positions over time.
    static func decode(_ url: URL, progress: @escaping (String) -> Void) throws -> (frames: [VizFrame], summary: [String]) {
        guard let probe = Probe.raw(url), let streams = probe.streams else { throw AppError("Couldn't read this file.") }
        let eac3 = streams.filter { $0.codec_name == "eac3" }
        guard let s = eac3.first(where: { ($0.profile ?? "").localizedCaseInsensitiveContains("atmos") }) ?? eac3.first else {
            throw AppError("This file has no Dolby Digital Plus (E-AC-3) track. The visualizer reads Dolby Atmos delivered as E-AC-3 JOC — TrueHD and ADM masters aren't supported.")
        }
        guard let ffmpeg = Tools.ffmpeg else { throw AppError("ffmpeg not found") }
        progress("Extracting the Dolby stream…")
        guard let raw = Tools.runSync(ffmpeg, ["-nostdin", "-v", "error", "-i", url.path, "-map", "0:\(s.index)", "-c", "copy", "-f", "eac3", "-"]),
              !raw.isEmpty else { throw AppError("Couldn't extract the E-AC-3 stream.") }
        progress("Reading the object metadata…")
        let sampleRate = Double(s.sample_rate ?? "") ?? 48000
        let parsed: (frames: [AtmosFrame], summary: String)
        do { parsed = try parseAtmos(raw, sampleRate: sampleRate) }
        catch let e as AtmosParseError { throw AppError("No Atmos object metadata found: \(e.description.components(separatedBy: "\n").first ?? "")") }

        var frames: [VizFrame] = []
        frames.reserveCapacity(parsed.frames.count)
        var dynamicIDs = Set<Int>(), beds = Set<String>()
        var parked = 0, dynamicSamples = 0
        for f in parsed.frames {
            var objs: [VizObject] = []
            objs.reserveCapacity(f.objects.count)
            for o in f.objects {
                // the Dolby encoder parks idle clusters at (0,0,0) — the front-left corner; they're hidden by default
                let isParked = !o.isBed && o.x == 0 && o.y == 0 && o.z == 0
                if o.isBed { beds.insert(o.bedChannel?.rawValue ?? "bed") }
                else { dynamicIDs.insert(o.id); dynamicSamples += 1; if isParked { parked += 1 } }
                objs.append(VizObject(id: o.id, x: Float(o.x), y: Float(o.y), z: Float(o.z),
                                      gain: Float(o.gain ?? 1), size: Float(o.size ?? 0), isBed: o.isBed,
                                      isParked: isParked, isActive: o.isActive))
            }
            frames.append(VizFrame(time: f.time, objects: objs))
        }
        guard !frames.isEmpty else { throw AppError("No Atmos object metadata found in this stream.") }
        let step = frames.count > 1 ? (frames[frames.count - 1].time - frames[0].time) / Double(frames.count - 1) : 0
        var summary = [
            "\(dynamicIDs.count) dynamic objects" + (beds.isEmpty ? "" : " + bed: " + beds.sorted().joined(separator: ", ")),
            "\(Fmt.int(frames.count)) metadata updates · one every \(String(format: "%.0f", step * 1000)) ms · \(Fmt.duration(frames.last?.time ?? 0))",
        ]
        if dynamicSamples > 0 && parked > 0 {
            summary.append(String(format: "%.0f%% of samples are idle clusters parked at (0,0,0) — hidden", Double(parked) / Double(dynamicSamples) * 100))
        }
        summary.append("Objects are Dolby's spatial clusters (JOC), not the original mix stems")
        return (frames, summary)
    }
}
