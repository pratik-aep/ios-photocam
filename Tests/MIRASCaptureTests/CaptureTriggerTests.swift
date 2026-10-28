import XCTest
import Geometry
#if canImport(MIRASCore)
@testable import MIRASCore
#else
@testable import MIRASCapture
#endif

final class CaptureTriggerTests: XCTestCase {
    private let targets = [ShotTarget(id: 0, angle: .init(yaw: 0, pitch: 0)), ShotTarget(id: 1, angle: .init(yaw: 45, pitch: 0))]

    func testInitialExposureAndLaterSteadiness() {
        var trigger = CaptureTrigger()
        func step(_ time: Double, _ id: Int, _ done: Set<Int>) -> ShotTarget? {
            trigger.update(angle: targets[id].angle, targets: targets, completed: done, timestamp: time, normal: true, velocity: 0, busy: false, active: true)
        }
        XCTAssertNil(step(0, 0, [])); XCTAssertNil(step(0.99, 0, []))
        XCTAssertEqual(step(1, 0, [])?.id, 0)
        XCTAssertNil(step(2, 1, [0])); XCTAssertNil(step(2.29, 1, [0]))
        XCTAssertEqual(step(2.31, 1, [0])?.id, 1)
    }

    func testRetakeRecoversAfterTrackingAndMotionInterruptions() {
        for interruptedByTracking in [true, false] {
            var trigger = CaptureTrigger()
            func step(_ time: Double, normal: Bool = true, velocity: Double = 0) -> ShotTarget? {
                trigger.update(angle: targets[0].angle, targets: targets, completed: [0], timestamp: time, normal: normal, velocity: velocity, busy: false, active: true)
            }
            XCTAssertNil(step(0)); XCTAssertTrue(trigger.isRetaking)
            XCTAssertNil(step(0.8, normal: !interruptedByTracking, velocity: interruptedByTracking ? 0 : 10))
            XCTAssertNil(step(1)); XCTAssertNil(step(1.99))
            XCTAssertEqual(step(2.01)?.id, 0)
            XCTAssertNil(step(4), "Must leave a completed dot before another retake")
        }
    }

    func testRetakeRequiresLeavingAndReturning() {
        var trigger = CaptureTrigger()
        func step(_ time: Double, _ id: Int) -> ShotTarget? {
            trigger.update(angle: targets[id].angle, targets: targets, completed: [0, 1], timestamp: time, normal: true, velocity: 0, busy: false, active: true)
        }
        XCTAssertNil(step(0, 0)); XCTAssertEqual(step(1, 0)?.id, 0)
        XCTAssertNil(step(3, 0))
        XCTAssertNil(step(4, 1))
        XCTAssertNil(step(5, 0)); XCTAssertEqual(step(6, 0)?.id, 0)
    }

    func testBusyAndStoppedCaptureResetTheTimer() {
        for active in [true, false] {
            var trigger = CaptureTrigger()
            func step(_ time: Double, busy: Bool = false, active: Bool = true) -> ShotTarget? {
                trigger.update(angle: targets[1].angle, targets: targets, completed: [0], timestamp: time, normal: true, velocity: 0, busy: busy, active: active)
            }
            XCTAssertNil(step(0))
            XCTAssertNil(step(1, busy: active, active: active))
            XCTAssertNil(step(2)); XCTAssertEqual(step(2.31)?.id, 1)
        }
    }
}
