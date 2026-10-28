import XCTest
@testable import Geometry
final class GeometryTests: XCTestCase {
    func testConversions() {
        for yaw in stride(from: -720.0, through: 720, by: 15) {
            for pitch in stride(from: -90.0, through: 90, by: 15) {
                let a = SphericalAngle(yaw: yaw, pitch: pitch), b = SphericalAngle(vector: a.vector), uv = a.uv
                XCTAssertLessThan(a.distance(to: b), 0.00001)
                XCTAssertLessThan(a.distance(to: SphericalAngle(u: uv.u, v: uv.v)), 0.00001)
                let pixel = a.pixel(width: 2048, height: 1024)
                XCTAssertLessThan(a.distance(to: SphericalAngle(u: pixel.x/2048, v: pixel.y/1024)), 0.00001)
            }
        }
    }
    func testWrapPolesAndNorth() {
        XCTAssertEqual(SphericalAngle(u: 0, v: 0.5).vector.x, SphericalAngle(u: 1, v: 0.5).vector.x, accuracy: 1e-10)
        XCTAssertEqual(SphericalAngle(yaw: 99, pitch: 90).uv.v, 0)
        XCTAssertEqual(SphericalAngle(yaw: 99, pitch: -90).uv.v, 1)
        XCTAssertEqual(Geometry.northReference(firstWorldYaw: 80, heading: 30, accuracy: 10), 50)
        XCTAssertEqual(Geometry.northReference(firstWorldYaw: 80, heading: 30, accuracy: 20), 80)
        XCTAssertEqual(Geometry.northReference(firstWorldYaw: 80, heading: nil, accuracy: nil), 80)
        for (heading, accuracy) in [(30.0, -1.0), (360, 1), (Double.infinity, 1), (30, Double.nan)] {
            XCTAssertFalse(Geometry.hasReliableHeading(heading, accuracy: accuracy))
            XCTAssertEqual(Geometry.northReference(firstWorldYaw: 80, heading: heading, accuracy: accuracy), 80)
        }
    }
    func testPlannerCoverage10000Directions() {
        let plan = ShotPlanner.plan(horizontalFOV: 77, verticalFOV: 63)
        for i in 0..<10_000 {
            let y = 1-2*(Double(i)+0.5)/10_000
            let direction = SphericalAngle(yaw: Double(i)*137.507764, pitch: asin(y)*180 / .pi)
            XCTAssertTrue(plan.contains { ShotPlanner.covers(direction, target: $0.angle, horizontalFOV: 77*0.92, verticalFOV: 63*0.92) }, "Uncovered: \(direction)")
        }
    }
    func testTapRay() {
        let look = SphericalAngle(yaw: 355, pitch: 22)
        XCTAssertLessThan(look.distance(to: Geometry.tapRay(x: 200, y: 400, width: 400, height: 800, verticalFOV: 70, look: look)), 0.00001)
        XCTAssertGreaterThan(Geometry.tapRay(x: 200, y: 0, width: 400, height: 800, verticalFOV: 70, look: .init(yaw: 0, pitch: 0)).pitch, 0)
    }
}
