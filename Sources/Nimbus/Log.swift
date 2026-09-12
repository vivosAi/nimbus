import Foundation

/// Logging that goes both to the unified log and to a plain file.
///
/// `log show` has to scan the whole system archive, which takes long enough to
/// make it useless for a tight edit-run-look loop. A flat file is instant.
enum Log {

    static let fileURL = URL(fileURLWithPath: "/tmp/nimbus.log")

    private static let queue = DispatchQueue(label: "io.github.vivosai.nimbus.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        NSLog("[Nimbus] \(message)")
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Called once at launch so each run starts with a clean file.
    static func startNewSession() {
        try? "=== Nimbus started \(Date()) ===\n".write(to: fileURL,
                                                           atomically: true,
                                                           encoding: .utf8)
    }
}
