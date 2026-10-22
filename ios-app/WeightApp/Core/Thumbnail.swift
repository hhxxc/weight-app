import SwiftUI
import UIKit
import ImageIO

/// 缩略图加载：按目标尺寸解码（ImageIO 下采样），避免把 1280px 原图整张解进内存。
/// 走 URLSession.shared，可复用 URLCache（/uploads 带 immutable 头）。
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "weight.thumbnail", qos: .utility, attributes: .concurrent)

    private init() {
        cache.countLimit = 200
    }

    private func key(_ url: URL, _ size: CGFloat) -> NSString {
        "\(url.absoluteString)|\(Int(size))" as NSString
    }

    func cached(_ url: URL, size: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, size))
    }

    func load(_ url: URL, size: CGFloat, completion: @escaping (UIImage?) -> Void) {
        let k = key(url, size)
        if let hit = cache.object(forKey: k) {
            completion(hit)
            return
        }
        queue.async { [weak self] in
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data,
                      let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let pixels = size * UIScreen.main.scale
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                ]
                var image: UIImage?
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    image = UIImage(cgImage: cg)
                }
                if let img = image {
                    self?.cache.setObject(img, forKey: k)
                }
                DispatchQueue.main.async { completion(image) }
            }.resume()
        }
    }
}

/// 固定尺寸缩略图（列表用）
struct ThumbnailImage: View {
    let url: URL
    var size: CGFloat = 52

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            } else {
                ProgressView().scaleEffect(0.6)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear(perform: load)
    }

    private func load() {
        if let hit = ThumbnailLoader.shared.cached(url, size: size) {
            image = hit
            return
        }
        ThumbnailLoader.shared.load(url, size: size) { img in
            if let img {
                image = img
            } else {
                failed = true
            }
        }
    }
}
