import Foundation
import CryptoKit

// Shared on-disk media cache (images here, video/attachment files in Caches/attachments via Attachments),
// kept under 500 MB together. Reading a file bumps its date, so the least recently viewed go first.
// Not per account: these are public media URLs.
enum DiskCache {
    static let limit: Int64 = 500 * 1024 * 1024
    private static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    static let images = root.appendingPathComponent("images")
    static let attachments = root.appendingPathComponent("attachments")
    nonisolated(unsafe) private static var writes = 0

    static func imageFile(for url: URL) -> URL {
        let hash = Insecure.SHA1.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
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
