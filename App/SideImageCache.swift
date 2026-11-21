import ImageIO
import SwiftUI

@MainActor @Observable
final class SideImageCache {
    nonisolated static let maxPixel = 2048
    static let limit = 8

    private(set) var images: [Int: UIImage] = [:]
    private var recency: [Int] = []
    @ObservationIgnored private var loading: Set<Int> = []

    func image(_ side: Int) -> UIImage? { images[side] }

    @discardableResult
    func load(side: Int, url: URL) async -> Bool {
        if images[side] != nil { return true }
        guard loading.insert(side).inserted else { return true }
        defer { loading.remove(side) }
        let decoded = await Task.detached(priority: .userInitiated) { Self.downsampled(url) }.value
        guard let decoded else { return false }
        images[side] = decoded
        recency.removeAll { $0 == side }
        recency.append(side)
        while recency.count > Self.limit {
            images[recency.removeFirst()] = nil
        }
        return true
    }

    func touch(_ side: Int) {
        guard images[side] != nil else { return }
        recency.removeAll { $0 == side }
        recency.append(side)
    }

    nonisolated static func downsampled(_ url: URL, maxPixel: Int = 2048) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        // The thumbnail call can enlarge small images, so never ask for more than the photo has.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let longEdge = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? maxPixel,
                           properties?[kCGImagePropertyPixelHeight] as? Int ?? maxPixel)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, longEdge),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
