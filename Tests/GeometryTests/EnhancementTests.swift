import XCTest
@testable import Geometry
final class EnhancementTests: XCTestCase {
    /// A shaded white wall (left half) beside a tinted, patterned curtain (right half).
    private func scene(width w: Int = 1024, height h: Int = 512) -> RasterImage {
        var bytes = [UInt8](repeating: 255, count: w*h*4)
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4, fx = Double(x), fy = Double(y)
            if x < w/2 {
                let v = 228+6*sin(fx/37)*cos(fy/23)
                for c in 0..<3 { bytes[i+c] = UInt8(v) }
            } else {
                let v = 150+70*sin(fx/9)*sin(fy/11)
                bytes[i] = UInt8(clamping: Int(v+18)); bytes[i+1] = UInt8(clamping: Int(v)); bytes[i+2] = UInt8(clamping: Int(v-18))
            }
        } }
        return .init(width: w, height: h, rgba: bytes)
    }
    private func luminance(_ image: RasterImage, _ x: Int, _ y: Int) -> Double {
        let i = (y*image.width+x)*4
        return 0.299*Double(image.rgba[i])+0.587*Double(image.rgba[i+1])+0.114*Double(image.rgba[i+2])
    }
    private func stats(_ image: RasterImage, _ xs: Range<Int>) -> (mean: Double, std: Double, low: Double) {
        var values: [Double] = []
        for y in 0..<image.height { for x in xs { values.append(luminance(image, x, y)) } }
        let mean = values.reduce(0, +)/Double(values.count)
        let std = sqrt(values.reduce(0) { $0+($1-mean)*($1-mean) }/Double(values.count))
        return (mean, std, values.sorted()[values.count/100])
    }
    func testDehazeRestoresContrastAndKeepsWhitesWhite() {
        var image = scene()
        // 40% veil toward a bright haze colour, as glare from a window does.
        for i in stride(from: 0, to: image.rgba.count, by: 4) { for c in 0..<3 { image.rgba[i+c] = UInt8(0.6*Double(image.rgba[i+c])+0.4*235) } }
        let hazy = image, w = image.width
        Enhancement.levels(&image)
        Enhancement.localContrast(&image, clip: 2, strength: 0.6)
        let curtainBefore = stats(hazy, w/2..<w), curtainAfter = stats(image, w/2..<w)
        let wallBefore = stats(hazy, 0..<w/2), wallAfter = stats(image, 0..<w/2)
        print(String(format: "DEHAZE: curtain σ %.1f → %.1f, 1%% %.0f → %.0f · wall mean %.1f → %.1f, σ %.2f → %.2f", curtainBefore.std, curtainAfter.std, curtainBefore.low, curtainAfter.low, wallBefore.mean, wallAfter.mean, wallBefore.std, wallAfter.std))
        XCTAssertGreaterThan(curtainAfter.std, curtainBefore.std*1.4, "Local contrast must be restored")
        XCTAssertLessThan(curtainAfter.low, curtainBefore.low-15, "Veiled darks must deepen")
        XCTAssertGreaterThan(wallAfter.mean, wallBefore.mean-4, "White walls must not be pushed toward grey")
        XCTAssertLessThan(wallAfter.std, wallBefore.std*2.5+0.5, "Flat walls must not turn blotchy")
        var tint = 0.0
        for y in 0..<image.height { for x in 0..<w/2 { let i = (y*w+x)*4; tint += abs(Double(image.rgba[i])-Double(image.rgba[i+2])) } }
        XCTAssertLessThan(tint/Double(image.height*w/2), 1, "Neutral surfaces must stay neutral")
    }
    func testLocalContrastIsContinuousAcrossTheSeam() {
        let w = 1024, h = 512
        var image = RasterImage(width: w, height: h, rgba: [UInt8](repeating: 255, count: w*h*4))
        for y in 0..<h { for x in 0..<w {
            let v = 140+70*sin(Double(x)/Double(w)*2 * .pi*5)*cos(Double(y)/41)
            for c in 0..<3 { image.rgba[(y*w+x)*4+c] = UInt8(v) }
        } }
        Enhancement.localContrast(&image, clip: 2, strength: 0.6)
        var seam = 0.0, interior = 0.0
        for y in 0..<h {
            seam += abs(luminance(image, 0, y)-luminance(image, w-1, y))
            interior += abs(luminance(image, w/2, y)-luminance(image, w/2-1, y))
        }
        XCTAssertLessThan(seam, interior*1.5+Double(h))
    }
    func testLevelsLimitStretch() {
        // A legitimately low-contrast scene must not be stretched to the full range.
        var image = RasterImage(width: 256, height: 128, rgba: [UInt8](repeating: 255, count: 256*128*4))
        for y in 0..<128 { for x in 0..<256 { for c in 0..<3 { image.rgba[(y*256+x)*4+c] = UInt8(100+(x*7+y*13)%41) } } }
        Enhancement.levels(&image)
        var low = 255, high = 0
        for i in stride(from: 0, to: image.rgba.count, by: 4) { low = min(low, Int(image.rgba[i])); high = max(high, Int(image.rgba[i])) }
        XCTAssertLessThanOrEqual(high-low, Int(40*1.3)+2)
    }
}
