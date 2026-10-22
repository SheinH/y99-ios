import SwiftUI

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

#if DEBUG
/// Logs whenever a view's horizontal position or width changes (hunting the sideways shake).
struct ShiftProbe: ViewModifier {
    let name: String
    @State private var last: CGRect?

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
            defer { last = f }
            guard let last else { return }
            if abs(f.minX - last.minX) > 0.5 || abs(f.width - last.width) > 0.5 {
                DebugLog.log(String(format: "shift %@: x %.1f -> %.1f, w %.1f -> %.1f (y %.0f)",
                                    name, last.minX, f.minX, last.width, f.width, f.minY))
            }
        }
    }
}
#endif

extension View {
    @ViewBuilder func shiftProbe(_ name: @autoclosure () -> String) -> some View {
        #if DEBUG
        modifier(ShiftProbe(name: name()))
        #else
        self
        #endif
    }
}
