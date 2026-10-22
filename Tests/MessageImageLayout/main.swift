import Foundation

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

let albums: [[CGFloat]] = [
    [], [1], [16 / 9], [9 / 16], [1, 1], [2, 2],
    [0.6, 1.7, 1], [1.7, 0.6, 1], [1, 1, 1, 1], [1.7, 1, 0.7, 1.3],
    [0, .nan, .infinity, -1],
] + (5 ... 20).map { count in (0 ..< count).map { [CGFloat(0.6), 1, 1.7][$0 % 3] } }

for width: CGFloat in [1, 60, 320, 540] {
    for ratios in albums {
        let frames = MessageImageLayout.frames(aspectRatios: ratios, width: width)
        require(frames.count == ratios.count, "Every image must appear exactly once")
        for (index, frame) in frames.enumerated() {
            require(frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0, "Tiles must have finite positive sizes")
            require(frame.minX >= 0 && frame.minY >= 0 && frame.maxX <= width + 0.0001, "Tiles must stay inside the album")
            for previous in frames.prefix(index) {
                let overlap = frame.intersection(previous)
                require(overlap.isNull || overlap.width < 0.0001 || overlap.height < 0.0001, "Tiles must not overlap")
            }
        }
    }
}

require(MessageImageLayout.frames(aspectRatios: [1], width: 0).isEmpty, "No layout before a width exists")
let single = MessageImageLayout.frames(aspectRatios: [2], width: 320)[0]
require(single.size == CGSize(width: 320, height: 160), "A single image keeps its aspect ratio")
let portrait = MessageImageLayout.frames(aspectRatios: [0.6, 1.5, 1], width: 320)
require(portrait[0].height > portrait[1].height && portrait[1].minX == portrait[2].minX, "A leading portrait spans the two stacked neighbors")
for ratios in albums where !ratios.isEmpty {
    let natural = MessageImageLayout.frames(aspectRatios: ratios, width: 320)
    let limited = MessageImageLayout.frames(aspectRatios: ratios, width: 320, maximumHeight: 120)
    require(limited.count == ratios.count, "Height limits retain every attachment")
    require(limited.allSatisfy { $0.maxX <= 320.0001 && $0.maxY <= 120.0001 }, "The whole album fits its width and height limits")
    for (original, fitted) in zip(natural, limited) {
        require(abs(original.width / original.height - fitted.width / fitted.height) < 0.0001, "Fitting preserves tile proportions")
    }
}

print("ok: image album geometry (empty, single, 2–20 images, invalid ratios and narrow widths)")
