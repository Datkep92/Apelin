import ImageIO
import PDFKit
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// Presentation thumbnails never replace the original attachment or its MIME type.
@MainActor
final class MessageAttachmentPreviews {
    static let shared = MessageAttachmentPreviews()
    private final class Result: NSObject {
        let image: UIImage?
        init(_ image: UIImage?) {
            self.image = image
        }
    }

    private let cache = NSCache<NSUUID, Result>()
    private var pending: [UUID: [() -> Void]] = [:]

    private init() {
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func image(for attachment: ComposerAttachment) -> UIImage? {
        if let result = cache.object(forKey: attachment.id as NSUUID) {
            return result.image
        }
        let image: UIImage?
        if let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 1080,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary)
        {
            image = UIImage(cgImage: thumbnail)
        } else if attachment.data.starts(with: Data("%PDF".utf8)),
                  let page = PDFDocument(data: attachment.data)?.page(at: 0)
        {
            image = page.thumbnail(of: CGSize(width: 540, height: 720), for: .mediaBox)
        } else {
            return nil
        }
        store(image, for: attachment.id)
        return image
    }

    func prepare(_ attachment: ComposerAttachment, completion: @escaping () -> Void) {
        guard image(for: attachment) == nil,
              cache.object(forKey: attachment.id as NSUUID) == nil,
              attachment.text == nil,
              UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.conforms(to: .text) != true
        else { return }
        if pending[attachment.id] != nil {
            pending[attachment.id]?.append(completion)
            return
        }
        pending[attachment.id] = [completion]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent((attachment.name as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try attachment.data.write(to: file, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            DispatchQueue.main.async { [self] in finish(nil, for: attachment.id) }
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: file,
            size: CGSize(width: 540, height: 540),
            scale: 2,
            representationTypes: .thumbnail,
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.type == .thumbnail ? representation?.uiImage : nil
            DispatchQueue.main.async { [self] in
                try? FileManager.default.removeItem(at: directory)
                finish(image, for: attachment.id)
            }
        }
    }

    private func store(_ image: UIImage?, for id: UUID) {
        let cost = image?.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
        cache.setObject(Result(image), forKey: id as NSUUID, cost: cost)
    }

    private func finish(_ image: UIImage?, for id: UUID) {
        store(image, for: id)
        let callbacks = pending.removeValue(forKey: id) ?? []
        callbacks.forEach { $0() }
    }
}
