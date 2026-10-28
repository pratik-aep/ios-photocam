import XCTest
@testable import Geometry
final class PhotometricTests: XCTestCase {
    /// Mean absolute error after fitting one global per-channel affine map to the reference, so the overall
    /// brightness choice is not counted and only inconsistency between frames (patches, seams) remains.
    private func inconsistency(_ image: RasterImage, _ source: RasterImage) -> Double {
        let w = image.width, h = image.height
        var total = 0.0, count = 0.0
        for c in 0..<3 {
            var pairs: [(Double, Double)] = [], sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for y in 0..<h where abs(90-Double(y)*180/Double(h)) < 80 { for x in 0..<w {
                let o = Double(image.rgba[(y*w+x)*4+c])/255
                let r = Double(source.sample(x: Float(x)*Float(source.width-1)/Float(w-1), y: Float(y)*Float(source.height-1)/Float(h-1))[c])
                pairs.append((o, r)); sx += o; sy += r; sxx += o*o; sxy += o*r
            } }
            let n = Double(pairs.count), a = (n*sxy-sx*sy)/(n*sxx-sx*sx), b = (sy-a*sx)/n
            for (o, r) in pairs { total += abs(a*o+b-r); count += 1 }
        }
        return total/count
    }
    func testCompensationRemovesVeilingGlare() throws {
        let source = try loadTestPanorama()
        let frames = SyntheticFixture.frames(width:480,height:360,source:source,noise:0,veil:0.05)
        let before = inconsistency(try Reprojection.render(frames:frames,width:1024),source)
        let after = inconsistency(try Reprojection.render(frames:Reprojection.compensate(frames),width:1024),source)
        print(String(format:"VEIL: inconsistency %.4f → %.4f",before,after))
        XCTAssertLessThan(after, before*0.35)
    }
    func testCompensationIsStable() throws {
        // A second pass over frames that already agree must change almost nothing.
        let once = Reprojection.compensate(SyntheticFixture.frames(width:320,height:240,source:try loadTestPanorama(),noise:0))
        let twice = Reprojection.compensate(once)
        var change = 0.0, count = 0.0
        for (a, b) in zip(once, twice) { for (p, q) in zip(a.image.rgba, b.image.rgba) { change += abs(Double(p)-Double(q)); count += 1 } }
        XCTAssertLessThan(change/count, 0.5)
        XCTAssertTrue(twice.allSatisfy { $0.projection.z.w == 1 })
    }
}
