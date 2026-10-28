import Foundation

public struct RasterImage: Sendable {
    public var width: Int; public var height: Int; public var rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) { self.width = width; self.height = height; self.rgba = rgba }
    public func sample(x: Float, y: Float) -> SIMD3<Float> {
        let ix = min(width-2, max(0, Int(x))), iy = min(height-2, max(0, Int(y)))
        let dx = min(1, max(0, x-Float(ix))), dy = min(1, max(0, y-Float(iy)))
        func rgb(_ i: Int) -> SIMD3<Float> { .init(Float(rgba[i]), Float(rgba[i+1]), Float(rgba[i+2])) / 255 }
        let i = (iy*width+ix)*4
        return (rgb(i)*(1-dx)+rgb(i+4)*dx)*(1-dy) + (rgb(i+width*4)*(1-dx)+rgb(i+width*4+4)*dx)*dy
    }
}
public struct Projection: Sendable {
    // Each camera axis in panorama coordinates; w holds fx, fy and photometric gain.
    public var x: SIMD4<Float>; public var y: SIMD4<Float>; public var z: SIMD4<Float>
    public var meta: SIMD4<Float> // cx, cy, width, height
    public var info: SIMD4<UInt32> // pixel offset into packed GPU buffer
    public init(x: SIMD4<Float>, y: SIMD4<Float>, z: SIMD4<Float>, meta: SIMD4<Float>, info: SIMD4<UInt32> = .zero) { self.x = x; self.y = y; self.z = z; self.meta = meta; self.info = info }
    public static func virtual(angle: SphericalAngle, width: Int, height: Int, verticalFOV: Double, gain: Float = 1) -> Self {
        let a = Float(angle.yaw * .pi/180), p = Float(angle.pitch * .pi/180), f = Float(Double(height)/2/tan(verticalFOV * .pi/360))
        return .init(x: .init(cos(a), 0, sin(a), f), y: .init(-sin(a)*sin(p), cos(p), cos(a)*sin(p), f), z: .init(-sin(a)*cos(p), -sin(p), cos(a)*cos(p), gain), meta: .init(Float(width)/2, Float(height)/2, Float(width), Float(height)))
    }
    public func project(_ d: SIMD3<Float>) -> (Float, Float, Float)? {
        let depth = -(z.x*d.x+z.y*d.y+z.z*d.z)
        guard depth > 0 else { return nil }
        let px = (x.x*d.x+x.y*d.y+x.z*d.z)/depth*x.w+meta.x
        let py = -(y.x*d.x+y.y*d.y+y.z*d.z)/depth*y.w+meta.y
        let edge = min(px/meta.z, 1-px/meta.z, py/meta.w, 1-py/meta.w)
        guard edge > 0.04 else { return nil }
        return (px, py, edge*edge)
    }
    public func direction(x px: Float, y py: Float) -> SIMD3<Float> {
        let rx = (px-meta.x)/x.w, ry = -(py-meta.y)/y.w
        let v = SIMD3(x.x*rx+y.x*ry-z.x, x.y*rx+y.y*ry-z.y, x.z*rx+y.z*ry-z.z)
        return v / sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
    }
}
public struct RasterFrame: Sendable {
    public var image: RasterImage; public var projection: Projection
    public init(image: RasterImage, projection: Projection) { self.image = image; self.projection = projection }
}
public enum Reprojection {
    public static func direction(x: Int, y: Int, width: Int, height: Int) -> SIMD3<Float> {
        let a = (Float(x)+0.5)/Float(width)*2 * .pi - .pi
        let p = .pi/2 - (Float(y)+0.5)/Float(height) * .pi
        return .init(sin(a)*cos(p), sin(p), -cos(a)*cos(p))
    }
    public static func pixel(_ d: SIMD3<Float>, frames: [RasterFrame]) -> SIMD4<Float> {
        var color = SIMD3<Float>.zero, total: Float = 0
        for frame in frames {
            guard let (x, y, w) = frame.projection.project(d) else { continue }
            color += frame.image.sample(x: x, y: y)*frame.projection.z.w*w; total += w
        }
        return total > 0 ? SIMD4(color/total, 1) : .zero
    }
    public static func render(frames: [RasterFrame], width: Int, cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> RasterImage {
        let height = width/2
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        for y in 0..<height {
            if y % 16 == 0 { if cancelled() { throw CancellationError() }; progress(Double(y)/Double(height)) }
            for x in 0..<width {
                let c = pixel(direction(x: x, y: y, width: width, height: height), frames: frames), i = (y*width+x)*4
                bytes[i] = UInt8(clamping: Int(min(1, max(0, c.x))*255)); bytes[i+1] = UInt8(clamping: Int(min(1, max(0, c.y))*255)); bytes[i+2] = UInt8(clamping: Int(min(1, max(0, c.z))*255)); bytes[i+3] = c.w > 0 ? 255 : 0
            }
        }
        progress(1); return .init(width: width, height: height, rgba: bytes)
    }
    public static func compensate(_ input: [RasterFrame]) -> [RasterFrame] {
        guard input.count > 1 else { return input }
        // Pairwise overlap equations: log(g_i) - log(g_j) = log(L_j/L_i).
        var equations: [(Int, Int, Float)] = []
        for i in input.indices { for j in input.indices where j > i {
            var ratios: [Float] = []
            let a = input[i], b = input[j]
            for y in stride(from: 8, to: a.image.height-8, by: max(8, a.image.height/12)) {
                for x in stride(from: 8, to: a.image.width-8, by: max(8, a.image.width/12)) {
                    guard let (bx, by, _) = b.projection.project(a.projection.direction(x: Float(x), y: Float(y))) else { continue }
                    let ca = a.image.sample(x: Float(x), y: Float(y)), cb = b.image.sample(x: bx, y: by)
                    let la = ca.x*0.2126+ca.y*0.7152+ca.z*0.0722, lb = cb.x*0.2126+cb.y*0.7152+cb.z*0.0722
                    if la > 0.04, lb > 0.04, la < 0.92, lb < 0.92 { ratios.append(log(lb/la)) }
                }
            }
            if ratios.count >= 3 { ratios.sort(); equations.append((i, j, ratios[ratios.count/2])) }
        } }
        var gains = [Float](repeating: 0, count: input.count)
        for _ in 0..<100 {
            var next = gains
            for i in input.indices {
                var sum: Float = 0, count: Float = 0
                for (a, b, ratio) in equations { if i == a { sum += gains[b]+ratio; count += 1 }; if i == b { sum += gains[a]-ratio; count += 1 } }
                if count > 0 { next[i] = (gains[i]+sum/count)*0.5 }
            }
            let mean = next.reduce(0, +)/Float(next.count); gains = next.map { $0-mean }
        }
        return input.enumerated().map { i, f in var result = f; result.projection.z.w = min(2, max(0.5, exp(gains[i]))); return result }
    }
}
