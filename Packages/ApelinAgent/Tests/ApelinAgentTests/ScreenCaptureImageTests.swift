@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import CoreGraphics
import Foundation
import ImageIO
import KWWKAgent
import Testing

/// A capture of a whole screen is often several megabytes of PNG, over what a
/// provider takes. It used to be dropped, which left the model blind to the
/// screen it had been asked to look at and said nothing about why: over the
/// limit the bytes are scaled and encoded again to fit, and the reply says so.
@Suite("A screen capture is shown, scaled when it is over the limit")
struct ScreenCaptureImageTests {
    @Test
    func `a capture over the limit comes back as a scaled picture, not nothing`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .full)
        defer { harness.home.remove() }
        // Noise, which PNG cannot shrink, so the capture stays well over the
        // limit whatever the encoder does.
        let capture = try #require(Self.encoded([Self.picture(width: 2048, height: 2048, noise: true)], as: "public.png"))
        #expect(capture.count > ToolRunner.maxImageBytes)
        await harness.backend.setCapturedImage(capture)

        let (result, _) = try await harness.run(.screenCapture, [:])

        let shown = try #require(Self.picture(result), "a picture the model can see")
        #expect(shown.mimeType == "image/jpeg", "an opaque screen is sent as JPEG")
        #expect(max(shown.width, shown.height) <= FileImage.maxPixelSize)
        #expect(shown.byteCount <= ToolRunner.maxImageBytes)
        let said = Self.text(result)
        #expect(said.contains("\(capture.count) bytes"))
        #expect(said.contains("the picture with this reply is scaled down"), "and the model is told why it is smaller")
    }

    @Test
    func `a capture within the limit goes as the host sent it`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .full)
        defer { harness.home.remove() }
        let capture = try #require(Self.encoded([Self.picture(width: 40, height: 20)], as: "public.png"))
        await harness.backend.setCapturedImage(capture)

        let (result, _) = try await harness.run(.screenCapture, [:])

        let shown = try #require(Self.picture(result))
        #expect(shown.byteCount == capture.count, "nothing is encoded again under the limit")
        #expect(shown.mimeType == "image/png", "the host's own bytes, not a re-encoded copy")
        #expect(shown.width == 40 && shown.height == 20)
        #expect(!Self.text(result).contains("scaled"), "and nothing is said about scaling")
    }

    @Test
    func `a capture that cannot be shown says so`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .full)
        defer { harness.home.remove() }
        await harness.backend.setCapturedImage(Data(repeating: 0x41, count: ToolRunner.maxImageBytes + 1))

        let (result, _) = try await harness.run(.screenCapture, [:])

        #expect(Self.picture(result) == nil, "no picture at all, not a broken one")
        let said = Self.text(result)
        #expect(said.contains("over the \(ToolRunner.maxImageBytes) bytes a provider takes"))
        #expect(said.contains("no smaller picture of it could be sent"))
    }

    // MARK: The reply

    private struct Shown {
        let mimeType: String
        let byteCount: Int
        let width: Int
        let height: Int
    }

    private static func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { block in
            if case let .text(text) = block { text.text } else { nil }
        }.joined(separator: "\n")
    }

    /// The picture a result carries, decoded; nil without one that decodes.
    private static func picture(_ result: AgentToolResult) -> Shown? {
        for case let .image(image) in result.content {
            guard let data = Data(base64Encoded: image.data),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return Shown(mimeType: image.mimeType, byteCount: data.count, width: decoded.width, height: decoded.height)
        }
        return nil
    }

    // MARK: Fixtures

    /// A picture of one colour, or of noise no encoder can shrink (the same
    /// noise every run), opaque so it is sent as JPEG and PNG has sizes over
    /// the limit.
    private static func picture(
        width: Int,
        height: Int,
        noise: Bool = false,
    ) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        )!
        if noise {
            // xorshift64: the same noise every run.
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            let words = context.data!.bindMemory(to: UInt64.self, capacity: width * height / 2)
            for index in 0 ..< width * height / 2 {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                words[index] = state
            }
        } else {
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()!
    }

    private static func encoded(_ images: [CGImage], as type: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, images.count, nil) else { return nil }
        for image in images {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
