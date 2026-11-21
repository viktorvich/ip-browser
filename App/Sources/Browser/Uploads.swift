import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// A web page's «choose file»: a photo from the library or any file from Files. Every image,
/// whichever way it came, is re-encoded without its metadata (location, camera, dates) before the
/// page gets it, as the privacy policy says; other files go as they are.
final class UploadPicker: NSObject, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    private var completion: (([URL]?) -> Void)?

    func present(
        from host: UIViewController, sourceView: UIView, multiple: Bool,
        completion: @escaping ([URL]?) -> Void
    ) {
        finish(nil)
        self.completion = completion
        let sheet = UIAlertController(title: L("attach"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: L("attach.photo"), style: .default) { [weak self, weak host] _ in
                var c = PHPickerConfiguration()
                c.filter = .images
                c.selectionLimit = multiple ? 0 : 1
                let picker = PHPickerViewController(configuration: c)
                picker.delegate = self
                host?.present(picker, animated: true)
            })
        sheet.addAction(
            UIAlertAction(title: L("attach.file"), style: .default) { [weak self, weak host] _ in
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                picker.allowsMultipleSelection = multiple
                picker.delegate = self
                host?.present(picker, animated: true)
            })
        sheet.addAction(UIAlertAction(title: L("cancel"), style: .cancel) { [weak self] _ in self?.finish(nil) })
        sheet.popoverPresentationController?.sourceView = sourceView
        host.present(sheet, animated: true)
    }

    private func finish(_ urls: [URL]?) {
        completion?(urls)
        completion = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let files = urls.compactMap(Self.cleaned)
            DispatchQueue.main.async { self.finish(files.isEmpty ? nil : files) }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        if results.isEmpty {
            finish(nil)
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var files: [URL] = []
        for result in results {
            group.enter()
            result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                defer { group.leave() }
                // The provider's file is gone when this returns: the cleaned copy is made now.
                guard let url, let image = try? Self.stripMetadata(from: url) else { return }
                lock.lock()
                files.append(image)
                lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in self?.finish(files.isEmpty ? nil : files) }
    }

    /// A picked file as the page gets it: an image re-encoded without metadata, anything else as it
    /// is. An image that cannot be re-encoded is not given at all (it would carry its metadata).
    static func cleaned(_ url: URL) -> URL? {
        let type =
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .image) else { return url }
        return try? stripMetadata(from: url)
    }

    /// The pixels again, with only what is needed to show them (orientation, animation timing):
    /// no GPS, EXIF, TIFF, IPTC or maker data.
    static func stripMetadata(from source: URL) throws -> URL {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(image)
        else { throw AppError.message("image") }
        let count = CGImageSourceGetCount(image)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        guard count > 0, let writer = CGImageDestinationCreateWithURL(destination as CFURL, type, count, nil) else {
            throw AppError.message("image")
        }
        for i in 0..<count {
            guard let pixels = CGImageSourceCreateImageAtIndex(image, i, nil) else { throw AppError.message("image") }
            let original = CGImageSourceCopyPropertiesAtIndex(image, i, nil) as? [CFString: Any] ?? [:]
            var kept: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.94]
            for key in [kCGImagePropertyOrientation, kCGImagePropertyGIFDictionary] {
                if let value = original[key] { kept[key] = value }
            }
            CGImageDestinationAddImage(writer, pixels, kept as CFDictionary)
        }
        guard CGImageDestinationFinalize(writer) else { throw AppError.message("image") }
        return destination
    }
}
