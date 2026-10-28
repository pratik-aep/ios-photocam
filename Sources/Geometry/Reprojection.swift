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
    public var info: SIMD4<UInt32> // pixel offset, low-pass texel offset, low-pass width and height in packed GPU buffers
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
        return (px, py, edge)
    }
    public func direction(x px: Float, y py: Float) -> SIMD3<Float> {
        let rx = (px-meta.x)/x.w, ry = -(py-meta.y)/y.w
        let v = SIMD3(x.x*rx+y.x*ry-z.x, x.y*rx+y.y*ry-z.y, x.z*rx+y.z*ry-z.z)
        return v / sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
    }
}
/// Block-averaged, lightly smoothed copy of a frame: the low-frequency band for two-band blending.
public struct LowPass: Sendable {
    public static let factor = 8
    public var width: Int; public var height: Int
    public var rgba: [Float] // Four floats per texel so the buffer maps directly onto Metal float4.
    public init(_ image: RasterImage) {
        let f = LowPass.factor, w = (image.width+f-1)/f, h = (image.height+f-1)/f
        width = w; height = h
        var sums = [Float](repeating: 0, count: w*h*4)
        for y in 0..<image.height { let row = y/f*w; for x in 0..<image.width {
            let i = (y*image.width+x)*4, j = (row+x/f)*4
            sums[j] += Float(image.rgba[i]); sums[j+1] += Float(image.rgba[i+1]); sums[j+2] += Float(image.rgba[i+2]); sums[j+3] += 1
        } }
        for j in stride(from: 0, to: sums.count, by: 4) { let n = sums[j+3]*255; sums[j] /= n; sums[j+1] /= n; sums[j+2] /= n; sums[j+3] = 1 }
        // A separable [1 2 1] pass removes block structure before bilinear sampling.
        var horizontal = sums
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            horizontal[(y*w+x)*4+c] = (sums[(y*w+max(0,x-1))*4+c]+2*sums[(y*w+x)*4+c]+sums[(y*w+min(w-1,x+1))*4+c])/4
        } } }
        var smooth = horizontal
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            smooth[(y*w+x)*4+c] = (horizontal[(max(0,y-1)*w+x)*4+c]+2*horizontal[(y*w+x)*4+c]+horizontal[(min(h-1,y+1)*w+x)*4+c])/4
        } } }
        rgba = smooth
    }
    /// Samples at full-resolution frame coordinates.
    public func sample(x: Float, y: Float) -> SIMD3<Float> {
        let f = Float(LowPass.factor)
        let lx = min(Float(width-1), max(0, (x+0.5)/f-0.5)), ly = min(Float(height-1), max(0, (y+0.5)/f-0.5))
        let ix = Int(lx), iy = Int(ly), ix1 = min(width-1, ix+1), iy1 = min(height-1, iy+1), dx = lx-Float(ix), dy = ly-Float(iy)
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> { let i = (y*width+x)*4; return .init(rgba[i], rgba[i+1], rgba[i+2]) }
        return (rgb(ix, iy)*(1-dx)+rgb(ix1, iy)*dx)*(1-dy) + (rgb(ix, iy1)*(1-dx)+rgb(ix1, iy1)*dx)*dy
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
    /// Detail-band seam sharpness: a frame's weight falls by e^-1 per 0.25% of frame width it loses to the best frame.
    public static let seamSharpness: Float = 400
    /// Low-band sharpness: smooth colour hands over within a few percent of frame width, so one frame's veil or a
    /// parallax smear cannot spread across the whole overlap.
    public static let lowSharpness: Float = 60
    /// Two-band blend. Both bands prefer the most central frame: smooth colour with a soft handover, detail with a
    /// seam a few pixels wide, so pose error or parallax cannot leave translucent ghost copies.
    public static func pixel(_ d: SIMD3<Float>, frames: [RasterFrame], lows: [LowPass]) -> SIMD4<Float> {
        var low = SIMD3<Float>.zero, lowTotal: Float = 0, detail = SIMD3<Float>.zero, detailTotal: Float = 0, best: Float = -1
        for (frame, lowPass) in zip(frames, lows) {
            guard let (x, y, e) = frame.projection.project(d) else { continue }
            let gain = frame.projection.z.w, base = lowPass.sample(x: x, y: y)
            // Online softmax over edge distance (the Metal kernel uses the same recurrence). The ramp lets a frame
            // enter the blend from zero weight at its margin.
            if e > best { let s = exp(seamSharpness*(best-e)), sl = exp(lowSharpness*(best-e)); detail *= s; detailTotal *= s; low *= sl; lowTotal *= sl; best = e }
            let ramp = min(1, (e-0.04)*25), w = exp(seamSharpness*(e-best))*ramp, wl = exp(lowSharpness*(e-best))*ramp
            low += base*gain*wl; lowTotal += wl
            detail += (frame.image.sample(x: x, y: y)-base)*gain*w; detailTotal += w
        }
        return lowTotal > 0 ? SIMD4(low/lowTotal+detail/detailTotal, 1) : .zero
    }
    public static func render(frames: [RasterFrame], width: Int, cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> RasterImage {
        try render(frames: frames, lows: frames.map { LowPass($0.image) }, width: width, cancelled: cancelled, progress: progress)
    }
    public static func render(frames: [RasterFrame], lows: [LowPass], width: Int, cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> RasterImage {
        let height = width/2
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        for y in 0..<height {
            if y % 16 == 0 { if cancelled() { throw CancellationError() }; progress(Double(y)/Double(height)) }
            for x in 0..<width {
                let c = pixel(direction(x: x, y: y, width: width, height: height), frames: frames, lows: lows), i = (y*width+x)*4
                bytes[i] = UInt8(clamping: Int(min(1, max(0, c.x))*255)); bytes[i+1] = UInt8(clamping: Int(min(1, max(0, c.y))*255)); bytes[i+2] = UInt8(clamping: Int(min(1, max(0, c.z))*255)); bytes[i+3] = c.w > 0 ? 255 : 0
            }
        }
        progress(1); return .init(width: width, height: height, rgba: bytes)
    }
    static func linear(_ c: Float) -> Float { c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055, 2.4) }
    static func encoded(_ l: Float) -> Float { let c = min(1, max(0, l)); return c <= 0.0031308 ? c*12.92 : 1.055*pow(c, 1/2.4)-0.055 }
    static let linearTable: [Float] = (0..<256).map { linear(Float($0)/255) }

    /// Block-averaged linear-light copy of a frame for photometric sampling; averaging hides residual misalignment.
    struct LinearBlocks {
        static let factor = 8
        var width: Int, height: Int, rgb: [SIMD3<Float>]
        init(_ image: RasterImage) {
            let f = LinearBlocks.factor, w = (image.width+f-1)/f, h = (image.height+f-1)/f
            width = w; height = h
            var sums = [SIMD4<Float>](repeating: .zero, count: w*h)
            for y in 0..<image.height { let row = y/f*w; for x in 0..<image.width {
                let i = (y*image.width+x)*4, t = Reprojection.linearTable
                sums[row+x/f] += SIMD4(t[Int(image.rgba[i])], t[Int(image.rgba[i+1])], t[Int(image.rgba[i+2])], 1)
            } }
            rgb = sums.map { SIMD3($0.x, $0.y, $0.z)/$0.w }
        }
        func at(_ x: Int, _ y: Int) -> SIMD3<Float> { rgb[y*width+x] }
        /// Samples at full-resolution frame coordinates.
        func sample(x: Float, y: Float) -> SIMD3<Float> {
            let f = Float(LinearBlocks.factor)
            let lx = min(Float(width-1), max(0, (x+0.5)/f-0.5)), ly = min(Float(height-1), max(0, (y+0.5)/f-0.5))
            let ix = Int(lx), iy = Int(ly), ix1 = min(width-1, ix+1), iy1 = min(height-1, iy+1), dx = lx-Float(ix), dy = ly-Float(iy)
            return (at(ix, iy)*(1-dx)+at(ix1, iy)*dx)*(1-dy)+(at(ix, iy1)*(1-dx)+at(ix1, iy1)*dx)*dy
        }
        /// False at edges, where any residual misalignment dominates the photometric difference.
        func flat(_ x: Int, _ y: Int) -> Bool {
            func l(_ v: SIMD3<Float>) -> Float { v.x*0.2126+v.y*0.7152+v.z*0.0722 }
            let centre = l(at(x, y)), limit = 0.2*centre+0.01
            return [at(x-1, y), at(x+1, y), at(x, y-1), at(x, y+1)].allSatisfy { abs(l($0)-centre) <= limit }
        }
    }

    public static func compensate(_ input: [RasterFrame]) -> [RasterFrame] { var frames = input; compensate(&frames); return frames }
    /// Photometric alignment in linear light. Every frame gets a per-channel gain and offset so that overlapping
    /// frames agree. The offset absorbs veiling glare (lens flare from bright windows), which a gain alone cannot
    /// model. Corrections are baked into the pixels in place; each projection's gain is left at 1.
    public static func compensate(_ input: inout [RasterFrame]) {
        guard input.count > 1 else { return }
        let n = input.count, blocks = input.map { LinearBlocks($0.image) }
        var pairs: [(i: Int, j: Int, a: [SIMD3<Float>], b: [SIMD3<Float>])] = []
        for (i, j) in Alignment.overlappingPairs(input.map(\.projection)) {
            let pa = input[i].projection, pb = input[j].projection, t = blocks[i]
            var a: [SIMD3<Float>] = [], b: [SIMD3<Float>] = []
            for ty in stride(from: 1, to: t.height-1, by: 2) { for tx in stride(from: 1, to: t.width-1, by: 2) {
                let f = Float(LinearBlocks.factor), x = (Float(tx)+0.5)*f-0.5, y = (Float(ty)+0.5)*f-0.5
                guard min(x/pa.meta.z, 1-x/pa.meta.z, y/pa.meta.w, 1-y/pa.meta.w) > 0.04,
                      let (bx, by, _) = pb.project(pa.direction(x: x, y: y)) else { continue }
                let va = t.at(tx, ty), vb = blocks[j].sample(x: bx, y: by)
                // Clipped highlights carry no photometric information.
                guard max(va.max(), vb.max()) < 0.85, t.flat(tx, ty) else { continue }
                a.append(va); b.append(vb)
            } }
            if a.count >= 8 { pairs.append((i, j, a, b)) }
        }
        // The overlap equations only fix gains and offsets relative to each other, and their noise would shrink a free
        // global scale toward zero, so a stiff penalty holds the mean gain at 1 and the mean offset at 0. Weak per-frame
        // priors keep frames that see a single brightness (a white ceiling) on the gain-only explanation.
        let gainPrior = 1.0, offsetPrior = 25.0, gauge = 1e6
        var gains = [SIMD3<Float>](repeating: .one, count: n), offsets = [SIMD3<Float>](repeating: .zero, count: n)
        for c in 0..<3 {
            var weights = pairs.map { [Double](repeating: 1, count: $0.a.count) }, x = (0..<2*n).map { $0.isMultiple(of: 2) ? 1.0 : 0 }
            for _ in 0..<4 {
                var h = [Double](repeating: 0, count: 4*n*n), rhs = [Double](repeating: 0, count: 2*n)
                func add(_ r: Int, _ k: Int, _ v: Double) { h[r*2*n+k] += v; if r != k { h[k*2*n+r] += v } }
                for (p, pair) in pairs.enumerated() {
                    // Residual αᵢa + βᵢ − αⱼb − βⱼ; normal equations need only these weighted sums.
                    var saa = 0.0, sa = 0.0, sab = 0.0, sb = 0.0, sbb = 0.0, sw = 0.0
                    for k in pair.a.indices {
                        let a = Double(pair.a[k][c]), b = Double(pair.b[k][c]), w = weights[p][k]
                        saa += w*a*a; sa += w*a; sab += w*a*b; sb += w*b; sbb += w*b*b; sw += w
                    }
                    let ai = 2*pair.i, bi = ai+1, aj = 2*pair.j, bj = aj+1
                    add(ai, ai, saa); add(ai, bi, sa); add(ai, aj, -sab); add(ai, bj, -sa)
                    add(bi, bi, sw); add(bi, aj, -sb); add(bi, bj, -sw)
                    add(aj, aj, sbb); add(aj, bj, sb); add(bj, bj, sw)
                }
                for k in 0..<n { h[2*k*2*n+2*k] += gainPrior; rhs[2*k] += gainPrior; h[(2*k+1)*2*n+2*k+1] += offsetPrior }
                for k in 0..<n { rhs[2*k] += gauge*Double(n); for l in 0..<n { h[2*k*2*n+2*l] += gauge; h[(2*k+1)*2*n+2*l+1] += gauge } }
                guard let solution = Alignment.solve(h, rhs, size: 2*n) else { break }
                x = solution
                // Huber reweighting: parallax, moving people and misregistration fall outside 0.02 linear.
                for (p, pair) in pairs.enumerated() { for k in pair.a.indices {
                    let r = x[2*pair.i]*Double(pair.a[k][c])+x[2*pair.i+1]-x[2*pair.j]*Double(pair.b[k][c])-x[2*pair.j+1]
                    weights[p][k] = min(1, 0.02/max(1e-9, abs(r)))
                } }
            }
            for k in 0..<n { gains[k][c] = Float(min(2.5, max(0.4, x[2*k]))); offsets[k][c] = Float(min(0.1, max(-0.1, x[2*k+1]))) }
        }
        for k in 0..<n {
            let tables = (0..<3).map { c in (0..<256).map { v in UInt8(clamping: Int((encoded(gains[k][c]*linearTable[v]+offsets[k][c])*255).rounded())) } }
            input[k].image.rgba.withUnsafeMutableBufferPointer { px in
                for i in stride(from: 0, to: px.count, by: 4) { for c in 0..<3 { px[i+c] = tables[c][Int(px[i+c])] } }
            }
            input[k].projection.z.w = 1
        }
    }
}
