import AppKit
import CryptoKit
import ImageIO
import ThreeMFKit
import ThreeMFRendering

/// Provides list thumbnails: the image embedded by the slicer if there is one, otherwise an
/// off-screen SceneKit render. Results are cached in memory and on disk (~/Library/Caches).
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    static let pixelSize: CGFloat = 256
    /// Files larger than this are not rendered just for a thumbnail.
    static let maxRenderFileSize: Int64 = 150 * 1024 * 1024

    private let memory = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var failedKeys = Set<String>()
    private let diskDirectory: URL?

    private let extractQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "thumbnails.extract"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()

    private let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "thumbnails.render"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        diskDirectory = caches?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ThreeMFViewer", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        memory.countLimit = 800
        if let diskDirectory {
            try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        }
    }

    func cachedImage(for file: ModelFileItem) -> NSImage? {
        memory.object(forKey: file.cacheKey as NSString)
    }

    func thumbnail(for file: ModelFileItem) async -> NSImage? {
        let key = file.cacheKey
        if let image = memory.object(forKey: key as NSString) { return image }
        if hasFailed(key) { return nil }

        let url = file.url
        let diskFile = diskDirectory?.appendingPathComponent(Self.hash(key) + ".png")

        // 1. Disk cache or the preview embedded in the 3MF.
        var image: NSImage? = await perform(on: extractQueue) {
            if let diskFile, let data = try? Data(contentsOf: diskFile), let cached = NSImage(data: data) {
                return cached
            }
            guard let data = try? ThreeMFReader.thumbnailData(url: url),
                  let embedded = Self.downscaled(data) else { return nil }
            Self.write(embedded, to: diskFile)
            return embedded
        }

        // 2. Render the model ourselves.
        if image == nil, !Task.isCancelled, file.size <= Self.maxRenderFileSize {
            image = await perform(on: renderQueue) {
                guard let model = try? ThreeMFReader.load(url: url),
                      let rendered = ThumbnailRenderer.render(model: model, pixelSize: Self.pixelSize) else { return nil }
                Self.write(rendered, to: diskFile)
                return rendered
            }
        }

        if let image {
            memory.setObject(image, forKey: key as NSString)
        } else if !Task.isCancelled {
            markFailed(key)
        }
        return image
    }

    func clearDiskCache() {
        guard let diskDirectory else { return }
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        memory.removeAllObjects()
        lock.lock()
        failedKeys.removeAll()
        lock.unlock()
    }

    // MARK: - Helpers

    private func hasFailed(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failedKeys.contains(key)
    }

    private func markFailed(_ key: String) {
        lock.lock()
        failedKeys.insert(key)
        lock.unlock()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    /// Runs `work` on an operation queue; cancelling the calling task cancels queued work.
    private func perform<T>(on queue: OperationQueue, _ work: @escaping () -> T?) async -> T? {
        let box = ResultBox<T>()
        let operation = BlockOperation { box.value = work() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                operation.completionBlock = { continuation.resume(returning: box.value) }
                queue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    static func downscaled(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func write(_ image: NSImage, to url: URL?) {
        guard let url, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
