import Foundation
import Observation
import Geometry
import UIKit

@MainActor @Observable final class LibraryViewModel {
    var captures: [CaptureDocument] = []
    var libraryWarnings: [String] = []
    var error: String?
    var progress: Double?
    var activity = ""
    var metrics: String?
    var selected: CaptureDocument?
    var shareURL: URL?
    var work: Task<Void, Never>?
    let stitcher = StitchService()
    let exporter = ExportService()
    func refresh() async {
        do {
            let library = try await CaptureStore.shared.load()
            captures = library.captures; libraryWarnings = library.warnings
        } catch { self.error = error.localizedDescription }
    }
    func save(_ capture: CaptureDocument) async {
        do { try await CaptureStore.shared.save(capture); await refresh() } catch { self.error = error.localizedDescription }
    }
    func remove(_ capture: CaptureDocument) async {
        do { try await CaptureStore.shared.delete(capture.id); await refresh() } catch { self.error = error.localizedDescription }
    }
    func stitch(_ capture: CaptureDocument) {
        guard work == nil else { return }
        progress = 0; activity = "Stitching panorama"
        work = Task {
            do {
                let result = try await stitcher.stitch(capture) { value in Task { @MainActor in self.progress = value } }
                try Task.checkCancellation()
                var c = capture; c.stitched = true; c.stitchedSettings = c.settings; c.coverage = result.coverage
                // Stitch notes describe the latest stitch only; capture notes are kept.
                let coverageNote = "Incomplete coverage: uncovered areas have a blurred fill.", cpuNote = "Stitched with CPU fallback."
                let detailNote = "Few matching details between photos; alignment relied mostly on motion sensors."
                c.warnings.removeAll { [coverageNote, cpuNote, detailNote].contains($0) }
                if result.coverage < 0.98 { c.warnings.append(coverageNote) }
                if !result.usedMetal { c.warnings.append(cpuNote) }
                if let a = result.alignment, a.matches < 3*c.frames.count { c.warnings.append(detailNote) }
                let url = CaptureStore.folder(c.id).appending(path: "panorama.jpg")
                let image = result.image, poseHeading: Double? = c.yawReference == "trueNorth" ? 0 : nil
                try await Task.detached { try ImageCodec.jpeg(image, heading: poseHeading, to: url) }.value
                try await CaptureStore.shared.save(c); await refresh(); selected = c
                do { try await exporter.saveToPhotos(c) } catch { self.error = "Panorama saved in the app. \(error.localizedDescription)" }
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            progress = nil; work = nil
        }
    }
    func export(_ capture: CaptureDocument) {
        guard work == nil else { return }
        progress = 0; activity = "Preparing MIRAS package"
        work = Task {
            do { shareURL = try await exporter.export(capture, deviceModel: DeviceInfo.model) } catch { self.error = error.localizedDescription }
            progress = nil; work = nil
        }
    }
    func loadSample(runTest: Bool) {
        guard work == nil else { return }
        progress = 0; activity = runTest ? "Running synthetic stitch test" : "Creating sample capture"
        work = Task {
            do {
                let doc = try await Task.detached(priority: .userInitiated) { () throws -> CaptureDocument in
                    var c = CaptureDocument(); c.name = "MIRAS test panorama"; c.settings.width = 2048
                    c.targets = ShotPlanner.plan(horizontalFOV: 77, verticalFOV: 63)
                    try FileManager.default.createDirectory(at: CaptureStore.folder(c.id).appending(path: "frames"), withIntermediateDirectories: true)
                    return c
                }.value
                var c = doc
                let bundled = Bundle.main.url(forResource: "MIRAS_VR_Test_Panorama", withExtension: "png")
                let source = try await Task.detached { try bundled.map { try ImageCodec.decode($0, maxSize: 4096) } }.value
                if runTest {
                    let frames = await Task.detached { Reprojection.compensate(SyntheticFixture.frames(source: source)) }.value
                    let raw = try await stitcher.render(frames: frames, width: 2048, cpu: true) { value in Task { @MainActor in self.progress = value } }
                    let m = await Task.detached { SyntheticFixture.metrics(raw.image, source: source) }.value; metrics = m.description + (m.meanAbsoluteError < 0.06 && abs(m.bestHorizontalShift) <= 2 && m.seamError < 0.02 && m.coverage >= 0.98 ? " · PASS" : " · FAIL")
                    c.coverage = m.coverage
                    try await Task.detached { try ImageCodec.jpeg(raw.image, heading: nil, to: CaptureStore.folder(doc.id).appending(path: "panorama.jpg")) }.value
                } else {
                    let panorama = await Task.detached { source ?? SyntheticFixture.panorama(width: 2048) }.value
                    try await Task.detached { try ImageCodec.jpeg(panorama, heading: nil, to: CaptureStore.folder(doc.id).appending(path: "panorama.jpg")) }.value
                    c.coverage = 1
                }
                c.stitched = true; c.stitchedSettings = c.settings; c.warnings = ["Synthetic sample; no real camera frames."]
                try await CaptureStore.shared.save(c); await refresh(); selected = c
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            progress = nil; work = nil
        }
    }
}
