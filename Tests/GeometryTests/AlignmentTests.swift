import XCTest
@testable import Geometry
final class AlignmentTests: XCTestCase {
    private func source() throws -> RasterImage { try loadTestPanorama() }
    /// Mean angle (degrees) between estimated and true relative rotations of every frame pair; independent of global orientation.
    private func relativeError(_ estimated: [Projection], _ truth: [Projection]) -> Double {
        func axes(_ p: Projection) -> [SIMD3<Double>] { [p.x, p.y, p.z].map { SIMD3(Double($0.x),Double($0.y),Double($0.z)) } }
        // Camera-frame relative rotation RₐᵀR_b: dot products of the two cameras' axes, unchanged by a global rotation.
        func relative(_ a: Projection, _ b: Projection) -> [[Double]] {
            let ra = axes(a), rb = axes(b)
            return (0..<3).map { r in (0..<3).map { c in (ra[r]*rb[c]).sum() } }
        }
        var total = 0.0, count = 0.0
        for i in truth.indices { for j in truth.indices where j > i {
            let e = relative(estimated[i],estimated[j]), t = relative(truth[i],truth[j])
            let trace = (0..<3).reduce(0.0) { s, k in s+(0..<3).reduce(0.0) { $0+e[k][$1]*t[k][$1] } }
            total += acos(min(1,max(-1,(trace-1)/2)))*180 / .pi; count += 1
        } }
        return total/count
    }
    func testAlignmentRecoversPoseError() throws {
        let source = try source()
        let frames = SyntheticFixture.frames(width:960,height:720,source:source,noise:2,roll:1)
        let truth = SyntheticFixture.poses(width:960,height:720)
        let start = Date()
        let (aligned, report) = Alignment.align(frames)
        let seconds = Date().timeIntervalSince(start)
        let before = relativeError(frames.map(\.projection),truth), after = relativeError(aligned.map(\.projection),truth)
        print(String(format:"ALIGNMENT: %@ · pose error %.3f° → %.3f° · %.2fs",report.description,before,after,seconds))
        XCTAssertGreaterThan(report.matches, 10*frames.count)
        XCTAssertLessThan(after, 0.05)
        XCTAssertLessThan(after, before/8)
        let plain = SyntheticFixture.metrics(try Reprojection.render(frames:Reprojection.compensate(frames),width:1024),source:source)
        let fixed = SyntheticFixture.metrics(try Reprojection.render(frames:Reprojection.compensate(aligned),width:1024),source:source)
        print("ALIGNED STITCH: \(plain) → \(fixed)")
        XCTAssertLessThan(fixed.meanAbsoluteError, plain.meanAbsoluteError*0.8)
    }
    func testAlignmentRecoversFocalLength() throws {
        // A 2% intrinsics error misplaces frame edges by several pixels, which rotations alone cannot absorb.
        let frames = SyntheticFixture.frames(width:960,height:720,source:try source(),noise:1,roll:0.5,focalError:0.02)
        let truth = SyntheticFixture.poses(width:960,height:720)
        let (aligned, report) = Alignment.align(frames)
        let focal = Double(aligned[0].projection.x.w/truth[0].x.w), error = relativeError(aligned.map(\.projection),truth)
        print(String(format:"FOCAL: %@ · focal %.4f of true · pose error %.3f°",report.description,focal,error))
        XCTAssertEqual(focal, 1, accuracy: 0.003)
        XCTAssertLessThan(error, 0.05)
        XCTAssertLessThan(report.rmsAfter, 0.3)
    }
    func testAlignmentKeepsAccuratePoses() throws {
        let frames = SyntheticFixture.frames(width:480,height:360,source:try source(),noise:0)
        let truth = SyntheticFixture.poses(width:480,height:360)
        let (aligned, report) = Alignment.align(frames)
        XCTAssertLessThan(relativeError(aligned.map(\.projection),truth), 0.1)
        XCTAssertEqual(report.focalScale, 1, accuracy: 0.002)
    }
    func testTexturelessFramesKeepRecordedPoses() {
        let flat = SyntheticFixture.frames(width:160,height:120).map { f -> RasterFrame in
            var g = f; g.image.rgba = [UInt8](repeating:128,count:f.image.rgba.count); return g
        }
        let (aligned, report) = Alignment.align(flat)
        XCTAssertEqual(report.matches, 0)
        for (a, b) in zip(aligned, flat) { XCTAssertEqual(a.projection.z, b.projection.z) }
    }
}
