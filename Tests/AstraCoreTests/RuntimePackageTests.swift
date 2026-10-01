import CryptoKit
import Foundation
import XCTest
@testable import AstraCore

final class RuntimePackageTests: XCTestCase {
    private let required = ["Frameworks/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu",
                            "Frameworks/swtpm.0.framework/Versions/A/swtpm.0",
                            "Resources/qemu/edk2-aarch64-secure-code.fd"]
    private func fixture() throws -> (URL, [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        var hashes = [String: String]()
        for name in required {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data(name.utf8)
            try bytes.write(to: path)
            hashes[name] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        try writeManifest(root, files: hashes)
        return (root, hashes)
    }
    private func writeManifest(_ root: URL, files: [String: String]) throws {
        try JSONSerialization.data(withJSONObject: ["schema": 1, "files": files])
            .write(to: root.appendingPathComponent("Resources/AstraRuntime.json"))
    }
    func testValidRuntimeSurvivesBundleRelocation() throws {
        let (root, _) = try fixture()
        try BundledVirtualizationRuntime.verify(in: root)
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.copyItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try BundledVirtualizationRuntime.verify(in: moved)
    }
    func testMissingCoreAndAlteredFirmwareAreRejected() throws {
        let (root, files) = try fixture()
        var incomplete = files
        incomplete.removeValue(forKey: required[0])
        try writeManifest(root, files: incomplete)
        XCTAssertThrowsError(try BundledVirtualizationRuntime.verify(in: root))
        try writeManifest(root, files: files)
        try Data("tampered firmware".utf8).write(to: root.appendingPathComponent(required[2]))
        XCTAssertThrowsError(try BundledVirtualizationRuntime.verify(in: root))
    }
    func testRuntimeCannotEscapeThroughPathsOrSymlinks() throws {
        let (root, files) = try fixture()
        var escaping = files
        escaping["../external"] = String(repeating: "0", count: 64)
        try writeManifest(root, files: escaping)
        XCTAssertThrowsError(try BundledVirtualizationRuntime.verify(in: root))
        try writeManifest(root, files: files)
        let outside = root.appendingPathExtension("outside")
        try Data(required[0].utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let victim = root.appendingPathComponent(required[0])
        try FileManager.default.removeItem(at: victim)
        try FileManager.default.createSymbolicLink(at: victim, withDestinationURL: outside)
        XCTAssertThrowsError(try BundledVirtualizationRuntime.verify(in: root))
    }
}
