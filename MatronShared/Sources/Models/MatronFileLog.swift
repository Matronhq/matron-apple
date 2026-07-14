import Foundation

/// Append-only, size-capped diagnostic log file inside the app's data
/// container (`Documents/matron-diag.log`), mirroring the `Logger.diag`
/// and `.breadcrumb` trails.
///
/// Exists because pulling the unified log off a physical iPhone needs
/// root and (in practice) a cable — `log collect` repeatedly refused
/// network pulls during the 2026-07-13 blank-chat hunt — while a
/// Debug-installed app's data container copies over WiFi with plain
/// `xcrun devicectl device copy files … --domain-type appDataContainer`.
/// One command, no sudo, no user involvement:
///
///   xcrun devicectl device copy files --device <id> \
///     --domain-type appDataContainer --domain-identifier chat.matron.app \
///     --source Documents/matron-diag.log --destination /tmp/
///
/// Sizing: 2 MB live file rotated once to `matron-diag.old.log` —
/// bounded at ~4 MB total, several hours of full diag chatter.
///
/// Threading: all file I/O is confined to one utility-QoS serial queue;
/// `append` is fire-and-forget from any thread. The `DateFormatter` and
/// cached `FileHandle` are only touched on that queue.
public enum MatronFileLog {
    private static let queue = DispatchQueue(label: "chat.matron.filelog", qos: .utility)
    private static let maxBytes: UInt64 = 2_000_000

    public static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("matron-diag.log")
    }

    private static var rotatedURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("matron-diag.old.log")
    }

    // Queue-confined state.
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var bytesWritten: UInt64 = 0
    nonisolated(unsafe) private static var wroteSessionHeader = false
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Appends one timestamped line. The timestamp is captured at the
    /// call site (so ordering reflects when events happened, not when
    /// the queue drained); formatting and I/O happen off-thread.
    public static func append(_ message: String) {
        let now = Date()
        queue.async {
            writeLine(stampedLine(message, at: now))
        }
    }

    /// Blocks until all appends issued before this call have hit the
    /// file. Test seam; also usable before a deliberate export.
    public static func _flushForTesting() {
        queue.sync {}
    }

    /// Test seam: close and delete both log files.
    public static func _resetForTesting() {
        queue.sync {
            try? handle?.close()
            handle = nil
            bytesWritten = 0
            wroteSessionHeader = false
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: rotatedURL)
        }
    }

    // MARK: - Queue-confined implementation

    private static func stampedLine(_ message: String, at date: Date) -> String {
        "\(formatter.string(from: date)) \(message)\n"
    }

    private static func writeLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if !wroteSessionHeader {
            wroteSessionHeader = true
            let header = stampedLine(
                "=== session start pid=\(ProcessInfo.processInfo.processIdentifier) ===",
                at: Date()
            )
            if let headerData = header.data(using: .utf8) {
                rawWrite(headerData)
            }
        }
        rawWrite(data)
    }

    private static func rawWrite(_ data: Data) {
        if bytesWritten >= maxBytes {
            rotate()
        }
        if handle == nil {
            openHandle()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += UInt64(data.count)
        } catch {
            // A failed diagnostic write must never take the app down or
            // recurse into logging; drop the handle and let the next
            // append retry from scratch.
            try? handle.close()
            Self.handle = nil
        }
    }

    private static func openHandle() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        bytesWritten = (try? h.seekToEnd()) ?? 0
        handle = h
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: url, to: rotatedURL)
        bytesWritten = 0
    }
}
