import Foundation
import XCTest
@testable import AstraCore

final class VMCreationTests: XCTestCase {
    func testNewMachineIsSparseIndependentAndDoesNotOverwriteExistingState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("Portable App.app/Contents")
        let template = runtime.appendingPathComponent("Resources/qemu/edk2-arm-vars.fd")
        try FileManager.default.createDirectory(at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
        let initialVariables = Data(repeating: 0xff, count: 4096)
        try initialVariables.write(to: template)
        let iso = root.appendingPathComponent("Windows ARM.iso")
        try Data("test ISO fixture".utf8).write(to: iso)
        let destination = root.appendingPathComponent("New Windows.astravm")
        let config = try VMCreation.create(at: destination, name: "New Windows", diskGiB: 64,
            cpuCount: 4, memoryMiB: 4096, iso: iso, runtimeContents: runtime)
        try config.validate(directory: destination)
        XCTAssertNotNil(config.machineUUID.flatMap(UUID.init(uuidString:)))
        let disk = destination.appendingPathComponent("windows.raw")
        XCTAssertEqual(try disk.resourceValues(forKeys: [.fileSizeKey]).fileSize, 64 * 1024 * 1024 * 1024)
        XCTAssertLessThan(try disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? Int.max, 1024 * 1024)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("efi_vars.fd")), initialVariables)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("tpmdata")).count, 0)
        let original = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try VMCreation.create(at: destination, name: "Overwrite", diskGiB: 128,
            cpuCount: 4, memoryMiB: 4096, iso: iso, runtimeContents: runtime))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("manifest.json")), original)
        let plan = try LaunchPlan(configuration: config, directory: destination,
            sockets: root.appendingPathComponent("sockets"), runtimeContents: runtime)
        XCTAssertTrue(plan.engineArguments.contains { $0.contains("windows-install-media") && $0.contains("readonly=on") })
        XCTAssertTrue(plan.engineArguments.contains { $0.contains("windows-install-cd") && $0.contains("bootindex=2") })
        XCTAssertTrue(plan.engineArguments.contains("-uuid"))
        XCTAssertFalse(plan.engineArguments.joined().contains("/Applications/UTM.app"))
    }

    func testMissingISOAndFirmwareCannotLeavePartialMachine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Missing.astravm")
        XCTAssertThrowsError(try VMCreation.create(at: destination, name: "Missing", diskGiB: 64,
            cpuCount: 4, memoryMiB: 4096, iso: root.appendingPathComponent("absent.iso"), runtimeContents: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
