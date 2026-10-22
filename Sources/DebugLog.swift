import Foundation

// Small on-device log for diagnosing the live connection and read receipts, read off the phone with
// `xcrun devicectl device copy from … Library/Caches/debug.log` (no calls to y99 needed). Capped at ~200 KB.
enum DebugLog {
    private static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "y99.debuglog")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func log(_ line: String) {
        let stamped = "\(fmt.string(from: Date())) \(line)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 200_000 {
                try? FileManager.default.removeItem(at: file)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close()
            } else {
                try? Data(stamped.utf8).write(to: file)
            }
        }
    }
}
