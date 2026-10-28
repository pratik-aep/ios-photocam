import Foundation
import Metal
import Geometry
import Accelerate
import CoreText

struct StitchResult: Sendable { var image: RasterImage; var coverage: Double; var usedMetal: Bool }
actor StitchService {
    func stitch(_ capture: CaptureDocument, cpu: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws -> StitchResult {
        try Task.checkCancellation()
        try validateWidth(capture.settings.width)
        var frames: [RasterFrame] = []
        guard !capture.frames.isEmpty else { throw CaptureError.message("No captured frames. Capture the dots before stitching.") }
        guard capture.referenceWorldYaw.isFinite else { throw CaptureError.message("Invalid capture orientation. Capture this scene again.") }
        for (i, frame) in capture.frames.enumerated() {
            try Task.checkCancellation()
            guard frame.transform.count == 16, frame.intrinsics.count == 9,
                  frame.transform.allSatisfy(\.isFinite), frame.intrinsics.allSatisfy(\.isFinite),
                  frame.width > 1, frame.height > 1,
                  frame.intrinsics[0] > 0, frame.intrinsics[4] > 0 else {
                throw CaptureError.message("Camera data for frame \(frame.index) is damaged. Retake this capture.")
            }
            let url = CaptureStore.folder(capture.id).appending(path: "frames/\(frame.file)")
            let image = try ImageCodec.decode(url, maxSize: 1280)
            let sx = Float(image.width)/Float(frame.width), sy = Float(image.height)/Float(frame.height)
            let a = Float(-capture.referenceWorldYaw * .pi/180)
            func axis(_ index: Int, _ w: Float) -> SIMD4<Float> {
                let x = frame.transform[index*4], y = frame.transform[index*4+1], z = frame.transform[index*4+2]
                return .init(cos(a)*x-sin(a)*z, y, sin(a)*x+cos(a)*z, w)
            }
            let p = Projection(x: axis(0, frame.intrinsics[0]*sx), y: axis(1, frame.intrinsics[4]*sy), z: axis(2, 1), meta: .init(frame.intrinsics[6]*sx, frame.intrinsics[7]*sy, Float(image.width), Float(image.height)))
            frames.append(.init(image: image, projection: p)); progress(Double(i+1)/Double(capture.frames.count)*0.08)
        }
        frames = Reprojection.compensate(frames)
        if capture.settings.refinement { frames = refine(frames) }
        progress(0.12)
        return try await render(frames: frames, width: capture.settings.width, cpu: cpu, nadirCap: capture.settings.nadirCap, progress: progress)
    }
    func render(frames: [RasterFrame], width: Int, cpu: Bool, nadirCap: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws -> StitchResult {
        try Task.checkCancellation()
        try validateWidth(width)
        guard !frames.isEmpty else { throw CaptureError.message("No captured frames. Capture the dots before stitching.") }
        for frame in frames {
            let image = frame.image, p = frame.projection
            guard (2...16384).contains(image.width), (2...16384).contains(image.height),
                  image.rgba.count == image.width*image.height*4,
                  [p.x, p.y, p.z, p.meta].allSatisfy({ v in (0..<4).allSatisfy { v[$0].isFinite } }),
                  p.x.w > 0, p.y.w > 0, p.z.w > 0,
                  p.meta.z == Float(image.width), p.meta.w == Float(image.height) else {
                throw CaptureError.message("Invalid image or camera projection. Retake this capture.")
            }
        }
        var raster: RasterImage
        var metal = false
        if !cpu, let gpu = try? await metalRender(frames: frames, width: width, progress: progress) { raster = gpu; metal = true }
        else { raster = try Reprojection.render(frames: frames, width: width, cancelled: { Task.isCancelled }, progress: { progress(0.12+$0*0.8) }) }
        try Task.checkCancellation()
        var valid = 0, count = 0
        for y in 0..<raster.height where Double(y)/Double(raster.height) < 0.9444 {
            for x in 0..<raster.width { count += 1; if raster.rgba[(y*raster.width+x)*4+3] > 0 { valid += 1 } }
        }
        guard valid > 0 else { throw CaptureError.message("No panorama coverage. Check the captured frames and retry.") }
        fillHoles(&raster)
        if nadirCap { applyCap(&raster) }
        progress(1)
        return .init(image: raster, coverage: Double(valid)/Double(max(1,count)), usedMetal: metal)
    }
    private func validateWidth(_ width: Int) throws {
        guard (4...6144).contains(width), width.isMultiple(of: 2) else {
            throw CaptureError.message("Panorama width must be an even number between 4 and 6144 pixels.")
        }
    }
    private func shaderLibrary(_ device: MTLDevice) async throws -> MTLLibrary? {
        #if SWIFT_PACKAGE
        guard let url = Bundle.module.url(forResource: "Stitch", withExtension: "metal", subdirectory: "Shaders") else { return nil }
        return try await device.makeLibrary(source: String(contentsOf: url), options: nil)
        #else
        return device.makeDefaultLibrary()
        #endif
    }
    private func metalRender(frames: [RasterFrame], width: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> RasterImage {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let library = try await shaderLibrary(device), let function = library.makeFunction(name: "stitch") else { throw CaptureError.message("Metal unavailable; using CPU.") }
        let pipeline = try await device.makeComputePipelineState(function: function)
        var packed: [UInt8] = [], projections: [Projection] = []
        for frame in frames {
            var p = frame.projection; p.info.x = UInt32(packed.count/4); projections.append(p); packed.append(contentsOf: frame.image.rgba)
        }
        let height = width/2, size = width*height*4
        guard let input = device.makeBuffer(bytes: packed, length: packed.count, options: .storageModeShared), let poses = device.makeBuffer(bytes: projections, length: projections.count*MemoryLayout<Projection>.stride, options: .storageModeShared), let output = device.makeBuffer(length: size, options: .storageModeShared) else { throw CaptureError.message("Metal allocation failed; using CPU.") }
        // Small row batches allow progress and cancellation between GPU submissions.
        for row in stride(from: 0, to: height, by: 64) {
            try Task.checkCancellation()
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw CaptureError.message("Could not submit GPU work.") }
            var params = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(frames.count), UInt32(row))
            encoder.setComputePipelineState(pipeline); encoder.setBuffer(input, offset: 0, index: 0); encoder.setBuffer(poses, offset: 0, index: 1); encoder.setBuffer(output, offset: 0, index: 2)
            encoder.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 3)
            encoder.dispatchThreads(.init(width: width, height: min(64, height-row), depth: 1), threadsPerThreadgroup: .init(width: 16, height: 8, depth: 1)); encoder.endEncoding()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                command.addCompletedHandler { buffer in if let error = buffer.error { continuation.resume(throwing: error) } else { continuation.resume() } }; command.commit()
            }
            progress(0.12+0.8*Double(min(row+64,height))/Double(height))
        }
        return .init(width: width, height: height, rgba: Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: UInt8.self), count: size)))
    }
    private func refine(_ frames: [RasterFrame]) -> [RasterFrame] {
        // Bounded coordinate search of normalized cross correlation against the other poses.
        var result = frames
        for i in frames.indices {
            if Task.isCancelled { break }
            let base = frames[i].projection
            var best = base, bestScore: Float = -2
            let others = Array(frames.enumerated().filter { $0.offset != i }.map(\.element))
            for dy in [-1.5, -0.75, 0, 0.75, 1.5] { for dp in [-0.75, 0, 0.75] {
                var candidate = base
                let yaw = Float(dy * .pi/180), pitch = Float(dp * .pi/180)
                func rotate(_ v: SIMD4<Float>) -> SIMD4<Float> {
                    let y = cos(pitch)*v.y-sin(pitch)*v.z, z = sin(pitch)*v.y+cos(pitch)*v.z
                    return .init(cos(yaw)*v.x-sin(yaw)*z, y, sin(yaw)*v.x+cos(yaw)*z, v.w)
                }
                candidate.x = rotate(base.x); candidate.y = rotate(base.y); candidate.z = rotate(base.z)
                var a: [Float] = [], b: [Float] = []
                for y in stride(from: 12, to: frames[i].image.height-12, by: max(12, frames[i].image.height/12)) {
                    for x in stride(from: 12, to: frames[i].image.width-12, by: max(12, frames[i].image.width/12)) {
                        let c = Reprojection.pixel(candidate.direction(x: Float(x), y: Float(y)), frames: others)
                        if c.w > 0 { let own = frames[i].image.sample(x: Float(x), y: Float(y)); a.append((own.x+own.y+own.z)/3); b.append((c.x+c.y+c.z)/3) }
                    }
                }
                guard a.count > 12 else { continue }
                let ma = a.reduce(0,+)/Float(a.count), mb = b.reduce(0,+)/Float(b.count)
                var cross: Float = 0, va: Float = 0, vb: Float = 0
                for k in a.indices { let x = a[k]-ma, y = b[k]-mb; cross += x*y; va += x*x; vb += y*y }
                let score = cross/sqrt(max(1e-8,va*vb))
                if score > bestScore { bestScore = score; best = candidate }
            } }
            result[i].projection = best
        }
        return result
    }
    private func fillHoles(_ image: inout RasterImage) {
        // Multi-source spherical flood fill followed by a box blur only inside uncovered regions.
        let w = image.width, h = image.height
        var frontier: [Int] = [], mask = [Bool](repeating: false, count: w*h)
        for i in 0..<w*h where image.rgba[i*4+3] == 0 { mask[i] = true }
        for i in 0..<w*h where !mask[i] {
            let x = i%w, y = i/w
            if mask[y*w+(x+1)%w] || mask[y*w+(x+w-1)%w] || (y > 0 && mask[i-w]) || (y+1<h && mask[i+w]) { frontier.append(i) }
        }
        var cursor = 0
        while cursor < frontier.count {
            let i = frontier[cursor]; cursor += 1; let x = i%w, y = i/w
            let adjacent = [y*w+(x+1)%w, y*w+(x+w-1)%w, max(0,y-1)*w+x, min(h-1,y+1)*w+x]
            for j in adjacent where image.rgba[j*4+3] == 0 {
                for c in 0..<3 { image.rgba[j*4+c] = image.rgba[i*4+c] }; image.rgba[j*4+3] = 255; frontier.append(j)
            }
        }
        // vImage supplies a soft nearest-neighbor fill across the nadir without changing covered pixels.
        var blurred = image.rgba
        image.rgba.withUnsafeMutableBytes { source in blurred.withUnsafeMutableBytes { destination in
            var src = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w*4)
            var dst = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w*4)
            _ = vImageBoxConvolve_ARGB8888(&src, &dst, nil, 0, 0, 31, 31, nil, vImage_Flags(kvImageEdgeExtend))
        } }
        for i in 0..<w*h where mask[i] { for c in 0..<4 { image.rgba[i*4+c] = blurred[i*4+c] } }
    }
    private func applyCap(_ image: inout RasterImage) {
        let size = 512
        var bytes = [UInt8](repeating:255,count:size*size*4)
        bytes.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data:ptr.baseAddress,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(red:224/255,green:137/255,blue:58/255,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:size,height:size))
            ctx.setStrokeColor(CGColor(gray:0.12,alpha:0.7)); ctx.setLineWidth(4); ctx.strokeEllipse(in:CGRect(x:34,y:34,width:444,height:444))
            let attributes: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("HelveticaNeue-Medium" as CFString,64,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0.07,alpha:1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:"MIRAS",attributes:attributes))
            let width = CTLineGetTypographicBounds(line,nil,nil,nil); ctx.textPosition = CGPoint(x:(512-width)/2,y:232); CTLineDraw(line,ctx)
        }
        let logo = RasterImage(width:size,height:size,rgba:bytes)
        for y in Int(Double(image.height)*0.9444)..<image.height { for x in 0..<image.width {
            let yaw = Float(x)/Float(image.width)*2 * .pi - .pi
            let r = Float(image.height-y)/Float(image.height)*18
            let color = logo.sample(x:256+sin(yaw)*r*250,y:256+cos(yaw)*r*250)
            let i = (y*image.width+x)*4
            image.rgba[i] = UInt8(clamping:Int(color.x*255)); image.rgba[i+1] = UInt8(clamping:Int(color.y*255)); image.rgba[i+2] = UInt8(clamping:Int(color.z*255)); image.rgba[i+3] = 255
        } }
    }
}
