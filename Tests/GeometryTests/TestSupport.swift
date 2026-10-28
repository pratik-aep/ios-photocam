import XCTest
import CoreGraphics
import ImageIO
@testable import Geometry

/// The bundled labelled 2:1 test panorama.
func loadTestPanorama() throws -> RasterImage {
    let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path:"Sources/MIRASCapture/Resources/MIRAS_VR_Test_Panorama.png")
    let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
    let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource,0,nil))
    var bytes = [UInt8](repeating:0,count:cg.width*cg.height*4)
    try bytes.withUnsafeMutableBytes { ptr in
        let ctx = try XCTUnwrap(CGContext(data:ptr.baseAddress,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    }
    return RasterImage(width:cg.width,height:cg.height,rgba:bytes)
}
