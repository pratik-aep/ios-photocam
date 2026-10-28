import ARKit
import AVFoundation
import CoreImage
import Geometry
import simd

struct CameraSample {
    var angle: SphericalAngle
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    var resolution: CGSize
    var timestamp: Double
    var velocity: Double
    var translation: Double
    var normal: Bool
    var dark: Bool
}
final class CaptureService: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session = ARSession()
    var onSample: ((CameraSample) -> Void)?
    private var previous: (simd_quatf, Double)?
    private var origin: SIMD3<Float>?
    private var lastUpdate = 0.0
    private let queue = DispatchQueue(label: "org.miras.capture")
    private let context = CIContext()
    func start() throws {
        guard ARWorldTrackingConfiguration.isSupported else { throw CaptureError.message("AR capture needs a supported iPhone. Use Load sample capture to explore on the simulator.") }
        queue.sync { previous = nil; origin = nil; lastUpdate = 0 }
        let config = ARWorldTrackingConfiguration(); config.worldAlignment = .gravity
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing { config.videoFormat = format }
        session.delegate = self; session.delegateQueue = queue
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
    func stop() { session.pause(); unlockCamera() }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera, t = camera.transform
        let forward = Vector3(Double(-t.columns.2.x), Double(-t.columns.2.y), Double(-t.columns.2.z))
        let angle = SphericalAngle(vector: forward)
        let attitude = simd_quatf(t)
        let velocity: Double
        if let previous { velocity = Double(2*acos(min(1,abs(simd_dot(attitude.vector,previous.0.vector)))))*180 / .pi/max(0.001,frame.timestamp-previous.1) } else { velocity = 0 }
        previous = (attitude, frame.timestamp)
        guard frame.timestamp-lastUpdate > 0.06 else { return }; lastUpdate = frame.timestamp
        let position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let translation = origin.map { Double(simd_distance($0, position)) } ?? 0
        let normal: Bool; if case .normal = camera.trackingState { normal = true } else { normal = false }
        let buffer = frame.capturedImage
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        var luma = 0.0
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0), row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            var count = 0
            for y in stride(from: 0, to: h, by: 32) { for x in stride(from: 0, to: w, by: 32) { luma += Double(ptr[y*row+x]); count += 1 } }
            luma /= Double(max(1, count))
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        let sample = CameraSample(angle: angle, transform: t, intrinsics: camera.intrinsics, resolution: camera.imageResolution, timestamp: frame.timestamp, velocity: velocity, translation: translation, normal: normal, dark: luma < 35)
        DispatchQueue.main.async { self.onSample?(sample) }
    }
    func capture(index: Int, target: SphericalAngle) async throws -> (FrameRecord, Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            session.captureHighResolutionFrame { [self] high, error in
                queue.async { [self] in
                    guard let frame = high ?? session.currentFrame else { continuation.resume(throwing: error ?? CaptureError.message("No camera frame. Point at a textured area and retry.")); return }
                    do {
                        let buffer = frame.capturedImage, image = CIImage(cvPixelBuffer: buffer)
                        guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]) else { throw CaptureError.message("Could not encode the camera frame. Retry this target.") }
                        let t = frame.camera.transform, k = frame.camera.intrinsics
                        if origin == nil { origin = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z) }
                        let transform = (0..<4).flatMap { c in (0..<4).map { r in t[c][r] } }
                        let intrinsics = (0..<3).flatMap { c in (0..<3).map { r in k[c][r] } }
                        let record = FrameRecord(index: index, target: target, transform: transform, intrinsics: intrinsics, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), timestamp: frame.timestamp, exposure: frame.camera.exposureDuration)
                        continuation.resume(returning: (record, data, high == nil))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
    func lockCamera() throws {
        guard let camera = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
        if camera.isExposureModeSupported(.locked) { camera.exposureMode = .locked }
        if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
        if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked }
    }
    private func unlockCamera() {
        guard let camera = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera, (try? camera.lockForConfiguration()) != nil else { return }
        defer { camera.unlockForConfiguration() }
        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
    }
}
