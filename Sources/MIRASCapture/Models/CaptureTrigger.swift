import Foundation
import Geometry

// Shared with the Mac test harness so capture timing can be checked without AR hardware.
struct CaptureTrigger {
    private var disarmed = Set<Int>()
    private var candidate: (id: Int, retake: Bool, since: Double)?
    private(set) var isRetaking = false

    mutating func reset() { disarmed.removeAll(); clearTimer() }
    private mutating func clearTimer() { candidate = nil; isRetaking = false }

    mutating func update(angle: SphericalAngle, targets: [ShotTarget], completed: Set<Int>,
                         timestamp: Double, normal: Bool, velocity: Double, busy: Bool, active: Bool) -> ShotTarget? {
        for target in targets where angle.distance(to: target.angle) > 5 { disarmed.remove(target.id) }
        guard active, !busy, normal, timestamp.isFinite, velocity.isFinite, velocity < 6 else {
            clearTimer(); return nil
        }
        let retake = targets.first { completed.contains($0.id) && !disarmed.contains($0.id) && angle.distance(to: $0.angle) < 2.5 }
        let next = targets.filter { !completed.contains($0.id) }.min { angle.distance(to: $0.angle) < angle.distance(to: $1.angle) }
        guard let target = retake ?? next, angle.distance(to: target.angle) < 2.5 else { clearTimer(); return nil }
        isRetaking = retake != nil
        if candidate?.id != target.id || candidate?.retake != isRetaking || timestamp < (candidate?.since ?? timestamp) {
            candidate = (target.id, isRetaking, timestamp)
        }
        let duration = isRetaking || completed.isEmpty ? 1.0 : 0.3
        guard timestamp - (candidate?.since ?? timestamp) >= duration else { return nil }
        disarmed.insert(target.id); clearTimer()
        return target
    }
}
