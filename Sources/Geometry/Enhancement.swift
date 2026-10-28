import Foundation

/// Finishing for the full equirectangular panorama. Neighbourhood operations wrap across the 360° seam.
public enum Enhancement {
    static func luminance(_ px: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int { (77*Int(px[i])+150*Int(px[i+1])+29*Int(px[i+2])) >> 8 }

    /// Linear black/white point from area-weighted luminance percentiles. The stretch is limited so that
    /// scenes that are legitimately dark or bright are not pushed to an artificial range.
    public static func levels(_ image: inout RasterImage, low: Double = 0.003, high: Double = 0.998, maxGain: Double = 1.3) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return }
        var histogram = [Double](repeating: 0, count: 256), total = 0.0
        image.rgba.withUnsafeBufferPointer { px in
            for y in 0..<h {
                let weight = cos((Double(y)+0.5)/Double(h) * .pi - .pi/2) // Equirectangular rows shrink toward the poles.
                for x in 0..<w { histogram[luminance(px, (y*w+x)*4)] += weight }
                total += weight*Double(w)
            }
        }
        func percentile(_ p: Double) -> Double {
            var sum = 0.0
            for (value, count) in histogram.enumerated() { sum += count; if sum >= p*total { return Double(value) } }
            return 255
        }
        var black = min(percentile(low), 24), white = max(percentile(high), 200)
        if 255/(white-black) > maxGain { let excess = (white-black)-255/maxGain; black += excess/2; white -= excess/2 }
        guard black > 0.5 || white < 254.5 else { return }
        let lut = (0..<256).map { UInt8(clamping: Int(((Double($0)-black)*255/(white-black)).rounded())) }
        for i in stride(from: 0, to: image.rgba.count, by: 4) { for c in 0..<3 { image.rgba[i+c] = lut[Int(image.rgba[i+c])] } }
    }

    /// Contrast-limited adaptive histogram equalization (CLAHE). Tile curves come from luminance and are applied
    /// to each channel, which restores local contrast and colour that veiling glare and haze wash out. Each curve
    /// is shifted to keep its tile's mean brightness, and highlights are progressively protected, so white walls
    /// and ceilings stay white instead of being equalized toward grey. Tiles wrap horizontally; `strength` blends
    /// the result with the input.
    public static func localContrast(_ image: inout RasterImage, columns: Int = 16, rows: Int = 8, clip: Float = 1.5, strength: Float = 0.5) {
        let w = image.width, h = image.height
        guard columns >= 2, rows >= 2, w >= columns*8, h >= rows*8, strength > 0 else { return }
        var curves = [Float](repeating: 0, count: columns*rows*256)
        image.rgba.withUnsafeBufferPointer { px in
            for r in 0..<rows { for c in 0..<columns {
                var histogram = [Float](repeating: 0, count: 256)
                let x0 = c*w/columns, x1 = (c+1)*w/columns, y0 = r*h/rows, y1 = (r+1)*h/rows
                for y in y0..<y1 { for x in x0..<x1 { histogram[luminance(px, (y*w+x)*4)] += 1 } }
                let n = Float((x1-x0)*(y1-y0)), limit = max(1, clip*n/256)
                let mean = histogram.enumerated().reduce(Float(0)) { $0+Float($1.offset)*$1.element }/n
                var excess: Float = 0
                for b in 0..<256 where histogram[b] > limit { excess += histogram[b]-limit; histogram[b] = limit }
                // Midpoint CDF keeps a flat histogram mapping to identity.
                var below: Float = 0, curve = [Float](repeating: 0, count: 256)
                for b in 0..<256 { let count = histogram[b]+excess/256; curve[b] = (below+count/2)/n*255; below += count }
                let m = min(254, Int(mean)), t = mean-Float(m), shift = curve[m]*(1-t)+curve[m+1]*t-mean
                for b in 0..<256 { curves[(r*columns+c)*256+b] = curve[b]-shift }
            }}
        }
        // Full effect up to luminance 170, tapering to a quarter at white.
        let protection: [Float] = (0..<256).map { v in
            let t = min(1, max(0, (Float(v)-170)/85)); return strength*(1-0.75*t*t*(3-2*t))
        }
        // Each pixel interpolates the curves of its four nearest tile centres.
        let tileW = Float(w)/Float(columns), tileH = Float(h)/Float(rows)
        let horizontal: [(Int, Int, Float)] = (0..<w).map { x in
            let f = (Float(x)+0.5)/tileW-0.5, c = Int(f.rounded(.down))
            return (((c%columns)+columns)%columns, (((c+1)%columns)+columns)%columns, f-Float(c))
        }
        let vertical: [(Int, Int, Float)] = (0..<h).map { y in
            let f = min(Float(rows-1), max(0, (Float(y)+0.5)/tileH-0.5)), r = min(rows-2, Int(f))
            return (r, r+1, f-Float(r))
        }
        image.rgba.withUnsafeMutableBufferPointer { px in
            curves.withUnsafeBufferPointer { curve in
                let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount*4))
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    for y in band*h/bands..<(band+1)*h/bands {
                        let (r0, r1, wy) = vertical[y]
                        for x in 0..<w {
                            let (c0, c1, wx) = horizontal[x], i = (y*w+x)*4
                            let a = (r0*columns+c0)*256, b = (r0*columns+c1)*256, c = (r1*columns+c0)*256, d = (r1*columns+c1)*256
                            // The luminance change is added equally to every channel: neutral surfaces stay neutral
                            // instead of having their faint tint amplified wherever the curve is steep.
                            let v = luminance(UnsafeBufferPointer(px), i)
                            let mapped = (curve[a+v]*(1-wx)+curve[b+v]*wx)*(1-wy)+(curve[c+v]*(1-wx)+curve[d+v]*wx)*wy
                            let delta = protection[v]*(mapped-Float(v))
                            for k in 0..<3 { px[i+k] = UInt8(clamping: Int((Float(px[i+k])+delta).rounded())) }
                        }
                    }
                }
            }
        }
    }
}
