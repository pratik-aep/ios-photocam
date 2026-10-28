import XCTest
import CoreGraphics
import ImageIO
@testable import Geometry
final class SyntheticTests: XCTestCase {
    func testSyntheticStitch2048() throws {
        let sourceURL = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path:"Sources/MIRASCapture/Resources/MIRAS_VR_Test_Panorama.png")
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL,nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource,0,nil))
        var bytes = [UInt8](repeating:0,count:cg.width*cg.height*4)
        try bytes.withUnsafeMutableBytes { ptr in
            let ctx = try XCTUnwrap(CGContext(data:ptr.baseAddress,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
        }
        let source = RasterImage(width:cg.width,height:cg.height,rgba:bytes)
        let frames = Reprojection.compensate(SyntheticFixture.frames(source:source))
        let output = try Reprojection.render(frames: frames, width: 2048)
        let metrics = SyntheticFixture.metrics(output,source:source)
        print("SYNTHETIC 2048: \(metrics)")
        let lows = frames.map { LowPass($0.image) }
        for p in stride(from:-75.0,through:75,by:15) {
            let a = SphericalAngle(yaw:-180,pitch:p).vector, b = SphericalAngle(yaw:180,pitch:p).vector
            let left = Reprojection.pixel(SIMD3(Float(a.x),Float(a.y),Float(a.z)),frames:frames,lows:lows)
            let right = Reprojection.pixel(SIMD3(Float(b.x),Float(b.y),Float(b.z)),frames:frames,lows:lows)
            XCTAssertLessThan(abs(left.x-right.x)+abs(left.y-right.y)+abs(left.z-right.z),0.0001)
        }
        XCTAssertLessThan(metrics.meanAbsoluteError, 0.06)
        XCTAssertLessThanOrEqual(abs(metrics.bestHorizontalShift), 2)
        XCTAssertLessThan(metrics.seamError, 0.02)
        XCTAssertGreaterThanOrEqual(metrics.coverage, 0.98)
    }
}
