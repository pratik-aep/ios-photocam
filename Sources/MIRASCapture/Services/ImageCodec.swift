import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Geometry

enum ImageCodec {
    static func decode(_ url: URL, maxSize: Int = 1920) throws -> RasterImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSize, kCGImageSourceCreateThumbnailWithTransform: false] as CFDictionary) else { throw CaptureError.message("Cannot read image \(url.lastPathComponent).") }
        return try raster(image)
    }
    static func raster(_ image: CGImage) throws -> RasterImage {
        var bytes = [UInt8](repeating: 0, count: image.width*image.height*4)
        let success = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(data: ptr.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        guard success else { throw CaptureError.message("Image memory allocation failed. Choose a smaller output size.") }
        return .init(width: image.width, height: image.height, rgba: bytes)
    }
    static func cgImage(_ raster: RasterImage) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(raster.rgba) as CFData), let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw CaptureError.message("Cannot create panorama image. Try a smaller size.") }
        return image
    }
    static func jpeg(_ raster: RasterImage, heading: Double?, to url: URL) throws {
        let image = try cgImage(raster)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw CaptureError.message("Cannot create JPEG at the chosen location.") }
        let metadata = CGImageMetadataCreateMutable()
        let ns = "http://ns.google.com/photos/1.0/panorama/" as CFString
        CGImageMetadataRegisterNamespaceForPrefix(metadata, ns, "GPano" as CFString, nil)
        var fields = ["ProjectionType": "equirectangular", "UsePanoramaViewer": "True", "FullPanoWidthPixels": "\(raster.width)", "FullPanoHeightPixels": "\(raster.height)", "CroppedAreaImageWidthPixels": "\(raster.width)", "CroppedAreaImageHeightPixels": "\(raster.height)", "CroppedAreaLeftPixels": "0", "CroppedAreaTopPixels": "0"]
        if let heading { fields["PoseHeadingDegrees"] = "\(heading)" }
        for (key, value) in fields { CGImageMetadataSetValueWithPath(metadata, nil, "GPano:\(key)" as CFString, value as CFString) }
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message("Saving the panorama failed. Check free storage and retry.") }
    }
}
