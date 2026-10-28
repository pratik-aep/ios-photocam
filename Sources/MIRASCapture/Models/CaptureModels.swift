import Foundation
import Geometry

struct FrameRecord: Codable, Identifiable, Sendable {
    var id: Int { index }
    var index: Int
    var target: SphericalAngle
    var transform: [Float] // Column major, camera to AR world; image remains in sensor orientation.
    var intrinsics: [Float]
    var width: Int
    var height: Int
    var timestamp: Double
    var exposure: Double
    var file: String { String(format: "%03d.jpg", index) }
}
struct HeadingRecord: Codable, Sendable {
    var degrees: Double; var accuracy: Double
}
struct LocationRecord: Codable, Sendable {
    var latitude: Double; var longitude: Double; var accuracy: Double
}
struct StitchSettings: Codable, Sendable {
    var width = 6144 // Matches the decoded frames' angular resolution and the viewer's default zoom at about 1:1.
    var includeFrames = false
    var nadirCap = false
    var refinement = false // Wide alignment search for captures with large sensor drift.
    var enhance = true
}
extension StitchSettings {
    // Keys added after the first release decode with defaults so older captures still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = StitchSettings()
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? d.width
        includeFrames = try c.decodeIfPresent(Bool.self, forKey: .includeFrames) ?? d.includeFrames
        nadirCap = try c.decodeIfPresent(Bool.self, forKey: .nadirCap) ?? d.nadirCap
        refinement = try c.decodeIfPresent(Bool.self, forKey: .refinement) ?? d.refinement
        enhance = try c.decodeIfPresent(Bool.self, forKey: .enhance) ?? d.enhance
    }
}
struct Hotspot: Codable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var view: String
    var title: String
    var yaw: Double
    var pitch: Double
    var caption: String
    var sources: [String] = []
}
struct CaptureDocument: Codable, Identifiable, Sendable {
    var id = UUID()
    var name = "Untitled heritage view"
    var date = Date()
    var place: String?
    var frames: [FrameRecord] = []
    var heading: HeadingRecord?
    var location: LocationRecord?
    var yawReference = "firstShot"
    var referenceWorldYaw = 0.0
    var targets: [ShotTarget] = []
    var hotspots: [Hotspot] = []
    var settings = StitchSettings()
    var stitchedSettings: StitchSettings?
    var stitched = false
    var coverage = 0.0
    var warnings: [String] = []
    var slug: String {
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return (words.isEmpty ? "miras" : words.joined(separator: "-")) + "-" + id.uuidString.prefix(8).lowercased()
    }
    var status: String { !stitched ? "Frames only" : hotspots.isEmpty ? "Stitched" : "Tagged" }
}
enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
