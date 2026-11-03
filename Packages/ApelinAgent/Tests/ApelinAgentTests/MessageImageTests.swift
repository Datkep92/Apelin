@testable import ApelinAgent
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// A message's pictures as the endpoint they are sent to takes them: the
/// bytes that were attached when they fit, a scaled copy when they do not,
/// and the copy already made when the message is sent again.
@Suite("message images")
struct MessageImageTests {
    private static let anthropic = MessageImageLimits.anthropic
    private static let compatible = MessageImageLimits.openAICompatible

    // MARK: Limits

    @Test
    func `the limits follow the wire protocol its model speaks`() {
        #expect(MessageImageLimits.for(api: "anthropic-messages") == .anthropic)
        #expect(MessageImageLimits.for(api: "openai-completions") == .openAICompatible)
        #expect(MessageImageLimits.for(api: "openai-responses") == .openAICompatible)
        #expect(MessageImageLimits.for(api: "anything-else") == .openAICompatible)
        #expect(Self.compatible.longestSide > Self.anthropic.longestSide)
    }

    // MARK: One picture

    @Test
    func `a picture within the limits is sent as it was attached`() throws {
        let png = try #require(Self.png(width: 200, height: 100, alpha: true))

        let image = MessageImagePreparation.prepare(
            name: "shot.png",
            mimeType: "image/png",
            data: png,
            limits: Self.anthropic,
        )
        #expect(image.data == png)
        #expect(image.mimeType == "image/png")
    }

    @Test
    func `a picture past the side limit is scaled down and encoded again`() throws {
        let photo = try #require(FileReadImageTests.encoded(
            [FileReadImageTests.picture(width: 4000, height: 3000, noise: true)],
            as: "public.jpeg",
            quality: 0.9,
        ))

        let image = MessageImagePreparation.prepare(
            name: "photo.jpg",
            mimeType: "image/jpeg",
            data: photo,
            limits: Self.compatible,
        )
        let shown = try #require(Self.decoded(image.data))
        #expect(image.mimeType == "image/jpeg")
        #expect(image.data != photo)
        #expect(max(shown.width, shown.height) <= Self.compatible.longestSide)
        #expect(abs(Double(shown.width) / Double(shown.height) - 4.0 / 3.0) < 0.01)
        #expect(image.data.count <= Self.compatible.maximumBytes)
    }

    @Test
    func `bytes past the byte limit are encoded again until they fit`() throws {
        // Small on disk at first, and a megapixel of noise once encoded.
        let noise = try #require(Self.png(width: 2000, height: 2000, alpha: false, noise: true))

        let image = MessageImagePreparation.prepare(
            name: "noise.png",
            mimeType: "image/png",
            data: noise,
            limits: Self.anthropic,
        )
        #expect(image.data != noise)
        #expect(image.data.count <= Self.anthropic.maximumBytes)
        let shown = try #require(Self.decoded(image.data))
        #expect(max(shown.width, shown.height) <= Self.anthropic.longestSide)
    }

    @Test
    func `an animated GIF is sent as one frame`() throws {
        let frames = [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)]
            .map { FileReadImageTests.picture(width: 16, height: 16, color: $0) }
        let gif = try #require(FileReadImageTests.encoded(frames, as: "com.compuserve.gif"))

        let image = MessageImagePreparation.prepare(
            name: "dragon.gif",
            mimeType: "image/gif",
            data: gif,
            limits: Self.compatible,
        )
        #expect(image.data != gif)
        #expect(["image/png", "image/jpeg"].contains(image.mimeType))
        #expect(Self.frames(image.data) == 1)
    }

    @Test
    func `a mislabelled mime type is sent as what the bytes are`() throws {
        let photo = try #require(Self.jpeg(width: 60, height: 40))

        let image = MessageImagePreparation.prepare(
            name: "photo.jpg",
            mimeType: "image/jpg",
            data: photo,
            limits: Self.compatible,
        )
        #expect(image.mimeType == "image/jpeg")
        #expect(image.data == photo)
    }

    @Test
    func `a picture over the decode limit is still sent`() throws {
        // 81 megapixels: over `FileImage.maxSourcePixels`, and a few
        // kilobytes on disk, so no copy of it can be made here.
        let huge = try FileReadImageTests.blankPNG(width: 9000, height: 9000)

        let image = MessageImagePreparation.prepare(
            name: "huge.png",
            mimeType: "image/png",
            data: huge,
            limits: Self.compatible,
        )
        #expect(image.data == huge)
        #expect(image.mimeType == "image/png")
    }

    @Test
    func `bytes that are no picture at all are sent as they came`() {
        let text = Data("not an image, whatever it was called".utf8)

        let image = MessageImagePreparation.prepare(
            name: "chart",
            mimeType: "image/svg+xml",
            data: text,
            limits: Self.compatible,
        )
        #expect(image.data == text)
        #expect(image.mimeType == "image/svg+xml")
    }

    // MARK: The session's store

    @Test
    func `a picture sent again is the copy already prepared`() throws {
        var store = PreparedImageStore()
        let png = try #require(Self.png(width: 120, height: 80, alpha: true))

        let first = store.image(name: "one.png", mimeType: "image/png", data: png, limits: Self.compatible)
        let again = store.image(name: "one.png", mimeType: "image/png", data: png, limits: Self.compatible)
        #expect(store.held.count == 1)
        #expect(again.data == first.data)

        // Another endpoint takes another copy, and the first is kept.
        let photo = try #require(FileReadImageTests.encoded(
            [FileReadImageTests.picture(width: 3000, height: 2000, noise: true)],
            as: "public.jpeg",
            quality: 0.9,
        ))
        let wide = store.image(name: "photo.jpg", mimeType: "image/jpeg", data: photo, limits: Self.compatible)
        let narrow = store.image(name: "photo.jpg", mimeType: "image/jpeg", data: photo, limits: Self.anthropic)
        #expect(store.held.count == 3)
        let wideSide = try #require(Self.decoded(wide.data)).width
        let narrowSide = try #require(Self.decoded(narrow.data)).width
        #expect(wideSide > narrowSide)
    }

    @Test
    func `a store drops its oldest pictures past its bounds`() throws {
        var store = PreparedImageStore()
        store.maximumCount = 2
        let pictures = [
            try #require(Self.png(width: 40, height: 40, alpha: true)),
            try #require(Self.png(width: 80, height: 80, alpha: true)),
            try #require(Self.png(width: 120, height: 120, alpha: true)),
        ]

        for (index, png) in pictures.enumerated() {
            _ = store.image(name: "\(index).png", mimeType: "image/png", data: png, limits: Self.compatible)
        }
        #expect(store.held.count == 2)
        #expect(store.held.first?.key.source == pictures[1])
    }

    @Test
    func `a store never drops the picture it is sending`() throws {
        var store = PreparedImageStore()
        store.maximumBytes = 1
        let first = try #require(Self.png(width: 40, height: 40, alpha: true))
        let second = try #require(Self.png(width: 80, height: 80, alpha: true))

        _ = store.image(name: "one.png", mimeType: "image/png", data: first, limits: Self.compatible)
        _ = store.image(name: "two.png", mimeType: "image/png", data: second, limits: Self.compatible)
        #expect(store.held.count == 1)
        #expect(store.held.first?.key.source == second)
    }

    // MARK: Helpers

    private static func png(width: Int, height: Int, alpha: Bool, noise: Bool = false) -> Data? {
        FileReadImageTests.encoded(
            [FileReadImageTests.picture(width: width, height: height, alpha: alpha, noise: noise)],
            as: "public.png",
        )
    }

    private static func jpeg(width: Int, height: Int) -> Data? {
        FileReadImageTests.encoded([FileReadImageTests.picture(width: width, height: height)], as: "public.jpeg")
    }

    private static func decoded(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func frames(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetCount(source)
    }
}
