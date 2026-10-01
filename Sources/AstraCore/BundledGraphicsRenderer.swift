import CryptoKit
import Foundation

public enum BundledGraphicsRenderer {
    public struct Package: Sendable {
        public let library: URL
        public let worker: URL
    }

    private struct Manifest: Decodable {
        let version: String
        let sha256: String
        let worker_sha256: String
    }

    /// A partial or altered renderer package must never silently become active.
    public static func verifiedPackage(in contents: URL) throws -> Package? {
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
        let library = frameworks.appendingPathComponent("AstraDXMT.dylib")
        let worker = executables.appendingPathComponent("AstraRenderServer")
        let manifestLocation = contents.appendingPathComponent("Resources/AstraDXMT.json")
        let fm = FileManager.default
        let hasLibrary = fm.fileExists(atPath: library.path)
        let hasManifest = fm.fileExists(atPath: manifestLocation.path)
        let hasWorker = fm.fileExists(atPath: worker.path)
        if !hasLibrary && !hasManifest && !hasWorker { return nil }
        guard hasLibrary && hasManifest && hasWorker, fm.isExecutableFile(atPath: worker.path),
              library.resolvingSymlinksInPath().deletingLastPathComponent().path == frameworks.resolvingSymlinksInPath().path,
              worker.resolvingSymlinksInPath().deletingLastPathComponent().path == executables.resolvingSymlinksInPath().path else {
            throw ConfigurationError.invalid("The bundled graphics renderer package is incomplete.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestLocation))
        let digest = SHA256.hash(data: try Data(contentsOf: library)).map { String(format: "%02x", $0) }.joined()
        let workerDigest = SHA256.hash(data: try Data(contentsOf: worker)).map { String(format: "%02x", $0) }.joined()
        guard !manifest.version.isEmpty, manifest.sha256 == digest, manifest.worker_sha256 == workerDigest else {
            throw ConfigurationError.invalid("The bundled graphics renderer failed its integrity check.")
        }
        return Package(library: library, worker: worker)
    }
}
