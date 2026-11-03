import Foundation
import KWWKAI

/// A picture a message carries, as the endpoint is sent it: the bytes that
/// were attached when they already fit what that endpoint takes, and a
/// scaled, re-encoded copy when they do not. The file the attachment was
/// saved as is never touched — this is a copy of it, prepared in memory.
struct MessageImage: Sendable {
    let data: Data
    let mimeType: String

    /// What a request carries: the bytes base64-encoded, as every provider's
    /// wire shape has them.
    var content: ImageContent {
        ImageContent(data: data.base64EncodedString(), mimeType: mimeType)
    }
}

/// What one endpoint takes in one request.
struct MessageImageLimits: Sendable, Hashable {
    /// The longer side a picture is scaled to at most.
    var longestSide: Int
    /// The most bytes one picture's copy may be before base64 makes it a
    /// third larger.
    var maximumBytes: Int

    /// Anthropic's Messages API recommends 1568 px a side — the size kwwk's
    /// own image normalizer and `FileImage` use — and a picture that size
    /// stays under the 5 MB its request takes.
    static let anthropic = MessageImageLimits(
        longestSide: FileImage.maxPixelSize,
        maximumBytes: FileImage.maxBytes,
    )

    /// An OpenAI-compatible or Copilot endpoint scales anything past 2048 px
    /// a side down itself and takes 20 MB an image, of which a smaller one
    /// costs fewer tokens: a photo is left as it is rather than re-encoded
    /// smaller than the endpoint would have made it.
    static let openAICompatible = MessageImageLimits(
        longestSide: 2048,
        maximumBytes: 4 * 1024 * 1024,
    )

    /// What the endpoint behind `api` — kwwk's own name for the wire
    /// protocol, `model.api` — takes. Anthropic's Messages API is the one
    /// that wants a smaller picture; the rest of the field is OpenAI's
    /// shape, compatible endpoints and Copilot alike.
    static func `for`(api: String) -> MessageImageLimits {
        api == "anthropic-messages" ? .anthropic : .openAICompatible
    }
}

/// Pictures prepared for one session's endpoints, by the bytes they were
/// prepared from and the limits they were prepared for. A message sent
/// again — a request that failed and was retried — is sent the same copy
/// the model was given, without scaling or encoding it a second time, and
/// its bytes stay identical, which the provider's prompt cache depends on.
struct PreparedImageStore {
    /// The most the store holds, the attached bytes it is keyed by and the
    /// copies together: a conversation carries a handful, not a photo
    /// library.
    var maximumBytes = 16 * 1024 * 1024
    /// And the most pictures at once, whatever their size.
    var maximumCount = 8

    /// What a prepared picture was made from: the bytes that were attached,
    /// and the limits they were prepared for — a model switched
    /// mid-conversation reads another endpoint's limits, so the same
    /// picture prepared for it is another entry.
    struct Key: Hashable {
        var source: Data
        var limits: MessageImageLimits
    }

    /// Oldest first.
    private(set) var held: [(key: Key, image: MessageImage)] = []

    /// What the store is holding, keys and copies together.
    var byteCount: Int {
        held.reduce(0) { $0 + $1.key.source.count + $1.image.data.count }
    }

    /// `data`, named `name`, as `limits` are sent it: the copy already
    /// prepared for the same bytes and limits, or one made now and kept
    /// while the store's bounds allow.
    mutating func image(
        name: String,
        mimeType: String,
        data: Data,
        limits: MessageImageLimits,
    ) -> MessageImage {
        let key = Key(source: data, limits: limits)
        if let prepared = held.first(where: { $0.key == key }) {
            return prepared.image
        }
        let image = MessageImagePreparation.prepare(
            name: name,
            mimeType: mimeType,
            data: data,
            limits: limits,
        )
        held.append((key, image))
        evictOldest()
        return image
    }

    /// Drops the oldest until the store is within its bounds, never the last
    /// one: the picture being sent now is the one just added.
    private mutating func evictOldest() {
        while held.count > 1,
              (held.count > maximumCount || byteCount > maximumBytes) {
            held.removeFirst()
        }
    }
}

/// One attached picture, prepared for one endpoint's limits.
enum MessageImagePreparation {
    /// `data`, named `name` by the file it was attached as, as the endpoint
    /// is sent it: unchanged when it is a PNG or JPEG already within the
    /// limits, and a scaled, re-encoded copy otherwise. A copy that cannot be
    /// made — a corrupt file, or a picture over the decode limit — is the
    /// file's own bytes, since a picture the user attached is never dropped
    /// and a provider refusing it is better than a message that lost it.
    static func prepare(
        name: String,
        mimeType: String,
        data: Data,
        limits: MessageImageLimits,
    ) -> MessageImage {
        if let format = FileImage.format(of: Data(data.prefix(FileImage.sniffedBytes))),
           let size = FileImage.pixelSize(of: data),
           max(size.width, size.height) <= limits.longestSide,
           data.count <= limits.maximumBytes {
            // PNG and JPEG are what the providers take as they are; the
            // bytes sent are the user's own, which also keeps a re-sent
            // message's prefix byte for byte identical.
            switch format {
            case "PNG": return MessageImage(data: data, mimeType: "image/png")
            case "JPEG": return MessageImage(data: data, mimeType: "image/jpeg")
            default: break
            }
        }
        // HEIC, WebP, TIFF, BMP and GIF have to be re-encoded anyway — no
        // provider is sent an animation or a format it may not take — and so
        // has a picture past either limit.
        if let image = try? FileImage.read(
            data,
            frame: nil,
            name: name,
            sideLimit: limits.longestSide,
            bytesLimit: limits.maximumBytes,
        ) {
            return MessageImage(data: image.data, mimeType: image.mimeType)
        }
        return MessageImage(data: data, mimeType: mimeType)
    }
}
