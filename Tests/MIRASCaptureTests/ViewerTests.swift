import XCTest
import SceneKit
import Geometry
#if canImport(MIRASCore)
@testable import MIRASCore
#else
@testable import MIRASCapture
#endif

final class ViewerTests: XCTestCase {
    @MainActor func testRenderedTextureMatchesTapRay() throws {
        let w = 512, h = 256
        var bytes = [UInt8](repeating:255,count:w*h*4)
        for y in 0..<h { for x in 0..<w { let i = (y*w+x)*4; bytes[i] = UInt8(Double(x)/Double(w-1)*255); bytes[i+1] = UInt8(Double(y)/Double(h-1)*255); bytes[i+2] = 100 } }
        let texture = try ImageCodec.cgImage(RasterImage(width:w,height:h,rgba:bytes))
        let scene = SCNScene(), mesh = PanoramaMesh.make()
        let material = SCNMaterial(); material.diffuse.contents = texture; material.lightingModel = .constant; material.isDoubleSided = false; material.diffuse.wrapS = .repeat; mesh.firstMaterial = material
        scene.rootNode.addChildNode(SCNNode(geometry:mesh))
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.zNear = 0.01; camera.camera?.fieldOfView = 70; scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil); renderer.scene = scene; renderer.pointOfView = camera
        for look in [SphericalAngle(yaw:90,pitch:30),SphericalAngle(yaw:-90,pitch:-30),SphericalAngle(yaw:0,pitch:0)] {
            camera.eulerAngles = .init(Float(look.pitch * .pi/180),Float(-look.yaw * .pi/180),0)
            let snapshot = renderer.snapshot(atTime:0,with:CGSize(width:80,height:160),antialiasingMode:.none)
            #if os(macOS)
            let cg = try XCTUnwrap(snapshot.cgImage(forProposedRect:nil,context:nil,hints:nil))
            #else
            let cg = try XCTUnwrap(snapshot.cgImage)
            #endif
            let raster = try ImageCodec.raster(cg)
            for point in [(40.0,80.0),(15.0,45.0),(65.0,125.0)] {
            let c = raster.sample(x:Float(point.0),y:Float(point.1))
            let uv = Geometry.tapRay(x:point.0,y:point.1,width:80,height:160,verticalFOV:70,look:look).uv
            XCTAssertEqual(Double(c.x),uv.u,accuracy:0.04,"Yaw texture alignment")
            XCTAssertEqual(Double(c.y),uv.v,accuracy:0.04,"Pitch texture alignment")
            }
        }
    }
}
