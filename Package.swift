// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MIRASGeometry", platforms: [.macOS(.v13)],
    products: [.library(name: "Geometry", targets: ["Geometry"])],
    targets: [
        .target(name: "Geometry", path: "Sources/Geometry"),
        .target(name: "MIRASCore", dependencies: ["Geometry"], path: "Sources/MIRASCapture",
                exclude: ["MIRASCaptureApp.swift", "Info.plist", "Resources", "ViewModels", "Views", "Services/CaptureService.swift", "Services/HeadingService.swift"],
                sources: ["Models", "Services/CaptureStore.swift", "Services/ImageCodec.swift", "Services/StitchService.swift", "Services/ExportService.swift", "Services/PanoramaMesh.swift"], resources: [.copy("Shaders")]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry"], path: "Tests/GeometryTests"),
        .testTarget(name: "MIRASCoreTests", dependencies: ["MIRASCore", "Geometry"], path: "Tests/MIRASCaptureTests")
    ])
