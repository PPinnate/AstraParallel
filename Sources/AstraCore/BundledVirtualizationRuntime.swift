import CryptoKit
import Foundation

public enum BundledVirtualizationRuntime {
    private struct Manifest: Decodable {
        let schema: Int
        let files: [String: String]
    }

    /// Missing/tampered runtime files must fail before opening the guest disk.
    /// Relative paths also keep a moved app independent of its original location.
    public static func verify(in contents: URL) throws {
        let root = contents.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = root.appendingPathComponent("Resources/AstraRuntime.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let required = ["Frameworks/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu",
                        "Frameworks/swtpm.0.framework/Versions/A/swtpm.0",
                        "Resources/qemu/edk2-aarch64-secure-code.fd"]
        guard manifest.schema == 1, !manifest.files.isEmpty,
              required.allSatisfy({ manifest.files[$0] != nil }) else {
            throw ConfigurationError.invalid("The bundled virtualization runtime is incomplete.")
        }
        for (relative, expected) in manifest.files {
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            let file = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
            guard !relative.hasPrefix("/"), !components.contains(".."), !components.contains("."),
                  !components.contains(""), file.path.hasPrefix(root.path + "/"),
                  expected.count == 64 else {
                throw ConfigurationError.invalid("The bundled runtime contains an invalid file path.")
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else {
                throw ConfigurationError.invalid("The bundled runtime failed its integrity check: \(relative)")
            }
        }
    }
}
