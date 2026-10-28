import Foundation

/// Image-based pose refinement. Recorded poses predict where each detail of one frame lands in its neighbours;
/// normalized cross-correlation finds where it actually is, and a robust bundle adjustment, anchored to the
/// recorded (ARKit) poses, corrects every frame's rotation and the shared focal length at once.
public enum Alignment {
    public struct Report: Sendable, CustomStringConvertible {
        public var pairs = 0, matches = 0
        public var rmsBefore = 0.0, rmsAfter = 0.0 // Match residuals in working-image pixels.
        public var focalScale = 1.0 // Estimated correction applied to every frame's recorded focal length.
        public init() {}
        public var description: String { String(format: "%d matches over %d pairs · residual %.2f → %.2f px · focal ×%.4f", matches, pairs, rmsBefore, rmsAfter, focalScale) }
    }
    /// Pose uncertainty assumed for the recorded rotations; frames without matches stay on their recorded pose.
    static let priorDegrees = 1.5
    /// Relative uncertainty of the recorded focal length. One camera with locked focus shares a single scale.
    static let focalPrior = 0.05
    static let patchRadius = 7

    public static func align(_ frames: [RasterFrame], searchDegrees: Float = 2.5, workingSize: Int = 512) -> (frames: [RasterFrame], report: Report) {
        var report = Report()
        guard frames.count > 1 else { return (frames, report) }
        let grays = frames.map { Gray($0.image, maxSize: workingSize) }
        let features = grays.map { corners($0, margin: patchRadius+1) }
        var rotations = frames.map { Rotation($0.projection) }
        var corrections = [SIMD3<Double>](repeating: .zero, count: frames.count)
        var focal = 0.0 // Log of the focal-length correction.
        // A wide first pass absorbs sensor drift; the narrow pass re-matches on corrected warps for sub-pixel accuracy.
        for (round, degrees) in [searchDegrees, min(searchDegrees, 0.75)].enumerated() {
            let current = zip(frames, rotations).map { $0.projection.rotated(to: $1, focalScale: Float(Foundation.exp(focal))) }
            let pairs = overlappingPairs(current)
            var found = [[Match]](repeating: [], count: pairs.count)
            found.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: pairs.count) { k in
                    let (i, j) = pairs[k]
                    out[k] = match(i, j, projections: current, grays: grays, features: features[i], searchDegrees: degrees)
                }
            }
            let matches = found.flatMap { $0 }
            let pixelAngle = zip(grays, current).map { Double($0.scale)/Double($1.x.w) }
            let (before, after) = adjust(&rotations, &corrections, &focal, matches: matches, pixelAngle: pixelAngle)
            if round == 0 { report.rmsBefore = before; report.pairs = pairs.count }
            report.rmsAfter = after; report.matches = matches.count
        }
        report.focalScale = Foundation.exp(focal)
        let output = zip(frames, rotations).map { frame, rotation in
            var f = frame; f.projection = f.projection.rotated(to: rotation, focalScale: Float(report.focalScale)); return f
        }
        return (output, report)
    }

    // MARK: Matching

    /// One scene point seen in frames i and j, as image-plane coordinates (x−cx)/fx, −(y−cy)/fy at match time.
    struct Match { var i: Int; var j: Int; var a: SIMD2<Double>; var b: SIMD2<Double> }

    struct Gray {
        var width: Int, height: Int, scale: Float, v: [Float]
        init(_ image: RasterImage, maxSize: Int) {
            let f = max(1, Int((Float(max(image.width, image.height))/Float(maxSize)).rounded(.up)))
            width = image.width/f; height = image.height/f; scale = Float(f)
            v = [Float](repeating: 0, count: width*height)
            for y in 0..<height { for x in 0..<width {
                var s: Float = 0
                for yy in y*f..<(y+1)*f { for xx in x*f..<(x+1)*f {
                    let i = (yy*image.width+xx)*4
                    s += 0.299*Float(image.rgba[i])+0.587*Float(image.rgba[i+1])+0.114*Float(image.rgba[i+2])
                } }
                v[y*width+x] = s/(Float(f*f)*255)
            } }
        }
        func frame(_ x: Float, _ y: Float) -> (Float, Float) { ((x+0.5)*scale-0.5, (y+0.5)*scale-0.5) }
        func sample(frameX: Float, frameY: Float) -> Float? {
            let x = (frameX+0.5)/scale-0.5, y = (frameY+0.5)/scale-0.5
            // A damaged, near-empty frame must not index outside its pixels.
            guard width >= 2, height >= 2, x >= 0, y >= 0, x <= Float(width-1), y <= Float(height-1) else { return nil }
            let ix = min(width-2, Int(x)), iy = min(height-2, Int(y)), dx = x-Float(ix), dy = y-Float(iy), i = iy*width+ix
            return (v[i]*(1-dx)+v[i+1]*dx)*(1-dy)+(v[i+width]*(1-dx)+v[i+width+1]*dx)*dy
        }
    }

    /// Strongest Shi–Tomasi corner per 32-pixel cell; flat walls and sky produce none.
    static func corners(_ g: Gray, margin: Int, cell: Int = 32, threshold: Float = 0.002) -> [SIMD2<Int>] {
        let w = g.width, h = g.height
        guard w > 2*margin+2, h > 2*margin+2 else { return [] }
        var xx = [Float](repeating: 0, count: w*h), yy = xx, xy = xx
        for y in 1..<h-1 { for x in 1..<w-1 {
            let i = y*w+x, gx = (g.v[i+1]-g.v[i-1])/2, gy = (g.v[i+w]-g.v[i-w])/2
            xx[i] = gx*gx; yy[i] = gy*gy; xy[i] = gx*gy
        } }
        func box(_ a: [Float]) -> [Float] {
            var row = a, out = a
            for y in 0..<h { for x in 3..<w-3 { var s: Float = 0; for k in -3...3 { s += a[y*w+x+k] }; row[y*w+x] = s } }
            for y in 3..<h-3 { for x in 0..<w { var s: Float = 0; for k in -3...3 { s += row[(y+k)*w+x] }; out[y*w+x] = s } }
            return out
        }
        let sxx = box(xx), syy = box(yy), sxy = box(xy)
        var result: [SIMD2<Int>] = []
        for cy in stride(from: margin, to: h-margin, by: cell) { for cx in stride(from: margin, to: w-margin, by: cell) {
            var best: Float = threshold, point: SIMD2<Int>?
            for y in cy..<min(cy+cell, h-margin) { for x in cx..<min(cx+cell, w-margin) {
                let i = y*w+x, a = sxx[i], c = syy[i], b = sxy[i]
                let score = (a+c)/2-sqrt((a-c)*(a-c)/4+b*b)
                if score > best { best = score; point = .init(x, y) }
            } }
            if let point { result.append(point) }
        } }
        return result
    }

    static func overlappingPairs(_ projections: [Projection]) -> [(Int, Int)] {
        func halfDiagonal(_ p: Projection) -> Float { atan(sqrt(p.meta.z*p.meta.z+p.meta.w*p.meta.w)/2/p.x.w) }
        var pairs: [(Int, Int)] = []
        for i in projections.indices { for j in projections.indices where j > i {
            let a = projections[i], b = projections[j]
            let angle = acos(min(1, max(-1, a.z.x*b.z.x+a.z.y*b.z.y+a.z.z*b.z.z)))
            if angle < (halfDiagonal(a)+halfDiagonal(b))*0.95 { pairs.append((i, j)) }
        } }
        return pairs
    }

    /// Matches features of frame i inside frame j, searching around the pose-predicted position.
    static func match(_ i: Int, _ j: Int, projections: [Projection], grays: [Gray], features: [SIMD2<Int>], searchDegrees: Float) -> [Match] {
        let a = projections[i], b = projections[j], ga = grays[i], gb = grays[j], r = patchRadius
        let radius = min(48, max(3, Int((searchDegrees * .pi/180*a.x.w/ga.scale).rounded(.up))))
        let span = radius+r, size = 2*span+1
        // Coarse search uses every other offset and pixel; its patch is normalized separately.
        func normalized(_ step: Int, _ origin: SIMD2<Int>) -> [Float]? {
            var values: [Float] = []
            for v in stride(from: -r, through: r, by: step) { for u in stride(from: -r, through: r, by: step) { values.append(ga.v[(origin.y+v)*ga.width+origin.x+u]) } }
            let mean = values.reduce(0, +)/Float(values.count)
            values = values.map { $0-mean }
            let norm = sqrt(values.reduce(0) { $0+$1*$1 })
            guard norm/sqrt(Float(values.count)) > 0.015 else { return nil }
            return values.map { $0/norm }
        }
        func score(_ patch: [Float], _ window: [Float], _ ox: Int, _ oy: Int, _ step: Int) -> Float {
            var cross: Float = 0, sum: Float = 0, sq: Float = 0, k = 0
            for v in stride(from: -r, through: r, by: step) { for u in stride(from: -r, through: r, by: step) {
                let value = window[(span+oy+v)*size+span+ox+u]
                cross += patch[k]*value; sum += value; sq += value*value; k += 1
            } }
            let variance = sq-sum*sum/Float(k)
            return variance > 1e-6 ? cross/sqrt(variance) : -1
        }
        var result: [Match] = []
        let nearB = features.filter { p in
            let (fx, fy) = ga.frame(Float(p.x), Float(p.y))
            guard let q = b.unclippedProject(a.direction(x: fx, y: fy)) else { return false }
            let m = Float(span+2)*gb.scale
            return q.0 > m && q.1 > m && q.0 < b.meta.z-m && q.1 < b.meta.w-m
        }
        for p in nearB {
            guard let fine = normalized(1, p), let coarse = normalized(2, p) else { continue }
            // Frame j resampled onto frame i's pixel grid through the current poses.
            var window = [Float](repeating: 0, count: size*size), complete = true
            for v in -span...span where complete { for u in -span...span {
                let (fx, fy) = ga.frame(Float(p.x+u), Float(p.y+v))
                guard let q = b.unclippedProject(a.direction(x: fx, y: fy)), let value = gb.sample(frameX: q.0, frameY: q.1) else { complete = false; break }
                window[(v+span)*size+u+span] = value
            } }
            guard complete else { continue }
            var best: (Float, Int, Int) = (-2, 0, 0), second: Float = -2
            var candidates: [(Float, Int, Int)] = []
            for oy in stride(from: -radius, through: radius, by: 2) { for ox in stride(from: -radius, through: radius, by: 2) {
                candidates.append((score(coarse, window, ox, oy, 2), ox, oy))
            } }
            for c in candidates where c.0 > best.0 { best = c }
            for c in candidates where max(abs(c.1-best.1), abs(c.2-best.2)) > 3 { second = max(second, c.0) }
            // Repetitive texture (patterned curtains, tiles) gives competing peaks; such matches are unreliable.
            guard best.0 > 0.6, second < best.0-0.08 else { continue }
            var peak: (Float, Int, Int) = (-2, 0, 0)
            var grid = [Float](repeating: -2, count: 25)
            for dy in -2...2 { for dx in -2...2 {
                let ox = best.1+dx, oy = best.2+dy
                guard abs(ox) <= radius, abs(oy) <= radius else { continue }
                let s = score(fine, window, ox, oy, 1); grid[(dy+2)*5+dx+2] = s
                if s > peak.0 { peak = (s, ox, oy) }
            } }
            guard peak.0 > 0.85, abs(peak.1) < radius, abs(peak.2) < radius else { continue }
            func refine(_ left: Float, _ centre: Float, _ right: Float) -> Float {
                let d = left-2*centre+right; return left > -2 && right > -2 && d < 0 ? min(0.5, max(-0.5, (left-right)/(2*d))) : 0
            }
            let gx = peak.1-best.1+2, gy = peak.2-best.2+2
            let sx = gx > 0 && gx < 4 ? refine(grid[gy*5+gx-1], peak.0, grid[gy*5+gx+1]) : 0
            let sy = gy > 0 && gy < 4 ? refine(grid[(gy-1)*5+gx], peak.0, grid[(gy+1)*5+gx]) : 0
            // The detail at p in frame i appears in frame j where the ray of p + offset lands under the current poses.
            let (ax, ay) = ga.frame(Float(p.x), Float(p.y)), (bx, by) = ga.frame(Float(p.x)+Float(peak.1)+sx, Float(p.y)+Float(peak.2)+sy)
            guard let q = b.unclippedProject(a.direction(x: bx, y: by)) else { continue }
            result.append(.init(i: i, j: j, a: a.plane(ax, ay), b: b.plane(q.0, q.1)))
        }
        return result
    }

    // MARK: Bundle adjustment

    struct Rotation {
        var x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double> // Camera axes in panorama coordinates.
        init(_ p: Projection) {
            x = .init(Double(p.x.x), Double(p.x.y), Double(p.x.z)); y = .init(Double(p.y.x), Double(p.y.y), Double(p.y.z)); z = .init(Double(p.z.x), Double(p.z.y), Double(p.z.z))
        }
        func world(_ l: SIMD3<Double>) -> SIMD3<Double> { x*l.x+y*l.y+z*l.z }
        mutating func rotate(_ w: SIMD3<Double>) { x = exp(w, x); y = exp(w, y); z = exp(w, z) }
    }
    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> { .init(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x) }
    static func exp(_ w: SIMD3<Double>, _ v: SIMD3<Double>) -> SIMD3<Double> {
        let theta = sqrt((w*w).sum())
        guard theta > 1e-12 else { return v+cross(w, v) }
        let k = w/theta
        return v*cos(theta)+cross(k, v)*sin(theta)+k*(k*v).sum()*(1-cos(theta))
    }

    /// Gauss–Newton with Huber weights, a pose prior and one shared log focal-length scale; returns the RMS match
    /// residual (pixels) before and after.
    static func adjust(_ rotations: inout [Rotation], _ corrections: inout [SIMD3<Double>], _ focal: inout Double, matches: [Match], pixelAngle: [Double]) -> (Double, Double) {
        let n = rotations.count, size = 3*n+1, prior = 1/pow(priorDegrees * .pi/180, 2), focalWeight = 1/(focalPrior*focalPrior)
        let start = focal // Matches were measured with this focal scale.
        // Unit camera ray of an image-plane point at the current focal scale, and its derivative by log focal.
        func ray(_ m: SIMD2<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
            let s = Foundation.exp(start-focal), r = SIMD3(m.x*s, m.y*s, -1), length = sqrt((r*r).sum()), unit = r/length
            let dr = SIMD3(-m.x*s, -m.y*s, 0)
            return (unit, (dr-unit*(unit*dr).sum())/length)
        }
        var active = matches
        func residuals(_ list: [Match]) -> [Double] {
            list.map { m in let e = rotations[m.i].world(ray(m.a).0)-rotations[m.j].world(ray(m.b).0); return sqrt((e*e).sum())/pixelAngle[m.i] }
        }
        func rms(_ values: [Double]) -> Double { values.isEmpty ? 0 : sqrt(values.reduce(0) { $0+$1*$1 }/Double(values.count)) }
        let before = rms(residuals(active))
        let axes = [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        for pass in 0..<2 {
            for _ in 0..<8 {
                var hessian = [Double](repeating: 0, count: size*size), gradient = [Double](repeating: 0, count: size)
                for m in active {
                    let (ra, da) = ray(m.a), (rb, db) = ray(m.b)
                    let u = rotations[m.i].world(ra), v = rotations[m.j].world(rb), e = u-v
                    let sigma = pixelAngle[m.i], norm = sqrt((e*e).sum())/sigma
                    let w = (norm <= 1.5 ? 1 : 1.5/norm)/(sigma*sigma)
                    // Jacobian columns: left-multiplied small rotations give eₚ × u for frame i and v × eₚ for
                    // frame j; the last column is the focal scale, shared by every frame.
                    var columns = (0..<3).map { (3*m.i+$0, cross(axes[$0], u)) }
                    columns += (0..<3).map { (3*m.j+$0, cross(v, axes[$0])) }
                    columns.append((3*n, rotations[m.i].world(da)-rotations[m.j].world(db)))
                    for (r, a) in columns { gradient[r] += w*(a*e).sum(); for (c, b) in columns { hessian[r*size+c] += w*(a*b).sum() } }
                }
                for k in 0..<n { for p in 0..<3 { hessian[(3*k+p)*size+3*k+p] += prior; gradient[3*k+p] += prior*corrections[k][p] } }
                hessian[3*n*size+3*n] += focalWeight; gradient[3*n] += focalWeight*focal
                guard let step = solve(hessian, gradient.map { -$0 }, size: size) else { break }
                var largest = abs(step[3*n])
                for k in 0..<n {
                    let w = SIMD3(step[3*k], step[3*k+1], step[3*k+2])
                    rotations[k].rotate(w); corrections[k] += w; largest = max(largest, sqrt((w*w).sum()))
                }
                focal += step[3*n]
                if largest < 1e-7 { break }
            }
            // Parallax and false matches: drop residuals beyond 3 px and solve again.
            if pass == 0 { let r = residuals(active); active = zip(active, r).filter { $0.1 < 3 }.map(\.0) }
        }
        return (before, rms(residuals(active)))
    }

    /// Cholesky solve of a symmetric positive-definite system.
    static func solve(_ a: [Double], _ b: [Double], size n: Int) -> [Double]? {
        var l = [Double](repeating: 0, count: n*n)
        for i in 0..<n { for j in 0...i {
            var s = a[i*n+j]
            for k in 0..<j { s -= l[i*n+k]*l[j*n+k] }
            if i == j { guard s > 0 else { return nil }; l[i*n+i] = sqrt(s) } else { l[i*n+j] = s/l[j*n+j] }
        } }
        var y = b
        for i in 0..<n { for k in 0..<i { y[i] -= l[i*n+k]*y[k] }; y[i] /= l[i*n+i] }
        for i in stride(from: n-1, through: 0, by: -1) { for k in i+1..<n { y[i] -= l[k*n+i]*y[k] }; y[i] /= l[i*n+i] }
        return y
    }
}

extension Projection {
    func unclippedProject(_ d: SIMD3<Float>) -> (Float, Float)? {
        let depth = -(z.x*d.x+z.y*d.y+z.z*d.z)
        guard depth > 1e-4 else { return nil }
        return ((x.x*d.x+x.y*d.y+x.z*d.z)/depth*x.w+meta.x, -(y.x*d.x+y.y*d.y+y.z*d.z)/depth*y.w+meta.y)
    }
    /// Image-plane coordinates of a pixel: the camera ray before normalization is (x, y, −1).
    func plane(_ px: Float, _ py: Float) -> SIMD2<Double> { .init(Double((px-meta.x)/x.w), Double(-(py-meta.y)/y.w)) }
    func rotated(to r: Alignment.Rotation, focalScale: Float = 1) -> Projection {
        var p = self
        p.x = .init(Float(r.x.x), Float(r.x.y), Float(r.x.z), x.w*focalScale); p.y = .init(Float(r.y.x), Float(r.y.y), Float(r.y.z), y.w*focalScale); p.z = .init(Float(r.z.x), Float(r.z.y), Float(r.z.z), z.w)
        return p
    }
}
