import Foundation

struct CaptureLibrary: Sendable {
    var captures: [CaptureDocument]
    var warnings: [String]
}

actor CaptureStore {
    static let shared = CaptureStore()
    private let storageRoot: URL
    init(root: URL = CaptureStore.root) { storageRoot = root }
    nonisolated static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Captures", directoryHint: .isDirectory)
    }
    nonisolated static func folder(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    private func folder(_ id: UUID) -> URL { storageRoot.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func save(_ capture: CaptureDocument) throws {
        let folder = folder(capture.id)
        try FileManager.default.createDirectory(at: folder.appending(path: "frames"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(capture).write(to: folder.appending(path: "document.json"), options: .atomic)
        try encoder.encode(capture.frames).write(to: folder.appending(path: "frames.json"), options: .atomic)
    }
    func list() throws -> [CaptureDocument] {
        try load().captures
    }
    func load() throws -> CaptureLibrary {
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var captures: [CaptureDocument] = [], warnings: [String] = []
        let folders = try FileManager.default.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                let capture = try decoder.decode(CaptureDocument.self, from: Data(contentsOf: folder.appending(path: "document.json")))
                guard capture.id == id else { throw CaptureError.message("Capture identifier does not match its folder.") }
                captures.append(capture)
            } catch {
                warnings.append("Capture \(folder.lastPathComponent) could not be loaded. Its files have been kept for recovery.")
            }
        }
        return CaptureLibrary(captures: captures.sorted { $0.date > $1.date }, warnings: warnings)
    }
    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: folder(id)) }
    func writeFrame(_ data: Data, record: FrameRecord, capture: UUID) throws {
        let directory = folder(capture).appending(path: "frames")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: record.file), options: .atomic)
    }
}
