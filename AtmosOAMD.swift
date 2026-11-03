//  AtmosOAMD.swift
//
//  Standalone parser for Dolby Atmos object metadata ("OAMD") carried in E-AC-3 JOC
//  bitstreams ("Dolby Digital Plus with Dolby Atmos"). Foundation only, no third-party code.
//
//  Written from the public ETSI specifications:
//    * ETSI TS 102 366 V1.4.1 (2017-09)  E-AC-3 syncframe header (Annex E), CRC (6.10.1),
//                                        EMDF container (Annex H)
//    * ETSI TS 103 420 V1.2.1 (2018-10)  object audio metadata syntax/semantics (clause 5),
//                                        joc_header (6.2.2), EMDF carriage rules (clause 8)
//  Original code. Cavern (custom licence) and MediaInfoLib (BSD-2-Clause) were consulted only to
//  cross-check ambiguous bit orders; nothing was copied from them.
//
//  Usage: let (frames, summary) = try parseAtmos(rawEAC3Bytes, sampleRate: 48000)
//  Validated on a 1-hour 768 kb/s E-AC-3 JOC file (16 objects = LFE + 15 dynamic): see report.
//
//  ---------------------------------------------------------------------------------------
//  Coordinate convention (room-anchored, TS 103 420 clause 4.2.1, values passed through):
//    x : 0 = left wall    ... 1 = right wall
//    y : 0 = front wall (screen) ... 1 = back wall
//    z : 0 = horizontal plane of the main (ear-level) speaker layer ... 1 = ceiling.
//        This is the usual "floor -> ceiling" of an Atmos room view. The spec's cuboid
//        technically extends down to z = -1 (physical floor) and the bitstream can code
//        negative z; such values are passed through unclamped (dynamic Atmos objects
//        normally stay in 0...1 -- TS 103 420 Annex B clamps z to [0,1] for ADM export).
//  Bed objects (speaker-anchored) get the nominal speaker position of TS 103 420
//  Table B.10 converted to these room coordinates; the LFE sits at (0, 0, -1).
//
//  Bit-array convention (the spec text is ambiguous; see the notes at `OAMDBits`).
//  ---------------------------------------------------------------------------------------

import Foundation

// MARK: - Public model

/// Nominal bed speaker labels (TS 103 420 clause 4.4 / Table B.10), in bitstream channel order.
public enum AtmosSpeaker: String, Sendable, CaseIterable {
    case L, R, C, LFE, Ls, Rs, Lb, Rb, Tfl, Tfr, Tsl, Tsr, Tbl, Tbr, Lw, Rw, LFE2

    /// Nominal position in the room coordinates documented at the top of this file.
    public var position: (x: Double, y: Double, z: Double) {
        switch self {
        case .L: return (0, 0, 0)
        case .R: return (1, 0, 0)
        case .C: return (0.5, 0, 0)
        case .LFE: return (0, 0, -1)
        case .Ls: return (0, 0.5, 0)
        case .Rs: return (1, 0.5, 0)
        case .Lb: return (0, 1, 0)
        case .Rb: return (1, 1, 0)
        case .Tfl: return (0, 0, 1)
        case .Tfr: return (1, 0, 1)
        case .Tsl: return (0, 0.5, 1)
        case .Tsr: return (1, 0.5, 1)
        case .Tbl: return (0, 1, 1)
        case .Tbr: return (1, 1, 1)
        case .Lw: return (0, 10.0 / 62.0, 0)
        case .Rw: return (1, 10.0 / 62.0, 0)
        case .LFE2: return (1, 0, -1)
        }
    }
}

/// One object's state at one metadata update.
public struct AtmosObject: Sendable, Equatable {
    /// Index in the OAMD object list. Bed objects come first, then ISF, then dynamic objects.
    /// For the usual E-AC-3 JOC layout (LFE-only bed) id 0 is the LFE and ids 1...N are the
    /// N dynamic objects (N = JOC object count, e.g. 15).
    public let id: Int
    public let x: Double
    public let y: Double
    public let z: Double
    /// Linear amplitude gain carried in the metadata (1.0 = 0 dB, 0.0 = -inf dB). This is
    /// metadata only - it says nothing about how loud the object's audio actually is.
    public let gain: Double?
    /// Object size 0 (point source) ... 1 (as large as the room). If width/depth/height are
    /// coded separately this is the largest of the three. nil for bed/ISF objects.
    public let size: Double?
    /// true for every object whose position is not dynamic (bed channels; ISF objects).
    public let isBed: Bool
    /// false when the bitstream flags the object's audio essence as silent (b_object_not_active).
    public let isActive: Bool
    /// Speaker label for bed objects, nil otherwise.
    public let bedChannel: AtmosSpeaker?
}

/// All objects at one metadata update (one OAMD "info block"; usually one per 1536-sample frame).
public struct AtmosFrame: Sendable {
    /// Seconds from the start of the raw stream at which this update starts
    /// (syncframe start + sample_offset + 32 * block_offset_factor).
    public let time: Double
    /// Seconds over which a renderer ramps from the previous values to these values.
    /// For smooth drawing interpolate: prev + (cur - prev) * clamp((t - time) / rampDuration, 0, 1).
    public let rampDuration: Double
    public let objects: [AtmosObject]
}

public enum AtmosParseError: Error, CustomStringConvertible {
    case noSyncFrames
    case noObjectMetadata(summary: String)

    public var description: String {
        switch self {
        case .noSyncFrames: return "no AC-3/E-AC-3 syncframes found in the input"
        case .noObjectMetadata(let s): return "no valid object audio metadata found\n" + s
        }
    }
}

/// Parses raw E-AC-3 bytes (concatenated syncframes, e.g. `ffmpeg -c copy -f eac3`) and
/// returns object metadata over time plus a human-readable summary for sanity checks.
/// `sampleRate` is used for all timestamps (the summary flags a mismatch with the headers).
public func parseAtmos(_ raw: Data, sampleRate: Double) throws -> (frames: [AtmosFrame], summary: String) {
    let parser = AtmosStreamParser(sampleRate: sampleRate)
    raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        if let base = buf.baseAddress, buf.count > 0 {
            parser.run(base.assumingMemoryBound(to: UInt8.self), count: buf.count)
        }
    }
    if parser.stats.syncFrames == 0 { throw AtmosParseError.noSyncFrames }
    let summary = parser.makeSummary()
    if parser.frames.isEmpty { throw AtmosParseError.noObjectMetadata(summary: summary) }
    return (parser.frames, summary)
}

// MARK: - Bit-array conventions

/// TS 103 420 writes multi-bit flag fields as arrays (`content_description[]`, `obj_render_info[]`...)
/// and is internally inconsistent about which array index is which bit (e.g. the syntax tests
/// obj_render_info[0] for the position while Table 31 assigns position to index 3).
/// Convention used here: array index 0 = first bit read (MSB of the field). This matches
/// MediaInfoLib (content_description, bed masks), Cavern (content_description, render flags) and
/// the AC-4 bed-mask example (TS 103 190-2 Table 65 / Example 2, tuple read in bitstream order).
/// None of these fields' ambiguous cases occur in the validation file (no beds besides the LFE,
/// no mixed updates), so they are NOT verified on real data. Masks on the field read MSB-first:
enum OAMDBits {
    // content_description[] (4 bits): [3] beds, [2] ISF, [1] dynamic, [0] reserved
    static let contentBeds = 0x1, contentISF = 0x2, contentDynamic = 0x4, contentReserved = 0x8
    // obj_render_info[] (4 bits), per Table 31: [3] position, [2] zones, [1] size, [0] screen ref.
    // (Same as Cavern.) Only matters for "mixed" updates in info blocks > 0.
    static let renderPosition = 0x1, renderZone = 0x2, renderSize = 0x4, renderScreen = 0x8
    // obj_basic_info[] (2 bits), per Table 30: [1] gain, [0] priority. NOTE: Cavern uses the
    // opposite (gain = 0x2). Only matters for "mixed" updates in info blocks > 0.
    static let basicGain = 0x1, basicPriority = 0x2
    // ext_prec_pos_presence[] (3 bits), per Table 43: [2] X, [1] Y, [0] Z.
    static let extX = 0x1, extY = 0x2, extZ = 0x4
}

// MARK: - Tables (TS 103 420 clause 5.6, TS 102 366 Table 4.13)

private let rampDurationTable: [Int] = [32, 64, 128, 256, 320, 480, 1000, 1001, 1024, 1600, 1601, 1602, 1920, 2000, 2002, 2048]
private let sampleOffsetTable: [Int] = [8, 16, 18, 24]
private let distanceFactorTable: [Double] = [1.1, 1.3, 1.6, 2.0, 2.5, 3.2, 4.0, 5.0, 6.3, 7.9, 10.0, 12.6, 15.8, 20.0, 25.1, 50.1]
private let depthFactorTable: [Double] = [0.25, 0.5, 1, 2]
private let isfObjectCounts: [Int] = [4, 8, 10, 14, 15, 30, 0, 0]
private let extPrecTable: [Int] = [1, 2, -1, -2]
private let emdfProtectionBits: [Int] = [0, 8, 32, 128]
private let stdBedGroups: [[AtmosSpeaker]] = [[.L, .R], [.C], [.LFE], [.Ls, .Rs], [.Lb, .Rb],
                                              [.Tfl, .Tfr], [.Tsl, .Tsr], [.Tbl, .Tbr], [.Lw, .Rw], [.LFE2]]
private let ac3Bitrates: [Int] = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]

private let crc16Table: [UInt16] = (0..<256).map { i -> UInt16 in
    var c = UInt16(i) << 8
    for _ in 0..<8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x8005 : (c << 1) }   // x^16 + x^15 + x^2 + 1
    return c
}

/// Slicing-by-8 tables: entry [k * 256 + c] = CRC of byte c followed by k zero bytes.
private let crc16Slice8: [UInt16] = {
    var t = [UInt16](repeating: 0, count: 8 * 256)
    for c in 0..<256 { t[c] = crc16Table[c] }
    for k in 1..<8 {
        for c in 0..<256 {
            let prev = t[(k - 1) * 256 + c]
            t[k * 256 + c] = (prev << 8) ^ crc16Table[Int(prev >> 8)]
        }
    }
    return t
}()

/// For each byte value, a bit mask of shifts k (0...7) for which that byte is the fully covered
/// middle byte of the EMDF syncword 0x5838 ending k bits before the end of the following byte.
private let emdfMidByteMask: [UInt8] = {
    var t = [UInt8](repeating: 0, count: 256)
    for k in 0..<8 { t[(0x5838 >> (8 - k)) & 0xFF] |= UInt8(1 << k) }
    return t
}()

// MARK: - Bit reader

struct BitOverrun: Error {}

/// Big-endian (MSB-first) bit reader over a byte buffer, bounded to [pos, end) in bits.
struct BitReader {
    let p: UnsafePointer<UInt8>
    var pos: Int
    let end: Int

    init(_ p: UnsafePointer<UInt8>, bitPos: Int, bitEnd: Int) {
        self.p = p; self.pos = bitPos; self.end = bitEnd
    }

    @inline(__always)
    mutating func read(_ n: Int) throws -> Int {
        if n == 0 { return 0 }
        guard n <= 32, n <= end - pos else { throw BitOverrun() }
        let byte = pos >> 3
        let off = pos & 7
        let nBytes = (off + n + 7) >> 3
        var acc: UInt64 = 0
        for i in 0..<nBytes { acc = (acc << 8) | UInt64(p[byte + i]) }
        pos += n
        return Int(truncatingIfNeeded: (acc >> UInt64(nBytes * 8 - off - n)) & ((UInt64(1) << UInt64(n)) - 1))
    }

    @inline(__always)
    mutating func bit() throws -> Bool { try read(1) != 0 }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, n <= end - pos else { throw BitOverrun() }
        pos += n
    }

    /// EMDF variable_bits(n) (TS 102 366 H.2.1.2.1), capped at `maxGroups` groups to reject garbage.
    mutating func variableBits(_ n: Int, maxGroups: Int = 4) throws -> Int {
        var value = 0
        var groups = 0
        while true {
            value += try read(n)
            groups += 1
            guard try bit() else { return value }
            guard groups < maxGroups else { throw BitOverrun() }
            value <<= n
            value += 1 << n
        }
    }

    /// variable_bits_max(n, max_num_groups), TS 103 420 clause 5.5.1 (transcribed literally).
    mutating func variableBitsMax(_ n: Int, _ maxNumGroups: Int) throws -> Int {
        var value = 0
        var numGroup = 1
        value += try read(n)
        var more = try bit()
        if maxNumGroups > numGroup {
            if more { value <<= n; value += 1 << n }
            while more {
                value += try read(n)
                more = try bit()
                if numGroup >= maxNumGroups { break }
                if more { value <<= n; value += 1 << n; numGroup += 1 }
            }
        }
        return value
    }

    /// true if every bit in [pos, limit) is zero (used to verify padding).
    func remainingBitsAreZero(upTo limit: Int) -> Bool {
        var q = pos
        while q < limit {
            let off = q & 7
            let take = min(8 - off, limit - q)
            let byte = Int(p[q >> 3])
            let bits = (byte >> (8 - off - take)) & ((1 << take) - 1)
            if bits != 0 { return false }
            q += take
        }
        return true
    }
}

@inline(__always) private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
@inline(__always) private func signed3(_ v: Int) -> Int { v >= 4 ? v - 8 : v }

// MARK: - E-AC-3 / AC-3 syncframe header

struct SyncFrameHeader {
    var isEAC3: Bool
    var streamType: Int     // 0 = independent, 1 = dependent, 2 = independent (converted AC-3)
    var substreamID: Int
    var frameBytes: Int
    var sampleRate: Int
    var blocks: Int         // audio blocks (256 samples each) per syncframe
}

func parseSyncFrameHeader(_ p: UnsafePointer<UInt8>, available: Int) -> SyncFrameHeader? {
    guard available >= 6, p[0] == 0x0B, p[1] == 0x77 else { return nil }
    let bsid = Int(p[5] >> 3)
    if bsid <= 10 {                                   // AC-3 (TS 102 366 clause 4.3)
        let fscod = Int(p[4] >> 6), frmsizecod = Int(p[4] & 0x3F)
        guard fscod < 3, frmsizecod < 38 else { return nil }
        let kbps = ac3Bitrates[frmsizecod >> 1]
        let words: Int
        switch fscod {
        case 0: words = kbps * 2
        case 1: words = kbps * 1_536_000 / (44_100 * 16) + (frmsizecod & 1)
        default: words = kbps * 3
        }
        return SyncFrameHeader(isEAC3: false, streamType: 0, substreamID: 0, frameBytes: words * 2,
                               sampleRate: [48000, 44100, 32000][fscod], blocks: 6)
    } else if bsid <= 16 {                            // E-AC-3 (TS 102 366 Annex E.1.2.2)
        let strmtyp = Int(p[2] >> 6)
        guard strmtyp != 3 else { return nil }
        let frmsiz = (Int(p[2] & 7) << 8) | Int(p[3])
        let fscod = Int(p[4] >> 6)
        let code2 = Int((p[4] >> 4) & 3)
        let rate: Int, blocks: Int
        if fscod == 3 {
            guard code2 < 3 else { return nil }
            rate = [24000, 22050, 16000][code2]; blocks = 6
        } else {
            rate = [48000, 44100, 32000][fscod]; blocks = [1, 2, 3, 6][code2]
        }
        return SyncFrameHeader(isEAC3: true, streamType: strmtyp, substreamID: Int((p[2] >> 3) & 7),
                               frameBytes: (frmsiz + 1) * 2, sampleRate: rate, blocks: blocks)
    }
    return nil
}

/// CRC over everything after the syncword; a valid AC-3/E-AC-3 syncframe yields 0 (TS 102 366 6.10.1).
func syncFrameCRCIsValid(_ p: UnsafePointer<UInt8>, frameBytes: Int) -> Bool {
    syncFrameCRC(p, from: 2, to: frameBytes) == 0
}

/// CRC-16 (x^16 + x^15 + x^2 + 1, MSB first, register starting at 0) of bytes [from, to).
func syncFrameCRC(_ p: UnsafePointer<UInt8>, from: Int, to: Int) -> UInt16 {
    var crc: UInt16 = 0
    crc16Slice8.withUnsafeBufferPointer { t in
        var i = from
        while i + 8 <= to {
            crc = t[7 * 256 + Int(UInt16(p[i]) ^ (crc >> 8))] ^ t[6 * 256 + Int(UInt16(p[i + 1]) ^ (crc & 0xFF))]
                ^ t[5 * 256 + Int(p[i + 2])] ^ t[4 * 256 + Int(p[i + 3])] ^ t[3 * 256 + Int(p[i + 4])]
                ^ t[2 * 256 + Int(p[i + 5])] ^ t[256 + Int(p[i + 6])] ^ t[Int(p[i + 7])]
            i += 8
        }
        while i < to {
            crc = (crc << 8) ^ t[Int((crc >> 8) ^ UInt16(p[i]))]
            i += 1
        }
    }
    return crc
}

// MARK: - EMDF container (TS 102 366 Annex H)

struct EMDFPayloadRef {
    let id: Int
    let bitStart: Int
    let byteCount: Int
    let sampleOffset: Int?   // smploffst if smploffste
}

/// Validates an EMDF container whose syncword starts at `syncBit`; returns its payloads or nil.
/// Checks: container fits before `limitBit`, emdf_version 0, payload loop terminates inside the
/// container, protection length code valid, and all slack bits up to the container end are zero.
func parseEMDFContainer(_ p: UnsafePointer<UInt8>, syncBit: Int, limitBit: Int, containerEnd: inout Int) -> [EMDFPayloadRef]? {
    guard syncBit + 32 <= limitBit else { return nil }
    var head = BitReader(p, bitPos: syncBit + 16, bitEnd: limitBit)
    guard let length = try? head.read(16), length >= 3 else { return nil }
    let start = syncBit + 32
    let end = start + length * 8
    guard end <= limitBit else { return nil }
    var r = BitReader(p, bitPos: start, bitEnd: end)
    do {
        var version = try r.read(2)
        if version == 3 { version += try r.variableBits(2) }
        guard version == 0 else { return nil }
        let keyID = try r.read(3)
        if keyID == 7 { _ = try r.variableBits(3) }
        var payloads: [EMDFPayloadRef] = []
        while true {
            var id = try r.read(5)
            if id == 0 { break }
            if id == 0x1F { id += try r.variableBits(5) }
            // emdf_payload_config()
            let smploffste = try r.bit()
            var smploffst: Int? = nil
            if smploffste { smploffst = try r.read(11); try r.skip(1) }
            if try r.bit() { _ = try r.variableBits(11) }     // duration
            if try r.bit() { _ = try r.variableBits(2) }      // groupid
            if try r.bit() { try r.skip(8) }                  // codecdata
            let discardUnknown = try r.bit()
            if !discardUnknown {
                var frameAligned = false
                if !smploffste {
                    frameAligned = try r.bit()
                    if frameAligned { try r.skip(2) }        // create_duplicate, remove_duplicate
                }
                if smploffste || frameAligned { try r.skip(7) } // priority, proc_allowed
            }
            let size = try r.variableBits(8)
            guard size * 8 <= r.end - r.pos, payloads.count < 64 else { return nil }
            payloads.append(EMDFPayloadRef(id: id, bitStart: r.pos, byteCount: size, sampleOffset: smploffst))
            r.pos += size * 8
        }
        // emdf_protection()
        let primary = try r.read(2)
        guard primary != 0 else { return nil }
        let secondary = try r.read(2)
        try r.skip(emdfProtectionBits[primary] + emdfProtectionBits[secondary])
        guard r.remainingBitsAreZero(upTo: end) else { return nil }
        containerEnd = end
        return payloads
    } catch {
        return nil
    }
}

// MARK: - OAMD payload (TS 103 420 clause 5.5)

enum OAMDFailure: String, Error, CaseIterable {
    case unsupportedVersion = "unsupported oa_md_version"
    case truncated = "ran past payload/element end"
    case objectCountMismatch = "program_assignment counts != object_count"
    case elementOverrun = "oa_element larger than payload"
    case elementPadding = "object_element padding not zero (syntax mismatch)"
    case payloadPadding = "payload padding not zero (syntax mismatch)"
    case noObjectElement = "no object_element in payload"
}

/// Per-object state of one info block, kept as coded integers so differential coding works.
struct OAMDObjectState {
    var active = false
    var gainDB = 0.0
    var priority = 0.0
    var xCode = 31, yCode = 31, zCode = 0         // standard-precision position codes
    var posAbsolute = true                        // last coded position was absolute (z sign semantics)
    var zNegative = false
    var extX = 0, extY = 0, extZ = 0              // extended precision, in 1/5 of a code step
    var distanceFactor: Double? = nil             // b_object_distance_specified (inf = at infinity)
    var width = 0.0, depth = 0.0, height = 0.0
    var zone = 0
    var elevation = true
    var screenRef = false
    var snap = false

    mutating func resetRender() {
        xCode = 31; yCode = 31; zCode = 0; posAbsolute = true; zNegative = false
        extX = 0; extY = 0; extZ = 0; distanceFactor = nil
        width = 0; depth = 0; height = 0; zone = 0; elevation = true; screenRef = false; snap = false
    }

    var position: (Double, Double, Double) {
        let x = clamp((Double(xCode) + Double(extX) / 5) / 62, 0, 1)
        let y = clamp((Double(yCode) + Double(extY) / 5) / 62, 0, 1)
        let z: Double
        if posAbsolute {
            z = clamp((zNegative ? -1.0 : 1.0) * (Double(abs(zCode)) + Double(extZ) / 5) / 15, -1, 1)
        } else {
            z = clamp((Double(zCode) + Double(extZ) / 5) / 15, -1, 1)
        }
        return (x, y, z)
    }
}

/// Counters for code paths, so callers can see which (less tested) syntax features a stream uses.
struct OAMDUsage {
    var blocksPerPayload: [Int: Int] = [:]
    var sampleOffsets: [Int: Int] = [:]
    var rampDurations: [Int: Int] = [:]
    var elementIDs: [Int: Int] = [:]
    var basicReuse = 0, basicMixed = 0, renderReuse = 0, renderMixed = 0
    var differentialPositions = 0, extendedPrecision = 0, extendedElementBad = 0
    var distanceSpecified = 0, screenRef = 0, nonZeroSize = 0, zoneConstraints = 0, snap = 0
    var inactiveObjectBlocks = 0, additionalTableData = 0, reservedSampleOffset = 0, reservedSizeIdx = 0
    var gainCodes: [Int: Int] = [:]
}

struct ParsedOAMD {
    var objectCount = 0
    var bedSpeakers: [AtmosSpeaker] = []
    var isfCount = 0
    var dynamicCount = 0
    var programDescription = ""
    var blockStart: [Int] = []          // start sample of each info block, relative to the syncframe
    var blockRamp: [Int] = []           // ramp duration of each info block, in samples
    var states: [OAMDObjectState] = []  // index = object * blocks + block
    var blocks: Int { blockStart.count }
}

func parseOAMDPayload(_ p: UnsafePointer<UInt8>, bitStart: Int, byteCount: Int,
                      usage: inout OAMDUsage) throws -> ParsedOAMD {
    var out = ParsedOAMD()
    let payloadEnd = bitStart + byteCount * 8
    var r = BitReader(p, bitPos: bitStart, bitEnd: payloadEnd)
    do {
        // object_audio_metadata_payload()
        var version = try r.read(2)
        if version == 3 { version += try r.read(3) }
        guard version == 0 else { throw OAMDFailure.unsupportedVersion }
        var countBits = try r.read(5)
        if countBits == 0x1F { countBits += try r.read(7) }
        out.objectCount = countBits + 1

        // program_assignment()
        if try r.bit() {                                     // b_dyn_object_only_program
            let lfe = try r.bit()
            if lfe { out.bedSpeakers = [.LFE] }
            out.dynamicCount = out.objectCount - out.bedSpeakers.count
            out.programDescription = lfe ? "dynamic objects + LFE" : "dynamic objects only"
        } else {
            let content = try r.read(4)
            var parts: [String] = []
            if content & OAMDBits.contentBeds != 0 {
                _ = try r.bit()                              // b_bed_chan_distribute
                var instances = 1
                if try r.bit() { instances = try r.read(3) + 2 }
                for _ in 0..<instances {
                    if try r.bit() {                         // b_lfe_only
                        out.bedSpeakers.append(.LFE)
                    } else if try r.bit() {                  // b_standard_chan_assign
                        let mask = try r.read(10)
                        for k in 0..<10 where mask & (1 << k) != 0 { out.bedSpeakers += stdBedGroups[k] }
                    } else {
                        let mask = try r.read(17)
                        for k in 0..<17 where mask & (1 << k) != 0 { out.bedSpeakers.append(AtmosSpeaker.allCases[k]) }
                    }
                }
                parts.append("bed " + out.bedSpeakers.map { $0.rawValue }.joined(separator: " "))
            }
            if content & OAMDBits.contentISF != 0 {
                let idx = try r.read(3)
                out.isfCount = isfObjectCounts[idx]
                parts.append("ISF idx \(idx)")
            }
            if content & OAMDBits.contentDynamic != 0 {
                var n = try r.read(5)
                if n == 0x1F { n += try r.read(7) }
                out.dynamicCount = n + 1
                parts.append("\(out.dynamicCount) dynamic")
            }
            if content & OAMDBits.contentReserved != 0 {
                let size = try r.read(4) + 1
                try r.skip(size * 8)
            }
            out.programDescription = parts.joined(separator: " + ")
        }
        guard out.bedSpeakers.count + out.isfCount + out.dynamicCount == out.objectCount else {
            throw OAMDFailure.objectCountMismatch
        }

        let alternatePresent = try r.bit()
        var elementCount = try r.read(4)
        if elementCount == 0xF { elementCount += try r.read(5) }
        var objectElement: Range<Int>? = nil
        var extendedElement: Range<Int>? = nil
        for _ in 0..<elementCount {                           // oa_element_md()
            let elementID = try r.read(4)
            let size = try r.variableBitsMax(4, 4) + 1
            let bodyEnd = r.pos + size * 8                     // size covers alt id, discard flag, element, padding
            guard bodyEnd <= payloadEnd else { throw OAMDFailure.elementOverrun }
            var alternateID = 0
            if alternatePresent { alternateID = try r.read(4) }
            _ = try r.bit()                                    // b_discard_unknown_element
            usage.elementIDs[elementID, default: 0] += 1
            if alternateID == 0 {
                if elementID == 1, objectElement == nil { objectElement = r.pos..<bodyEnd }
                if elementID == 5, extendedElement == nil { extendedElement = r.pos..<bodyEnd }
            }
            r.pos = bodyEnd
        }
        guard r.remainingBitsAreZero(upTo: payloadEnd) else { throw OAMDFailure.payloadPadding }
        guard let element = objectElement else { throw OAMDFailure.noObjectElement }
        try parseObjectElement(p, element, &out, &usage)
        if let ext = extendedElement { parseExtendedElement(p, ext, &out, &usage) }
        return out
    } catch is BitOverrun {
        throw OAMDFailure.truncated
    }
}

/// object_element() (clause 5.5.5-5.5.11).
private func parseObjectElement(_ p: UnsafePointer<UInt8>, _ range: Range<Int>,
                                _ out: inout ParsedOAMD, _ usage: inout OAMDUsage) throws {
    var r = BitReader(p, bitPos: range.lowerBound, bitEnd: range.upperBound)
    // md_update_info()
    var sampleOffset = 0
    switch try r.read(2) {
    case 1: sampleOffset = sampleOffsetTable[try r.read(2)]
    case 2: sampleOffset = try r.read(5)
    case 3: usage.reservedSampleOffset += 1
    default: break
    }
    let blocks = try r.read(3) + 1
    for _ in 0..<blocks {                                     // block_update_info()
        let offsetFactor = try r.read(6)
        var ramp = 0
        switch try r.read(2) {
        case 0: ramp = 0
        case 1: ramp = 512
        case 2: ramp = 1536
        default:
            if try r.bit() { ramp = rampDurationTable[try r.read(4)] } else { ramp = try r.read(11) }
        }
        out.blockStart.append(sampleOffset + 32 * offsetFactor)
        out.blockRamp.append(ramp)
        usage.rampDurations[ramp, default: 0] += 1
    }
    usage.blocksPerPayload[blocks, default: 0] += 1
    usage.sampleOffsets[sampleOffset, default: 0] += 1
    let reservedDataNotPresent = try r.bit()
    if !reservedDataNotPresent { try r.skip(5) }

    let staticCount = out.bedSpeakers.count + out.isfCount
    out.states = [OAMDObjectState](repeating: OAMDObjectState(), count: out.objectCount * blocks)
    for j in 0..<out.objectCount {                            // object_data()
        let inBedOrISF = j < staticCount
        var prev = OAMDObjectState()
        for blk in 0..<blocks {                               // object_info_block(blk)
            var s = prev
            let notActive = try r.bit()
            s.active = !notActive
            if notActive { usage.inactiveObjectBlocks += 1 }

            // object_basic_info
            var basicStatus = 0
            if !notActive {
                if blk == 0 { basicStatus = 1 } else { basicStatus = try r.read(2) }
            }
            switch basicStatus {
            case 0:
                s.gainDB = -.infinity; s.priority = 0
            case 1, 3:
                var flags = OAMDBits.basicGain | OAMDBits.basicPriority
                if basicStatus == 3 { flags = try r.read(2); usage.basicMixed += 1 }
                if flags & OAMDBits.basicGain != 0 {
                    let gainIdx = try r.read(2)
                    usage.gainCodes[gainIdx, default: 0] += 1
                    switch gainIdx {
                    case 0: s.gainDB = 0
                    case 1: s.gainDB = -.infinity
                    case 2:
                        let g = try r.read(6)
                        s.gainDB = g < 15 ? Double(15 - g) : Double(14 - g)
                    default:                                  // same as the previous object in this block
                        s.gainDB = j > 0 ? out.states[(j - 1) * blocks + blk].gainDB : 0
                    }
                }
                if flags & OAMDBits.basicPriority != 0 {
                    if try r.bit() { s.priority = 1 } else { s.priority = Double(try r.read(5)) / 32 }
                }
            default:
                usage.basicReuse += 1
            }

            // object_render_info
            var renderStatus = 0
            if !notActive && !inBedOrISF {
                if blk == 0 { renderStatus = 1 } else { renderStatus = try r.read(2) }
            }
            switch renderStatus {
            case 0:
                s.resetRender()
            case 1, 3:
                var flags = 0xF
                if renderStatus == 3 { flags = try r.read(4); usage.renderMixed += 1 }
                if flags & OAMDBits.renderPosition != 0 {
                    var differential = false
                    if blk > 0 { differential = try r.bit() }
                    if differential {                         // 3-bit two's complement deltas
                        let dx = signed3(try r.read(3)), dy = signed3(try r.read(3)), dz = signed3(try r.read(3))
                        s.xCode = min(62, max(0, prev.xCode + dx))
                        s.yCode = min(62, max(0, prev.yCode + dy))
                        s.zCode = min(15, max(-15, prev.zCode + dz))
                        s.posAbsolute = false
                        usage.differentialPositions += 1
                    } else {
                        s.xCode = try r.read(6)
                        s.yCode = try r.read(6)
                        let positive = try r.bit()
                        let zBits = try r.read(4)
                        s.zCode = positive ? zBits : -zBits
                        s.zNegative = !positive
                        s.posAbsolute = true
                    }
                    s.extX = 0; s.extY = 0; s.extZ = 0
                    s.distanceFactor = nil
                    if try r.bit() {                          // b_object_distance_specified
                        usage.distanceSpecified += 1
                        if try r.bit() { s.distanceFactor = .infinity } else { s.distanceFactor = distanceFactorTable[try r.read(4)] }
                    }
                }
                if flags & OAMDBits.renderZone != 0 {
                    s.zone = try r.read(3)
                    s.elevation = try r.bit()
                    if s.zone != 0 || !s.elevation { usage.zoneConstraints += 1 }
                }
                if flags & OAMDBits.renderSize != 0 {
                    switch try r.read(2) {
                    case 0: s.width = 0; s.depth = 0; s.height = 0
                    case 1:
                        let v = Double(try r.read(5)) / 31
                        s.width = v; s.depth = v; s.height = v
                    case 2:
                        s.width = Double(try r.read(5)) / 31
                        s.depth = Double(try r.read(5)) / 31
                        s.height = Double(try r.read(5)) / 31
                    default:
                        usage.reservedSizeIdx += 1
                    }
                    if s.width > 0 || s.depth > 0 || s.height > 0 { usage.nonZeroSize += 1 }
                }
                if flags & OAMDBits.renderScreen != 0 {
                    s.screenRef = try r.bit()
                    if s.screenRef { try r.skip(5); usage.screenRef += 1 }   // screen_factor_bits, depth_factor_idx
                }
                s.snap = try r.bit()
                if s.snap { usage.snap += 1 }
            default:
                usage.renderReuse += 1
            }

            if try r.bit() {                                  // b_additional_table_data_exists
                let bytes = try r.read(4) + 1
                try r.skip(bytes * 8)
                usage.additionalTableData += 1
            }
            out.states[j * blocks + blk] = s
            prev = s
        }
    }
    guard r.remainingBitsAreZero(upTo: range.upperBound) else { throw OAMDFailure.elementPadding }
}

/// extended_object_element() (clause 5.5.13-5.5.15): divergence (skipped) and extended precision.
/// Applied only if the element parses exactly; otherwise ignored (counted).
private func parseExtendedElement(_ p: UnsafePointer<UInt8>, _ range: Range<Int>,
                                  _ out: inout ParsedOAMD, _ usage: inout OAMDUsage) {
    var r = BitReader(p, bitPos: range.lowerBound, bitEnd: range.upperBound)
    let blocks = out.blocks
    let staticCount = out.bedSpeakers.count + out.isfCount
    var ext = [(Int, Int, Int)?](repeating: nil, count: out.states.count)
    do {
        if try r.bit() {                                       // b_obj_div_block
            for j in staticCount..<out.objectCount {
                for blk in 0..<blocks where out.states[j * blocks + blk].active {
                    if try r.bit() {                           // b_object_divergence
                        let mode = try r.read(2)
                        if mode == 0 { try r.skip(2) } else if mode >= 2 { try r.skip(6) }
                    }
                }
            }
        }
        if try r.bit() {                                       // b_ext_prec_pos_block
            for j in staticCount..<out.objectCount {
                for blk in 0..<blocks where out.states[j * blocks + blk].active {
                    if try r.bit() {                           // b_ext_prec_pos
                        let presence = try r.read(3)
                        var e = (0, 0, 0)
                        if presence & OAMDBits.extX != 0 { e.0 = extPrecTable[try r.read(2)] }
                        if presence & OAMDBits.extY != 0 { e.1 = extPrecTable[try r.read(2)] }
                        if presence & OAMDBits.extZ != 0 { e.2 = extPrecTable[try r.read(2)] }
                        ext[j * blocks + blk] = e
                    }
                }
            }
        }
        guard r.remainingBitsAreZero(upTo: range.upperBound) else { usage.extendedElementBad += 1; return }
    } catch {
        usage.extendedElementBad += 1
        return
    }
    for (i, e) in ext.enumerated() {
        guard let e = e else { continue }
        out.states[i].extX = e.0; out.states[i].extY = e.1; out.states[i].extZ = e.2
        usage.extendedPrecision += 1
    }
}

// MARK: - Stream walker

struct AtmosStreamStats {
    var syncFrames = 0, accessUnits = 0, dependentFrames = 0, otherProgramFrames = 0, ac3Frames = 0
    var crcErrors = 0, resyncBytes = 0, trailingBytes = 0
    var lostAUs = 0, jocSplices = 0, jocSeqAnomalies = 0
    var headerRates: [Int: Int] = [:]
    var samplesPerFrame: [Int: Int] = [:]
    var totalSamples = 0
    var emdfContainers = 0, emdfCandidatesRejected = 0
    var payloadIDs: [Int: Int] = [:]
    var emdfSampleOffsetPresent = 0
    var oamdPayloads = 0, oamdAUs = 0, multipleOAMDInAU = 0
    var oamdFailures: [String: Int] = [:]
    var objectCounts: [Int: Int] = [:]
    var programs: [String: Int] = [:]
    var jocObjectCounts: [Int: Int] = [:]
    var jocDownmixConfigs: [Int: Int] = [:]
    var auWithoutOAMDRuns = 0
}

final class AtmosStreamParser {
    let sampleRate: Double
    var frames: [AtmosFrame] = []
    var stats = AtmosStreamStats()
    var usage = OAMDUsage()

    private var auStartSample = 0
    private var auSamples = 0
    private var lastSeq: Int? = nil                 // joc_seq_count of the last AU that carried JOC
    private var ausSinceSeq = 0                     // access units opened since then (incl. current)
    private var auOpen = false
    private var auOAMD: ParsedOAMD? = nil
    private var inProgramZero = false
    private var previousAUHadOAMD = true

    // value ranges over dynamic objects (for the summary)
    private var minX = Double.infinity, maxX = -Double.infinity
    private var minY = Double.infinity, maxY = -Double.infinity
    private var minZ = Double.infinity, maxZ = -Double.infinity
    private var minGainDB = Double.infinity, maxGainDB = -Double.infinity
    private var minSize = Double.infinity, maxSize = -Double.infinity
    private var dynamicSamples = 0

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func run(_ p: UnsafePointer<UInt8>, count n: Int) {
        var pos = 0
        var synced = false                             // the first frame must pass its CRC
        var skipped = 0                                // bytes skipped since sync was lost
        while pos + 6 <= n {
            guard let h = parseSyncFrameHeader(p + pos, available: n - pos), h.frameBytes >= 16 else {
                pos += 1; skipped += 1; synced = false; continue
            }
            if pos + h.frameBytes > n {
                if synced { stats.trailingBytes = n - pos; break }   // truncated last frame
                pos += 1; skipped += 1; continue                     // false sync while hunting
            }
            let crcOK = syncFrameCRCIsValid(p + pos, frameBytes: h.frameBytes)
            if !synced && !crcOK {                     // while hunting for sync, only trust CRC-valid frames
                pos += 1; skipped += 1; continue
            }
            stats.resyncBytes += skipped              // lost frames are re-timed via joc_seq_count (see handle)
            skipped = 0
            synced = true
            stats.syncFrames += 1
            if !crcOK { stats.crcErrors += 1 }

            let independent = !h.isEAC3 || h.streamType != 1
            if independent {
                if h.substreamID == 0 {
                    closeAccessUnit()
                    ausSinceSeq += 1
                    auOpen = true
                    auSamples = h.blocks * 256
                    inProgramZero = true
                    stats.accessUnits += 1
                    stats.headerRates[h.sampleRate, default: 0] += 1
                    stats.samplesPerFrame[auSamples, default: 0] += 1
                    if !h.isEAC3 { stats.ac3Frames += 1 }
                } else {
                    inProgramZero = false
                    stats.otherProgramFrames += 1
                }
            } else {
                stats.dependentFrames += 1
                if !inProgramZero { stats.otherProgramFrames += 1 }
            }
            if h.isEAC3 && inProgramZero && auOpen && crcOK {
                scanFrame(p, frameStart: pos, frameBytes: h.frameBytes)
            }
            pos += h.frameBytes
        }
        if pos < n && stats.trailingBytes == 0 { stats.trailingBytes = n - pos }
        stats.resyncBytes += skipped
        closeAccessUnit()
    }

    /// Finds EMDF containers anywhere in the syncframe (skip fields / auxdata), at any bit offset.
    private func scanFrame(_ p: UnsafePointer<UInt8>, frameStart: Int, frameBytes: Int) {
        let limitBit = (frameStart + frameBytes) * 8 - 17     // auxdatae + encinfo + crc2 follow
        var i = frameStart + 7
        let last = frameStart + frameBytes - 3
        emdfMidByteMask.withUnsafeBufferPointer { mask in
            while i <= last {
                var m = mask[Int(p[i - 1])]
                if m != 0 {
                    let acc = UInt32(p[i - 2]) << 16 | UInt32(p[i - 1]) << 8 | UInt32(p[i])
                    var jumpTo = 0
                    while m != 0 {
                        let k = m.trailingZeroBitCount
                        m &= m - 1
                        guard (acc >> UInt32(k)) & 0xFFFF == 0x5838 else { continue }
                        let syncBit = (i - 1) * 8 - k
                        var containerEnd = 0
                        if let payloads = parseEMDFContainer(p, syncBit: syncBit, limitBit: limitBit, containerEnd: &containerEnd) {
                            stats.emdfContainers += 1
                            handle(payloads, p)
                            jumpTo = (containerEnd >> 3) + 1   // don't rescan inside a valid container
                            break
                        } else {
                            stats.emdfCandidatesRejected += 1
                        }
                    }
                    if jumpTo > i { i = jumpTo; continue }
                }
                i += 1
            }
        }
    }

    private func handle(_ payloads: [EMDFPayloadRef], _ p: UnsafePointer<UInt8>) {
        for pl in payloads {
            stats.payloadIDs[pl.id, default: 0] += 1
            if pl.sampleOffset != nil { stats.emdfSampleOffsetPresent += 1 }
            switch pl.id {
            case 11:                                           // OAMD
                stats.oamdPayloads += 1
                do {
                    let parsed = try parseOAMDPayload(p, bitStart: pl.bitStart, byteCount: pl.byteCount, usage: &usage)
                    if auOAMD != nil { stats.multipleOAMDInAU += 1 }
                    auOAMD = parsed                              // keep the last one (last substream wins)
                } catch let f as OAMDFailure {
                    stats.oamdFailures[f.rawValue, default: 0] += 1
                } catch {
                    stats.oamdFailures["other", default: 0] += 1
                }
            case 14:                                           // JOC: joc_header + joc_seq_count only
                var r = BitReader(p, bitPos: pl.bitStart, bitEnd: pl.bitStart + pl.byteCount * 8)
                guard let dmx = try? r.read(3), let nobj = try? r.read(6), (try? r.skip(3 + 8)) != nil,
                      let seq = try? r.read(10) else { break }
                stats.jocDownmixConfigs[dmx, default: 0] += 1
                stats.jocObjectCounts[nobj + 1, default: 0] += 1
                // joc_seq_count (TS 103 420 6.3.3.3): +1 per frame, 1023 wraps to 1, 0 = start/splice.
                // If more frames elapsed than access units were seen, frames were lost: re-time.
                if seq == 0 {
                    if lastSeq != nil { stats.jocSplices += 1 }
                } else if let last = lastSeq {
                    let elapsed = ((seq - last) % 1023 + 1023) % 1023
                    let lost = elapsed - ausSinceSeq
                    if lost > 0 && auOpen {
                        auStartSample += lost * auSamples
                        stats.totalSamples += lost * auSamples
                        stats.lostAUs += lost
                    } else if lost < 0 {
                        stats.jocSeqAnomalies += 1
                    }
                }
                lastSeq = seq
                ausSinceSeq = 0
            default:
                break
            }
        }
    }

    private func closeAccessUnit() {
        guard auOpen else { return }
        defer {
            stats.totalSamples += auSamples
            auStartSample += auSamples
            auOpen = false
            auOAMD = nil
        }
        guard let o = auOAMD else {
            if previousAUHadOAMD { stats.auWithoutOAMDRuns += 1 }
            previousAUHadOAMD = false
            return
        }
        previousAUHadOAMD = true
        stats.oamdAUs += 1
        stats.objectCounts[o.objectCount, default: 0] += 1
        stats.programs[o.programDescription, default: 0] += 1
        let staticCount = o.bedSpeakers.count + o.isfCount
        for blk in 0..<o.blocks {
            var objects: [AtmosObject] = []
            objects.reserveCapacity(o.objectCount)
            for j in 0..<o.objectCount {
                let s = o.states[j * o.blocks + blk]
                let gain: Double? = s.gainDB == -.infinity ? 0 : pow(10, s.gainDB / 20)
                if j < o.bedSpeakers.count {
                    let sp = o.bedSpeakers[j], pos = sp.position
                    objects.append(AtmosObject(id: j, x: pos.x, y: pos.y, z: pos.z, gain: gain, size: nil,
                                               isBed: true, isActive: s.active, bedChannel: sp))
                } else if j < staticCount {
                    // ISF objects: stacked-ring layout not positioned by this parser
                    objects.append(AtmosObject(id: j, x: 0.5, y: 0.5, z: 0, gain: gain, size: nil,
                                               isBed: true, isActive: s.active, bedChannel: nil))
                } else {
                    let (x, y, z) = s.position
                    let size = max(s.width, s.depth, s.height)
                    objects.append(AtmosObject(id: j, x: x, y: y, z: z, gain: gain, size: size,
                                               isBed: false, isActive: s.active, bedChannel: nil))
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    minZ = min(minZ, z); maxZ = max(maxZ, z)
                    if s.gainDB.isFinite { minGainDB = min(minGainDB, s.gainDB); maxGainDB = max(maxGainDB, s.gainDB) }
                    minSize = min(minSize, size); maxSize = max(maxSize, size)
                    dynamicSamples += 1
                }
            }
            frames.append(AtmosFrame(time: Double(auStartSample + o.blockStart[blk]) / sampleRate,
                                     rampDuration: Double(o.blockRamp[blk]) / sampleRate,
                                     objects: objects))
        }
    }

    // MARK: summary

    func makeSummary() -> String {
        func hist<K: Comparable>(_ d: [K: Int], limit: Int = 8) -> String {
            if d.isEmpty { return "-" }
            let items = d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            let shown = items.prefix(limit).map { "\($0.key)x\($0.value)" }.joined(separator: ", ")
            return items.count > limit ? shown + ", ... (\(items.count) distinct)" : shown
        }
        func f(_ v: Double, _ digits: Int = 3) -> String { v.isFinite ? String(format: "%.\(digits)f", v) : "n/a" }
        let pct = stats.accessUnits > 0 ? 100.0 * Double(stats.oamdAUs) / Double(stats.accessUnits) : 0
        var s: [String] = []
        s.append("== E-AC-3 stream")
        s.append("syncframes \(stats.syncFrames) (access units / independent substream 0: \(stats.accessUnits), dependent: \(stats.dependentFrames), other programs: \(stats.otherProgramFrames), AC-3: \(stats.ac3Frames))")
        s.append("CRC errors \(stats.crcErrors) (frames kept for timing, metadata skipped), bytes skipped while resyncing \(stats.resyncBytes), trailing bytes \(stats.trailingBytes)")
        s.append("frames missing per joc_seq_count \(stats.lostAUs) (timestamps re-aligned), splices \(stats.jocSplices), counter anomalies \(stats.jocSeqAnomalies)")
        s.append("header sample rates [\(hist(stats.headerRates))], samples/frame [\(hist(stats.samplesPerFrame))], duration \(f(Double(stats.totalSamples) / sampleRate, 2)) s at \(Int(sampleRate)) Hz")
        if let rate = stats.headerRates.max(by: { $0.value < $1.value })?.key, Double(rate) != sampleRate {
            s.append("WARNING: sampleRate argument \(sampleRate) differs from the header rate \(rate) Hz; timestamps use the argument")
        }
        s.append("== EMDF")
        s.append("valid containers \(stats.emdfContainers), rejected 0x5838 candidates \(stats.emdfCandidatesRejected), payload ids [\(hist(stats.payloadIDs))] (1 loudness, 2 programme info, 11 OAMD, 14 JOC)")
        if stats.emdfSampleOffsetPresent > 0 { s.append("payloads with EMDF smploffst (ignored, OAMD sample_offset used): \(stats.emdfSampleOffsetPresent)") }
        s.append("== Object audio metadata")
        s.append("OAMD in \(stats.oamdAUs) of \(stats.accessUnits) access units (\(f(pct, 2))%), payloads \(stats.oamdPayloads), failures [\(hist(stats.oamdFailures))], gaps (runs without OAMD) \(stats.auWithoutOAMDRuns), duplicate OAMD in one AU \(stats.multipleOAMDInAU)")
        s.append("object_count [\(hist(stats.objectCounts))], program [\(hist(stats.programs))]")
        s.append("JOC header: objects [\(hist(stats.jocObjectCounts))], downmix config idx [\(hist(stats.jocDownmixConfigs))]")
        s.append("oa_element ids [\(hist(usage.elementIDs))] (1 object, 2 trim, 5 extended)")
        s.append("info blocks/payload [\(hist(usage.blocksPerPayload))], sample_offset [\(hist(usage.sampleOffsets))], ramp samples [\(hist(usage.rampDurations))]")
        s.append("gain idx [\(hist(usage.gainCodes))] (0 = 0 dB, 1 = -inf, 2 = coded, 3 = same as previous object)")
        s.append("less common paths: basic reuse \(usage.basicReuse), basic mixed \(usage.basicMixed), render reuse \(usage.renderReuse), render mixed \(usage.renderMixed), differential positions \(usage.differentialPositions), extended precision \(usage.extendedPrecision) (bad ext elements \(usage.extendedElementBad)), distance \(usage.distanceSpecified), screen ref \(usage.screenRef), non-zero size \(usage.nonZeroSize), zone constraints \(usage.zoneConstraints), snap \(usage.snap), inactive object-blocks \(usage.inactiveObjectBlocks), additional table data \(usage.additionalTableData), reserved codes \(usage.reservedSampleOffset + usage.reservedSizeIdx)")
        s.append("== Output")
        s.append("AtmosFrames \(frames.count), dynamic object samples \(dynamicSamples)")
        s.append("dynamic ranges: x [\(f(minX)), \(f(maxX))]  y [\(f(minY)), \(f(maxY))]  z [\(f(minZ)), \(f(maxZ))]  gain dB [\(f(minGainDB, 1)), \(f(maxGainDB, 1))]  size [\(f(minSize)), \(f(maxSize))]")
        s.append("coords: x 0 left -> 1 right, y 0 front -> 1 back, z 0 ear-level plane -> 1 ceiling (spec floor = -1)")
        return s.joined(separator: "\n")
    }
}
