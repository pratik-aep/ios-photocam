import XCTest
import Geometry
import ImageIO
import Metal
#if canImport(MIRASCore)
@testable import MIRASCore
#else
@testable import MIRASCapture
#endif

final class IntegrationTests: XCTestCase {
    func testLibrarySurvivesInterruptedCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = CaptureStore(root: root)
        let capture = CaptureDocument()
        let orphanID = UUID()
        try await store.save(capture)
        let orphan = root.appending(path: orphanID.uuidString).appending(path: "frames")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let damaged = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("broken json".utf8).write(to: damaged.appending(path: "document.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await store.load()
        XCTAssertEqual(library.captures.map(\.id), [capture.id])
        XCTAssertEqual(library.warnings.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: damaged.appending(path: "document.json")), Data("broken json".utf8))
    }

    func testEmptyStitchIsRejected() async throws {
        do {
            _ = try await StitchService().render(frames: [], width: 256, cpu: true, progress: { _ in })
            XCTFail("An empty stitch must not produce a successful blank panorama")
        } catch is CaptureError { }
    }

    func testMalformedPoseRecordIsRejectedBeforeDecoding() async throws {
        var capture = CaptureDocument()
        capture.frames = [.init(index: 0, target: .init(yaw: 0, pitch: 0), transform: [], intrinsics: [], width: 0, height: 0, timestamp: 0, exposure: 0)]
        do {
            _ = try await StitchService().stitch(capture, cpu: true, progress: { _ in })
            XCTFail("Expected damaged camera data to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Camera data"))
        }
    }

    func testUnsafeRenderInputsAreRejected() async throws {
        let good = SyntheticFixture.frames(width: 80, height: 60)
        let service = StitchService()
        for width in [0, -2, 3, 255, 8192, Int.max] {
            do {
                _ = try await service.render(frames: good, width: width, cpu: true, progress: { _ in })
                XCTFail("Expected width \(width) to be rejected")
            } catch is CaptureError { }
        }
        var damaged = good[0]
        damaged.image.rgba = []
        do {
            _ = try await service.render(frames: [damaged], width: 256, cpu: false, progress: { _ in })
            XCTFail("Expected truncated pixel storage to be rejected before GPU submission")
        } catch is CaptureError { }
    }

    func testRawExportExcludesUncommittedFrames() async throws {
        var capture = CaptureDocument(); capture.stitched = true; capture.settings.includeFrames = true
        let frame = FrameRecord(index: 0, target: .init(yaw: 0, pitch: 0), transform: [], intrinsics: [], width: 80, height: 60, timestamp: 0, exposure: 0.01)
        capture.frames = [frame]
        try await CaptureStore.shared.save(capture)
        let folder = CaptureStore.folder(capture.id)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ImageCodec.jpeg(SyntheticFixture.panorama(width: 256), heading: nil, to: folder.appending(path: "panorama.jpg"))
        try Data([1, 2, 3]).write(to: folder.appending(path: "frames/000.jpg"))
        try Data([4, 5, 6]).write(to: folder.appending(path: "frames/001.jpg"))
        let zip = try await ExportService().export(capture)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let exported = zip.deletingLastPathComponent().appending(path: capture.slug)
        let files = try FileManager.default.contentsOfDirectory(atPath: exported.appending(path: "frames").path)
        XCTAssertEqual(files, ["000.jpg"])
        let records = try JSONDecoder().decode([FrameRecord].self, from: Data(contentsOf: exported.appending(path: "frames.json")))
        XCTAssertEqual(records.map(\.index), [0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "frames/001.jpg").path))
    }

    func testPackageAndTapRayRoundTrip() async throws {
        var c = CaptureDocument(); c.name = "Test Heritage"; c.stitched = true; c.settings.width = 512
        let angle = Geometry.tapRay(x:200,y:400,width:400,height:800,verticalFOV:70,look:.init(yaw:359.96,pitch:22.3))
        c.hotspots = [.init(view:c.slug,title:"Gateway",yaw:angle.yaw,pitch:angle.pitch,caption:"Carved entrance",sources:["https://example.org/source"])]
        try await CaptureStore.shared.save(c)
        defer { let id = c.id; Task { try? await CaptureStore.shared.delete(id) } }
        let pano = CaptureStore.folder(c.id).appending(path:"panorama.jpg")
        try ImageCodec.jpeg(SyntheticFixture.panorama(width:512),heading:0,to:pano)
        let zip = try await ExportService().export(c)
        let folder = zip.deletingLastPathComponent().appending(path:c.slug)
        let data = try Data(contentsOf:folder.appending(path:"hotspots.json"))
        let decoded = try JSONDecoder().decode(HotspotPackage.self,from:data)
        XCTAssertEqual(decoded.defaults.triggerAngle,8); XCTAssertEqual(decoded.defaults.hoverExitAngle,4.5)
        XCTAssertEqual(decoded.hotspots[0].yaw,0); XCTAssertEqual(decoded.hotspots[0].view,c.slug)
        XCTAssertLessThan(SphericalAngle(yaw:decoded.hotspots[0].yaw,pitch:decoded.hotspots[0].pitch).distance(to:angle),0.1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(Set(json.keys),["defaults","hotspots"])
        let dots = try XCTUnwrap(json["hotspots"] as? [[String:Any]])
        XCTAssertEqual(Set(dots[0].keys),["id","view","title","yaw","pitch","caption","sources"])
        let zipData = try Data(contentsOf:zip); XCTAssertEqual(Array(zipData.prefix(4)),[0x50,0x4b,0x03,0x04])
        let manifestDecoder = JSONDecoder(); manifestDecoder.dateDecodingStrategy = .iso8601
        let manifest = try manifestDecoder.decode(CaptureManifest.self,from: Data(contentsOf:folder.appending(path:"capture.json")))
        XCTAssertEqual(manifest.yawReference,"firstShot"); XCTAssertEqual(manifest.outputSize["width"],512)
        #if os(macOS)
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/unzip"); process.arguments = ["-t",zip.path]; try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        let names = Process(); names.executableURL = URL(fileURLWithPath:"/usr/bin/unzip"); names.arguments = ["-Z1",zip.path]; let pipe = Pipe(); names.standardOutput = pipe
        try names.run(); let listing = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self); names.waitUntilExit()
        XCTAssertEqual(Set(listing.split(separator:"\n").map(String.init)),Set(["hotspots.json","capture.json","panorama.jpg"].map { c.slug+"/"+$0 }))
        #endif
        try FileManager.default.removeItem(at:zip.deletingLastPathComponent())
    }
    func testGPanoMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString+".jpg"); defer { try? FileManager.default.removeItem(at:url) }
        try ImageCodec.jpeg(SyntheticFixture.panorama(width:512),heading:0,to:url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source,0,nil))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata,nil,"GPano:ProjectionType" as CFString) as String?,"equirectangular")
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata,nil,"GPano:FullPanoWidthPixels" as CFString) as String?,"512")
    }
    func testCPUStitchService() async throws {
        let frames = Reprojection.compensate(SyntheticFixture.frames(width:320,height:240))
        let result = try await StitchService().render(frames:frames,width:512,cpu:true,progress:{ _ in })
        let metrics = SyntheticFixture.metrics(result.image)
        XCTAssertLessThan(metrics.meanAbsoluteError,0.06); XCTAssertGreaterThanOrEqual(result.coverage,0.98); XCTAssertFalse(result.usedMetal)
    }
    func testMetalAgreesWithCPU() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let frames = Reprojection.compensate(SyntheticFixture.frames(width:160,height:120))
        let service = StitchService()
        let cpu = try await service.render(frames:frames,width:256,cpu:true,progress:{ _ in })
        let gpu = try await service.render(frames:frames,width:256,cpu:false,progress:{ _ in })
        XCTAssertTrue(gpu.usedMetal,"Metal must execute; a CPU fallback does not validate the kernel")
        let error = zip(cpu.image.rgba,gpu.image.rgba).reduce(0.0) { $0+abs(Double($1.0)-Double($1.1))/255 }/Double(cpu.image.rgba.count)
        XCTAssertLessThan(error,0.002)
    }
    func testPoseRecordsStitchAtNorth() async throws {
        var capture = CaptureDocument(); capture.settings.width = 512; capture.referenceWorldYaw = 37; capture.yawReference = "trueNorth"
        let frames = SyntheticFixture.frames(width:320,height:240)
        try await CaptureStore.shared.save(capture)
        defer { let id = capture.id; Task { try? await CaptureStore.shared.delete(id) } }
        let a = Float(37 * Double.pi/180)
        func world(_ v: SIMD4<Float>) -> [Float] { [cos(a)*v.x-sin(a)*v.z,v.y,sin(a)*v.x+cos(a)*v.z,0] }
        for (index, frame) in frames.enumerated() {
            let p = frame.projection
            let transform = world(p.x)+world(p.y)+world(p.z)+[0,0,0,1]
            let record = FrameRecord(index:index,target:SphericalAngle(yaw:0,pitch:0),transform:transform,intrinsics:[p.x.w,0,0,0,p.y.w,0,p.meta.x,p.meta.y,1],width:320,height:240,timestamp:Double(index),exposure:0.01)
            let url = CaptureStore.folder(capture.id).appending(path:"frames/\(record.file)")
            try ImageCodec.jpeg(frame.image,heading:nil,to:url); capture.frames.append(record)
        }
        try await CaptureStore.shared.save(capture)
        let result = try await StitchService().stitch(capture,cpu:true,progress:{ _ in })
        let metrics = SyntheticFixture.metrics(result.image)
        XCTAssertLessThan(metrics.meanAbsoluteError,0.06); XCTAssertLessThanOrEqual(abs(metrics.bestHorizontalShift),2); XCTAssertGreaterThanOrEqual(result.coverage,0.98)
    }
    func testMissingNadirFillAndLogoKeepsHorizon() async throws {
        let all = Reprojection.compensate(SyntheticFixture.frames(width:160,height:120))
        let frames = all.filter { $0.projection.z.y < 0.99 }
        let service = StitchService()
        let plain = try await service.render(frames:frames,width:256,cpu:true,progress:{ _ in })
        let capped = try await service.render(frames:frames,width:256,cpu:true,nadirCap:true,progress:{ _ in })
        for i in stride(from:3,to:plain.image.rgba.count,by:4) { XCTAssertEqual(plain.image.rgba[i],255) }
        XCTAssertEqual(Array(plain.image.rgba.prefix(256*100*4)),Array(capped.image.rgba.prefix(256*100*4)))
        XCTAssertNotEqual(Array(plain.image.rgba.suffix(256*4)),Array(capped.image.rgba.suffix(256*4)))
    }
    func testCancellation() async throws {
        let task = Task { try await StitchService().render(frames:[],width:4096,cpu:true,progress:{ _ in }) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
    }
}
