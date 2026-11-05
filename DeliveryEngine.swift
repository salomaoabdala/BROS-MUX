// BROS-MUX Beta 2.0.0 — the Delivery engine: the queue, the detached render (--job-file) and its progress.
// Wave 0: the contract's types with the simplest bodies; the Delivery owner (D) writes the real ones.
// START still runs the old in-app mux (Project.run) until then.

import Foundation
import Observation

enum DeliveryState: String, Codable { case queued, running, done, warning, failed, cancelled }

/// The last progress of a running job (progress.json)
struct DeliverySnapshot: Codable, Equatable {
    var stage: JobProgress.Stage?; var title: String; var stageFraction: Double; var overall: Double
    var frame: Int?; var totalFrames: Int?; var fpsAverage: Double?; var bitrateKbps: Double?
    var bytesWritten: Int64?; var bytesTotal: Int64?; var stageIndex: Int; var stageCount: Int
    var stagesDone: [JobProgress.Stage]; var started: Date; var updated: Date
}

struct DeliveryItem: Identifiable {
    let id: UUID; var job: DeliveryJob; var jobFile: URL; var state: DeliveryState
    var snapshot: DeliverySnapshot?; var findings: [String]; var resultLines: [String]; var output: URL?
}

/// One line of "BEFORE YOU START", with the tab that fixes it
struct DeliveryPreflightItem: Identifiable { let id = UUID(); var level: CheckLevel; var text: String; var tab: AppMode? }

@Observable final class DeliveryQueue {
    static let shared = DeliveryQueue()
    var items: [DeliveryItem] = []
    var current: DeliveryItem? { items.first { $0.state == .running } }
    var isRunning: Bool { current != nil }
    var overall: Double? { current?.snapshot?.overall }

    /// What stops (✕) or needs a confirmation (⚠) before START (wave 0: the metadata and HDR problems only)
    func preflight(_ project: Project) -> [DeliveryPreflightItem] {
        var out: [DeliveryPreflightItem] = []
        if let m = project.metadataNotEmbedded { out.append(DeliveryPreflightItem(level: .fail, text: m, tab: .video)) }
        if let p = project.hdrProblem { out.append(DeliveryPreflightItem(level: .fail, text: p, tab: .video)) }
        return out
    }
    /// Wave 0: the old in-app mux (Project.run), not a detached job yet
    func startNow(from project: Project) { project.run() }
    func enqueue(from project: Project) {}
    func enqueueBatch(_ pictures: [URL], template project: Project) {}
    func startQueue() {}
    func cancel(_ id: UUID) {}
    func remove(_ id: UUID) {}
    func saveWithPanel(from project: Project) {}
    func load(_ url: URL, into project: Project) {}
    func restoreAtLaunch() {}
    func loadDemoRunningJob() {}
}

/// --job-file A.bmjob [B.bmjob…] [--dry-run]: the detached render
enum DeliveryCLI {
    static func run(_ args: [String]) -> Int32 {
        print("--job-file: not implemented yet")
        return 2
    }
}
