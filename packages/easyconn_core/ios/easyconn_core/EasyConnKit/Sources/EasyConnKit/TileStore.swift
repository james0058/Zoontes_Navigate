import Foundation
import CoreGraphics
import ImageIO

public struct TileKey: Hashable { public let z: Int, x: Int, y: Int }

/// Memory + disk cache of map tiles. `image(for:)` never blocks: it returns nil and starts a download,
/// and calls `onTileLoaded` when something new arrives so the renderer can redraw.
public final class TileStore {
    public typealias Loader = (_ key: TileKey, _ completion: @escaping (Data?) -> Void) -> Void

    public var onTileLoaded: (() -> Void)?
    private let loader: Loader
    private let diskDir: URL?
    private let lock = NSLock()
    private var memory = [TileKey: CGImage]()
    private var order = [TileKey]()
    private var inFlight = Set<TileKey>()
    private var failedAt = [TileKey: Date]()
    private let maxInMemory = 200

    public init(diskDirectory: URL? = nil, loader: @escaping Loader) {
        self.diskDir = diskDirectory
        self.loader = loader
        if let d = diskDirectory { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// Standard `{z}/{x}/{y}` template over URLSession. Mind the tile provider's usage policy
    /// (OpenStreetMap's forbids heavy use; set your own provider/key for real riding).
    public static func urlLoader(template: String, userAgent: String) -> Loader {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: cfg)
        return { key, done in
            let s = template.replacingOccurrences(of: "{z}", with: "\(key.z)")
                .replacingOccurrences(of: "{x}", with: "\(key.x)")
                .replacingOccurrences(of: "{y}", with: "\(key.y)")
            guard let url = URL(string: s) else { done(nil); return }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            session.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                done(ok ? data : nil)
            }.resume()
        }
    }

    /// Memory-only lookup that never starts a download (used to draw a blurry parent tile while the sharp one loads).
    public func peek(_ key: TileKey) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return memory[key]
    }

    public func image(for key: TileKey) -> CGImage? {
        lock.lock()
        if let img = memory[key] { lock.unlock(); return img }
        if inFlight.contains(key) { lock.unlock(); return nil }
        if let t = failedAt[key], Date().timeIntervalSince(t) < 15 { lock.unlock(); return nil }
        inFlight.insert(key)
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let data = readDisk(key), let img = Self.decode(data) { finish(key, img); return }
            loader(key) { [self] data in
                guard let data, let img = Self.decode(data) else { fail(key); return }
                writeDisk(key, data)
                finish(key, img)
            }
        }
        return nil
    }

    private func finish(_ key: TileKey, _ img: CGImage) {
        lock.lock()
        memory[key] = img
        order.append(key)
        if order.count > maxInMemory { memory.removeValue(forKey: order.removeFirst()) }
        inFlight.remove(key)
        lock.unlock()
        onTileLoaded?()
    }

    private func fail(_ key: TileKey) {
        lock.lock(); inFlight.remove(key); failedAt[key] = Date(); lock.unlock()
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Decode now (CPU) instead of lazily at first draw, so rendering never stalls.
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func path(_ k: TileKey) -> URL? { diskDir?.appendingPathComponent("\(k.z)_\(k.x)_\(k.y).tile") }
    private func readDisk(_ k: TileKey) -> Data? { path(k).flatMap { try? Data(contentsOf: $0) } }
    private func writeDisk(_ k: TileKey, _ d: Data) { if let p = path(k) { try? d.write(to: p, options: .atomic) } }
}
