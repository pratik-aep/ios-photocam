import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func save(_ image: CGImage, _ path: String) {
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil); precondition(CGImageDestinationFinalize(destination))
}
let icon = CGContext(data:nil,width:1024,height:1024,bitsPerComponent:8,bytesPerRow:4096,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
icon.setFillColor(CGColor(red:0.055,green:0.055,blue:0.055,alpha:1)); icon.fill(CGRect(x:0,y:0,width:1024,height:1024))
icon.setStrokeColor(CGColor(red:224/255,green:137/255,blue:58/255,alpha:1)); icon.setLineWidth(18)
icon.strokeEllipse(in:CGRect(x:190,y:190,width:644,height:644)); icon.strokeEllipse(in:CGRect(x:335,y:190,width:354,height:644))
icon.strokeEllipse(in:CGRect(x:190,y:335,width:644,height:354))
icon.setFillColor(CGColor(gray:1,alpha:1)); icon.fillEllipse(in:CGRect(x:477,y:477,width:70,height:70))
save(icon.makeImage()!,"Sources/MIRASCapture/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let w = 2048, h = 1024
var pixels = [UInt8](repeating:255,count:w*h*4)
for y in 0..<h { for x in 0..<w {
    let yaw = (Double(x)+0.5)/Double(w)*2 * .pi - .pi, pitch = .pi/2-(Double(y)+0.5)/Double(h) * .pi
    let dx = sin(yaw)*cos(pitch), dy = sin(pitch), dz = -cos(yaw)*cos(pitch)
    let grid = max(exp(-pow(abs(sin(yaw*6))/0.04,2)),exp(-pow(abs(sin(pitch*6))/0.04,2)))
    let ripple = 0.025*sin(yaw*17)*cos(pitch*9)
    let c = [(0.43+0.18*dx+0.09*dy)*(1-0.45*grid)+ripple,(0.43+0.16*dz+0.08*dx)*(1-0.45*grid)+ripple,(0.43+0.17*dy+0.07*dz)*(1-0.45*grid)+ripple]
    for k in 0..<3 { pixels[(y*w+x)*4+k] = UInt8(min(255,max(0,Int(c[k]*255)))) }
} }
pixels.withUnsafeMutableBytes { ptr in
    let ctx = CGContext(data:ptr.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx,flipped:false)
    for pitch in stride(from:-60,through:60,by:30) { for yaw in stride(from:-150,through:150,by:30) {
        let text = "\(yaw)° / \(pitch)°" as NSString
        let x = Double(w)*(0.5+Double(yaw)/360)+8, y = Double(h)*(0.5+Double(pitch)/180)+8
        text.draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:16,weight:.medium),.foregroundColor:NSColor.white])
    } }
    NSGraphicsContext.restoreGraphicsState()
    save(ctx.makeImage()!,"Sources/MIRASCapture/Resources/MIRAS_VR_Test_Panorama.png")
}
