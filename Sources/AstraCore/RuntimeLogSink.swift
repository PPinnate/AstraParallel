import Foundation

/// Retains a bounded log while continuously draining child output.
public final class RuntimeLogSink {
    private let pipe = Pipe()
    public var outputHandle: FileHandle { pipe.fileHandleForWriting }
    private let file: FileHandle
    private let writer = DispatchQueue(label: "local.astra.runtime-log", qos: .utility)
    private let limit: Int
    private let completion = DispatchGroup()
    private var written = 0
    private var discarded = 0
    private var marked = false

    public init(url: URL, limitBytes: Int = 64 * 1024 * 1024) throws {
        guard limitBytes > 0 else { throw ConfigurationError.invalid("Log limit must be positive.") }
        limit = limitBytes
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forWritingTo: url)
        completion.enter()
        pipe.fileHandleForReading.readabilityHandler = { [self] reader in
            let data = reader.availableData
            if data.isEmpty {
                reader.readabilityHandler = nil
                writer.async {
                    if self.discarded > 0 {
                        try? self.file.write(contentsOf: Data("\n[Astra] Discarded \(self.discarded) bytes beyond the log limit.\n".utf8))
                    }
                    try? self.file.close()
                    self.completion.leave()
                }
                try? reader.close()
                return
            }
            writer.async { self.append(data) }
        }
    }

    private func append(_ data: Data) {
        let count = min(data.count, max(0, limit - written))
        if count > 0 { try? file.write(contentsOf: data.prefix(count)); written += count }
        discarded += data.count - count
        if discarded > 0, !marked {
            marked = true
            try? file.write(contentsOf: Data("\n[Astra] \(limit)-byte log limit reached. Further output is drained without retention.\n".utf8))
        }
    }

    public func finish() {
        // After child exit this produces EOF, drains pending bytes, and breaks
        // the reader's lifetime-retaining closure before closing the file.
        try? pipe.fileHandleForWriting.close()
    }

    public func waitUntilFinished(seconds: Double) -> Bool {
        completion.wait(timeout: .now() + seconds) == .success
    }
}
