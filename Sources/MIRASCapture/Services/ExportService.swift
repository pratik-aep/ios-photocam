import Foundation
import Photos
import ImageIO
import Geometry

struct HotspotPackage: Codable {
    struct Defaults: Codable {
        var triggerAngle = 8.0, exitAngle = 11.0, hoverAngle = 3.0, hoverExitAngle = 4.5
        var dwellTime = 700, duration = 8000, cooldown = 4000
    }
    var defaults = Defaults()
    var hotspots: [Hotspot]
}
struct CaptureManifest: Codable {
    var appVersion: String
    var deviceModel: String
    var date: Date
    var frameCount: Int
    var outputSize: [String: Int]
    var yawReference: String
    var heading: HeadingRecord?
    var location: LocationRecord?
    var stitchSettings: StitchSettings
    var coverage: Double
    var warnings: [String]
}
actor ExportService {
    func export(_ capture: CaptureDocument, base: URL? = nil, deviceModel: String = "iPhone") throws -> URL {
        try Task.checkCancellation()
        guard capture.stitched else { throw CaptureError.message("Stitch the capture before exporting.") }
        for dot in capture.hotspots {
            guard !dot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !dot.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, dot.caption.count <= 300, dot.sources.allSatisfy({ URL(string: $0)?.scheme.map { ["https", "http"].contains($0) } == true }) else { throw CaptureError.message("Each hotspot needs a title, a caption up to 300 characters, and valid HTTP or HTTPS source URLs.") }
        }
        let fm = FileManager.default
        let root = (base ?? fm.temporaryDirectory).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: root) } }
        let folder = root.appending(path: capture.slug, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.copyItem(at: CaptureStore.folder(capture.id).appending(path: "panorama.jpg"), to: folder.appending(path: "panorama.jpg"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let spots = capture.hotspots.map { dot -> Hotspot in
            var d = dot; d.view = capture.slug; d.yaw = Geometry.wrap((Geometry.wrap(dot.yaw)*10).rounded()/10); d.pitch = (min(90,max(-90,dot.pitch))*10).rounded()/10; return d
        }
        try encoder.encode(HotspotPackage(hotspots: spots)).write(to: folder.appending(path: "hotspots.json"))
        let source = CGImageSourceCreateWithURL(folder.appending(path:"panorama.jpg") as CFURL,nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0,0,nil) as? [CFString:Any] }
        guard let outputWidth = properties?[kCGImagePropertyPixelWidth] as? Int, let outputHeight = properties?[kCGImagePropertyPixelHeight] as? Int else { throw CaptureError.message("Cannot read panorama dimensions. Re-stitch and retry.") }
        let heading = capture.yawReference == "trueNorth" ? capture.heading : nil
        let manifest = CaptureManifest(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0", deviceModel: deviceModel, date: capture.date, frameCount: capture.frames.count, outputSize: ["width": outputWidth, "height": outputHeight], yawReference: capture.yawReference, heading: heading, location: capture.location, stitchSettings: capture.stitchedSettings ?? capture.settings, coverage: capture.coverage, warnings: capture.warnings)
        try encoder.encode(manifest).write(to: folder.appending(path: "capture.json"))
        if capture.settings.includeFrames {
            let framesFolder = folder.appending(path: "frames")
            try fm.createDirectory(at: framesFolder, withIntermediateDirectories: true)
            // Only committed records belong in the package; undo/interrupted writes may leave other JPEGs.
            for frame in capture.frames {
                try Task.checkCancellation()
                try fm.copyItem(at: CaptureStore.folder(capture.id).appending(path: "frames/\(frame.file)"), to: framesFolder.appending(path: frame.file))
            }
            try encoder.encode(capture.frames).write(to: folder.appending(path: "frames.json"))
        }
        let zip = root.appending(path: "\(capture.slug).zip")
        try StoredZIP.write(folder: folder, to: zip)
        succeeded = true
        return zip
    }
    func saveToPhotos(_ capture: CaptureDocument) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CaptureError.message("Photos access is off. Enable it in Settings or export the package to Files.") }
        let url = CaptureStore.folder(capture.id).appending(path: "panorama.jpg")
        try await PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil) }
    }
}
// Uncompressed ZIP, standard CRC32 and central directory; readable by Files without a dependency.
enum StoredZIP {
    private static let crcTable: [UInt32] = (0..<256).map { v in var c = UInt32(v); for _ in 0..<8 { c = c & 1 != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1 }; return c }
    static func write(folder: URL, to url: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: folder.path) else { throw CaptureError.message("Cannot read the export folder.") }
        guard fm.createFile(atPath:url.path,contents:nil) else { throw CaptureError.message("Cannot create the ZIP archive. Check free storage.") }
        let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }
        var central = Data(), count: UInt16 = 0
        for case let relative as String in enumerator {
            try Task.checkCancellation()
            let file = folder.appending(path: relative)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let payload = try Data(contentsOf: file,options:.mappedIfSafe)
            let fileOffset = try handle.offset()
            guard payload.count < Int(UInt32.max), fileOffset < UInt64(UInt32.max), count < UInt16.max else { throw CaptureError.message("Package exceeds ZIP size limits. Export without raw frames.") }
            let name = Data((folder.lastPathComponent+"/"+relative).utf8)
            let crc = payload.reduce(UInt32.max) { (crc, b) in crcTable[Int((crc ^ UInt32(b)) & 255)] ^ (crc >> 8) } ^ UInt32.max
            let offset = UInt32(fileOffset), size = UInt32(payload.count)
            var archive = Data()
            archive.le(UInt32(0x04034b50)); archive.le(UInt16(20)); archive.le(UInt16(0x800)); archive.le(UInt16(0)); archive.le(UInt16(0)); archive.le(UInt16(0x21)); archive.le(crc); archive.le(size); archive.le(size); archive.le(UInt16(name.count)); archive.le(UInt16(0)); archive.append(name); try handle.write(contentsOf:archive); try handle.write(contentsOf:payload)
            central.le(UInt32(0x02014b50)); central.le(UInt16(20)); central.le(UInt16(20)); central.le(UInt16(0x800)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0x21)); central.le(crc); central.le(size); central.le(size); central.le(UInt16(name.count)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0)); central.le(offset); central.append(name); count += 1
        }
        let centralOffset = try handle.offset()
        guard centralOffset < UInt64(UInt32.max) else { throw CaptureError.message("Package exceeds ZIP size limits. Export without raw frames.") }
        let start = UInt32(centralOffset); var archive = central
        archive.le(UInt32(0x06054b50)); archive.le(UInt16(0)); archive.le(UInt16(0)); archive.le(count); archive.le(count); archive.le(UInt32(central.count)); archive.le(start); archive.le(UInt16(0))
        try handle.write(contentsOf:archive); try handle.synchronize()
    }
}
private extension Data { mutating func le<T: FixedWidthInteger>(_ value: T) { var n = value.littleEndian; Swift.withUnsafeBytes(of: &n) { append(contentsOf: $0) } } }
