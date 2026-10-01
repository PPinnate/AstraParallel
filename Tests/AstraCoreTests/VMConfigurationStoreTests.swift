import Foundation
import XCTest
import Darwin
@testable import AstraCore

final class VMConfigurationStoreTests: XCTestCase {
    func testSettingsPreserveIdentityAndRefuseRunningVM() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfiguration(machineUUID: UUID().uuidString)
        config.clipboardSharing = true
        for file in [config.diskFile, config.firmwareFile, config.tpmFile] { try Data([1,2,3]).write(to: directory.appendingPathComponent(file)) }
        let manifest = directory.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(config).write(to: manifest)
        let changed = try VMConfigurationStore.updateResources(at: directory, name: "Portable", cpuCount: 4, memoryMiB: 8192)
        XCTAssertEqual(changed.machineUUID, config.machineUUID)
        XCTAssertEqual(changed.diskFile, config.diskFile)
        XCTAssertEqual(changed.firmwareFile, config.firmwareFile)
        XCTAssertEqual(changed.tpmFile, config.tpmFile)
        XCTAssertEqual(changed.clipboardSharing, true)
        XCTAssertEqual(changed.name, "Portable")
        XCTAssertEqual(changed.cpuCount, 4)
        let before = try Data(contentsOf: manifest)
        let fd = open(directory.appendingPathComponent(".run.lock").path, O_RDWR)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try VMConfigurationStore.updateResources(at: directory, name: "Unsafe", cpuCount: 2, memoryMiB: 4096))
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        for file in [config.diskFile, config.firmwareFile, config.tpmFile] { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(file)), Data([1,2,3])) }
    }
}
