import Foundation
import Observation
import ARKit
import Geometry
import UIKit

@MainActor @Observable final class CaptureViewModel {
    let service = CaptureService()
    let heading = HeadingService()
    var document = CaptureDocument()
    var sample: CameraSample?
    var angle = SphericalAngle(yaw: 0, pitch: 0)
    var target: ShotTarget?
    var error: String?
    var coaching = "Point at a textured area to begin"
    var alignment = 0.0
    var busy = false
    var flash = false
    var started = false
    private var trigger = CaptureTrigger()
    private var sessionID = UUID()
    var completed: Set<Int> { Set(document.frames.map(\.index)) }
    var canFinish: Bool { !document.frames.isEmpty && document.targets.filter { abs($0.angle.pitch) < 89 }.allSatisfy { completed.contains($0.id) } }
    func start() async {
        guard !started else { return }; started = true
        let requestID = UUID(); sessionID = requestID
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard started, sessionID == requestID else { return }
        guard granted else { error = "Camera access is off. Enable Camera in Settings, then retry."; started = false; return }
        heading.request()
        service.onSample = { [weak self] sample in self?.update(sample) }
        do { try service.start() } catch { stop(); self.error = error.localizedDescription }
    }
    private func update(_ s: CameraSample) {
        guard started else { return }
        sample = s
        if document.targets.isEmpty {
            let hfov = 2*atan(Double(s.resolution.width)/Double(2*s.intrinsics[0][0]))*180 / .pi
            let vfov = 2*atan(Double(s.resolution.height)/Double(2*s.intrinsics[1][1]))*180 / .pi
            document.targets = ShotPlanner.plan(horizontalFOV: hfov, verticalFOV: vfov)
            document.referenceWorldYaw = Geometry.northReference(firstWorldYaw: s.angle.yaw, heading: heading.heading?.degrees, accuracy: heading.heading?.accuracy)
        }
        if document.frames.isEmpty && !busy {
            document.referenceWorldYaw = Geometry.northReference(firstWorldYaw: s.angle.yaw, heading: heading.heading?.degrees, accuracy: heading.heading?.accuracy)
        }
        angle = .init(yaw: s.angle.yaw-document.referenceWorldYaw, pitch: s.angle.pitch)
        let remaining = document.targets.filter { !completed.contains($0.id) }
        target = remaining.min { angle.distance(to: $0.angle) < angle.distance(to: $1.angle) }
        let distance = target.map { angle.distance(to: $0.angle) } ?? 180
        alignment = max(0, 1-distance/12)
        coaching = !s.normal ? "Tracking lost, point at a textured area" : s.dark ? "Too dark" : s.translation > 0.08 ? "Turn around the phone, not your body" : s.velocity >= 6 ? "Hold still" : "Follow the dots"
        let shot = trigger.update(angle: angle, targets: document.targets, completed: completed,
                                  timestamp: s.timestamp, normal: s.normal, velocity: s.velocity, busy: busy, active: started)
        if trigger.isRetaking { coaching = "Hold for 1 second to retake" }
        if let shot { take(shot) }
    }
    private func take(_ target: ShotTarget) {
        guard started, !busy else { return }
        busy = true
        Task {
            do {
                let (record, data, fallback) = try await service.capture(index: target.id, target: target.angle)
                if document.frames.isEmpty {
                    let t = record.transform
                    let worldYaw = atan2(Double(-t[8]),Double(t[10]))*180 / .pi
                    document.heading = heading.heading; document.location = heading.location; document.place = heading.place
                    document.referenceWorldYaw = Geometry.northReference(firstWorldYaw: worldYaw, heading: heading.heading?.degrees, accuracy: heading.heading?.accuracy)
                    document.yawReference = Geometry.hasReliableHeading(heading.heading?.degrees, accuracy: heading.heading?.accuracy) ? "trueNorth" : "firstShot"
                    if started {
                        do { try service.lockCamera() } catch { document.warnings.append("Camera lock failed: \(error.localizedDescription)") }
                    }
                }
                try await CaptureStore.shared.writeFrame(data, record: record, capture: document.id)
                document.frames.removeAll { $0.index == record.index }; document.frames.append(record)
                if fallback && !document.warnings.contains("High-resolution capture unavailable; used AR video frames.") { document.warnings.append("High-resolution capture unavailable; used AR video frames.") }
                try await CaptureStore.shared.save(document)
                guard started else { busy = false; return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred(); flash = true
                try? await Task.sleep(for: .milliseconds(120)); flash = false
                try? await Task.sleep(for: .milliseconds(1000))
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    func undo() {
        guard !busy, !document.frames.isEmpty else { return }; document.frames.removeLast()
        Task { do { try await CaptureStore.shared.save(document) } catch { self.error = error.localizedDescription } }
    }
    func stop() {
        started = false; sessionID = UUID(); trigger.reset(); flash = false
        service.onSample = nil; service.stop(); heading.stop()
    }
}
