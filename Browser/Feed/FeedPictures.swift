import ImageIO
import SwiftUI

/// News' pictures, decoded at the size they're shown. A 2700-wide picture in a 68-point
/// slot is 19 MB in memory at full size, and News held about 130 MB of them while open.
nonisolated enum FeedPictures {
    /// Files kept on disk between visits, so scrolling back and reopening doesn't fetch them again.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 100 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    /// NSCache is safe to use from any thread, which its type doesn't say.
    nonisolated(unsafe) private static let decoded: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 40 << 20
        return cache
    }()

    static func dropFromMemory() {
        decoded.removeAllObjects()
    }

    /// `size` in pixels: the picture comes back just large enough to fill it.
    @concurrent static func picture(_ url: URL, filling size: CGSize) async -> UIImage? {
        // In steps, so a slot a pixel different shares a picture.
        let slot = CGSize(width: (size.width / 64).rounded(.up) * 64, height: (size.height / 64).rounded(.up) * 64)
        let key = "\(Int(slot.width))x\(Int(slot.height)) \(url.absoluteString)" as NSString
        if let known = decoded.object(forKey: key) { return known }
        guard let (data, response) = try? await session.data(from: url),
              ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let width = CGFloat(pixelWidth), height = CGFloat(pixelHeight)
        // Filled, so both sides have to reach the slot's; the option asks for the longer side.
        let fill = max(slot.width / width, slot.height / height)
        let longest = min(max(width, height) * fill, max(width, height)).rounded(.up)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longest,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        decoded.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
}

/// A story's picture, filling the space it's given. Nothing until it has arrived.
struct ShownPicture: View {
    let url: URL
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            // Something there from the start: a task on nothing never runs.
            ZStack {
                Color.clear
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .task(id: url) {
                guard proxy.size.width > 0, proxy.size.height > 0 else { return }
                let pixels = CGSize(width: proxy.size.width * scale, height: proxy.size.height * scale)
                if let found = await FeedPictures.picture(url, filling: pixels) { image = found }
            }
        }
    }
}
