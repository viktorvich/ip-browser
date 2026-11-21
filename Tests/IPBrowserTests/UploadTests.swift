import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import IPBrowser

/// An image given to a web page carries no location or camera data, whichever way it was picked.
final class UploadTests: XCTestCase {
    private func photoWithLocation() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 41.31, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 69.24, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:21 10:00:00"],
        ]
        CGImageDestinationAddImage(writer, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    private func properties(_ url: URL) -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testImageFromFilesLosesItsMetadata() throws {
        let original = try photoWithLocation()
        XCTAssertNotNil(properties(original)[kCGImagePropertyGPSDictionary], "the fixture must carry a location")
        let cleaned = try XCTUnwrap(UploadPicker.cleaned(original))
        XCTAssertNotEqual(cleaned, original)
        let kept = properties(cleaned)
        XCTAssertNil(kept[kCGImagePropertyGPSDictionary])
        XCTAssertNil((kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
        XCTAssertNil((kept[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertEqual(kept[kCGImagePropertyPixelWidth] as? Int, 8)
        XCTAssertEqual(cleaned.lastPathComponent, original.lastPathComponent, "the page sees the file's own name")
    }

    func testOtherFilesGoAsTheyAre() throws {
        let text = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("hello".utf8).write(to: text)
        XCTAssertEqual(UploadPicker.cleaned(text), text)
    }

    func testBrokenImageIsNotGiven() throws {
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data("not a picture".utf8).write(to: fake)
        XCTAssertNil(UploadPicker.cleaned(fake))
    }
}
