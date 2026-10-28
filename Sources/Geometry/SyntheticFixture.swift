import Foundation

public struct SyntheticMetrics: Codable, Sendable, CustomStringConvertible {
    public var meanAbsoluteError: Double
    public var bestHorizontalShift: Int
    public var seamError: Double
    public var coverage: Double
    public var description: String { String(format: "MAE %.5f · shift %d px · seam %.5f · coverage %.2f%%", meanAbsoluteError, bestHorizontalShift, seamError, coverage*100) }
}
public enum SyntheticFixture {
    public static func color(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let yaw = atan2(d.x,-d.z), pitch = asin(min(1,max(-1,d.y)))
        var c = SIMD3<Float>(0.43+0.18*d.x+0.09*d.y, 0.43+0.16*d.z+0.08*d.x, 0.43+0.17*d.y+0.07*d.z)
        let yg = abs(sin(yaw*6)), pg = abs(sin(pitch*6))
        let grid = max(exp(-pow(yg/0.04,2)), exp(-pow(pg/0.04,2)))
        c *= 1-0.45*grid
        c += SIMD3(repeating: 0.025*sin(yaw*17)*cos(pitch*9))
        return c
    }
    public static func panorama(width: Int) -> RasterImage {
        let h = width/2; var bytes = [UInt8](repeating: 255, count: width*h*4)
        for y in 0..<h { for x in 0..<width {
            let c = color(Reprojection.direction(x: x, y: y, width: width, height: h)), i = (y*width+x)*4
            bytes[i] = UInt8(c.x*255); bytes[i+1] = UInt8(c.y*255); bytes[i+2] = UInt8(c.z*255)
        } }
        return .init(width: width, height: h, rgba: bytes)
    }
    /// True camera poses behind `frames`.
    public static func poses(width: Int = 1920, height: Int = 1440) -> [Projection] {
        ShotPlanner.plan(horizontalFOV: 2*atan(Double(width)/Double(height)*tan(63 * .pi/360))*180 / .pi, verticalFOV: 63)
            .map { Projection.virtual(angle: $0.angle, width: width, height: height, verticalFOV: 63) }
    }
    /// Frames rendered from the true poses but recorded with deterministic yaw/pitch error up to `noise` and roll error
    /// up to `roll` degrees, and a recorded focal length off by the fraction `focalError`. A positive `veil` adds up to
    /// that much linear-light glare to about half of the frames, as a bright window does.
    public static func frames(width: Int = 1920, height: Int = 1440, source: RasterImage? = nil, noise: Double = 0.5, roll: Double = 0, focalError: Double = 0, veil: Float = 0) -> [RasterFrame] {
        let plan = ShotPlanner.plan(horizontalFOV: 2*atan(Double(width)/Double(height)*tan(63 * .pi/360))*180 / .pi, verticalFOV: 63)
        return plan.enumerated().map { index, target in
            let actual = Projection.virtual(angle: target.angle, width: width, height: height, verticalFOV: 63)
            let noiseYaw = sin(Double(index)*12.9898)*noise, noisePitch = cos(Double(index)*7.832)*noise
            var recorded = Projection.virtual(angle: .init(yaw: target.angle.yaw+noiseYaw, pitch: target.angle.pitch+noisePitch), width: width, height: height, verticalFOV: 63)
            let r = Float(sin(Double(index)*3.71)*roll * .pi/180), x = recorded.x, y = recorded.y, f = Float(1+focalError)
            recorded.x = .init(cos(r)*x.x+sin(r)*y.x, cos(r)*x.y+sin(r)*y.y, cos(r)*x.z+sin(r)*y.z, x.w*f)
            recorded.y = .init(-sin(r)*x.x+cos(r)*y.x, -sin(r)*x.y+cos(r)*y.y, -sin(r)*x.z+cos(r)*y.z, y.w*f)
            let gain = Float(1+0.15*sin(Double(index)*2.39996)), glare = veil*max(0, Float(sin(Double(index)*1.7)))
            var bytes = [UInt8](repeating: 255, count: width*height*4)
            for y in 0..<height { for x in 0..<width {
                let d = actual.direction(x: Float(x), y: Float(y))
                var c: SIMD3<Float>
                if let source {
                    let uv = SphericalAngle(vector: .init(Double(d.x),Double(d.y),Double(d.z))).uv
                    c = source.sample(x: Float(uv.u)*Float(source.width-1), y: Float(uv.v)*Float(source.height-1))*gain
                } else { c = color(d)*gain }
                if glare > 0 { c = SIMD3(Reprojection.encoded(Reprojection.linear(c.x)+glare), Reprojection.encoded(Reprojection.linear(c.y)+glare), Reprojection.encoded(Reprojection.linear(c.z)+glare)) }
                let i = (y*width+x)*4
                bytes[i] = UInt8(clamping: Int(c.x*255)); bytes[i+1] = UInt8(clamping: Int(c.y*255)); bytes[i+2] = UInt8(clamping: Int(c.z*255))
            } }
            return .init(image: .init(width: width, height: height, rgba: bytes), projection: recorded)
        }
    }
    public static func metrics(_ image: RasterImage, source: RasterImage? = nil) -> SyntheticMetrics {
        var error = 0.0, count = 0.0, covered = 0.0, seam = 0.0, seamCount = 0.0
        let w = image.width, h = image.height
        func reference(_ x: Int, _ y: Int) -> SIMD3<Float> {
            if let source { return source.sample(x: Float(x)*Float(source.width-1)/Float(w-1), y: Float(y)*Float(source.height-1)/Float(h-1)) }
            return color(Reprojection.direction(x: x, y: y, width: w, height: h))
        }
        for y in 0..<h where abs(90-Double(y)*180/Double(h)) < 80 {
            for x in 0..<w {
                let c = reference(x,y), i = (y*w+x)*4
                error += Double(abs(Float(image.rgba[i])/255-c.x)+abs(Float(image.rgba[i+1])/255-c.y)+abs(Float(image.rgba[i+2])/255-c.z))/3
                count += 1; if image.rgba[i+3] > 0 { covered += 1 }
            }
            for c in 0..<3 {
                let first = Double(image.rgba[y*w*4+c]), last = Double(image.rgba[(y*w+w-1)*4+c])
                let next = Double(image.rgba[(y*w+1)*4+c]), previous = Double(image.rgba[(y*w+w-2)*4+c])
                // Measure a discontinuity beyond the local image gradient, not legitimate edge contrast.
                seam += max(0, abs(first-last)-(abs(first-next)+abs(last-previous))/2)/255; seamCount += 1
            }
        }
        var bestShift = 0, bestError = Double.infinity
        for shift in -12...12 {
            var e = 0.0
            for y in stride(from: h/10, to: h*9/10, by: 11) { for x in stride(from: 0, to: w, by: 7) {
                let j = (y*w+(x+shift+w)%w)*4, c = reference(x,y)
                e += Double(abs(Float(image.rgba[j])/255-c.x)+abs(Float(image.rgba[j+1])/255-c.y)+abs(Float(image.rgba[j+2])/255-c.z))
            } }
            if e < bestError { bestError = e; bestShift = shift }
        }
        return .init(meanAbsoluteError: error/max(1,count), bestHorizontalShift: bestShift, seamError: seam/max(1,seamCount), coverage: covered/max(1,count))
    }
}
