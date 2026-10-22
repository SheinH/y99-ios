import Foundation
import CryptoKit
import ImageIO

// Shared on-disk media cache (images here, video/attachment files in Caches/attachments via Attachments),
// kept under 500 MB together. Reading a file bumps its date, so the least recently viewed go first.
// Not per account: these are public media URLs.
enum DiskCache {
    static let limit: Int64 = 500 * 1024 * 1024
    private static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    static let images = root.appendingPathComponent("images")
    static let attachments = root.appendingPathComponent("attachments")
    nonisolated(unsafe) private static var writes = 0

    /// Any stable key, e.g. "msg:<message id>:full" (photo addresses change with the image server and
    /// their encrypted links, so photos in chats are filed by message id).
    static func imageFile(key: String) -> URL {
        let hash = Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return images.appendingPathComponent(hash)
    }

    static func read(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        touch(file)
        return data
    }

    static func write(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        didWrite()
    }

    static func has(_ key: String) -> Bool { FileManager.default.fileExists(atPath: imageFile(key: key).path) }

    /// The image filed under `key`, else downloaded from `url` (y99's image hosts 403 without the Referer)
    /// and filed under it. `url` may be nil when only the cached copy can be used.
    static func image(key: String, url: URL?) async -> Data? {
        if case .image(let data) = await fetch(key: key, url: url) { return data }
        return nil
    }

    /// `gone`: y99 deleted the file (404 "EXPIRED OR DELETED"; photos don't last forever there), so only a
    /// copy saved here earlier can show it.
    enum Fetched { case image(Data), gone, failed }

    static func fetch(key: String, url: URL?) async -> Fetched {
        let file = imageFile(key: key)
        if let data = await Task.detached(operation: { read(file) }).value { return .image(data) }
        guard let url else { return .failed }
        var req = URLRequest(url: url)
        req.setValue("https://meetyou.me/", forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return .failed }
        let status = (resp as? HTTPURLResponse)?.statusCode
        if status == 404 { return .gone }
        guard status == 200, isImage(data) else { return .failed }
        Task.detached(priority: .utility) { write(data, to: file) }
        return .image(data)
    }

    /// An error page served with a 200 must never be filed as the picture.
    static func isImage(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(src) != nil && CGImageSourceGetCount(src) > 0
    }

    static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Call after adding a file anywhere in the cache; trims every 20 additions.
    static func didWrite() {
        writes += 1
        if writes % 20 == 0 { Task.detached(priority: .utility) { trim() } }
    }

    /// Deletes least-recently-used files until both folders together fit the limit.
    static func trim() {
        // One-time: the first image cache was keyed by address, which broke offline; start it over.
        if !UserDefaults.standard.bool(forKey: "imageCacheV2") {
            try? FileManager.default.removeItem(at: images)
            UserDefaults.standard.set(true, forKey: "imageCacheV2")
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var files: [(url: URL, date: Date, size: Int64)] = []
        for dir in [images, attachments] {
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                files.append((url, v.contentModificationDate ?? .distantPast, Int64(v.fileSize ?? 0)))
            }
        }
        var total = files.reduce(0) { $0 + $1.size }
        for f in files.sorted(by: { $0.date < $1.date }) where total > limit {
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
        }
    }
}
