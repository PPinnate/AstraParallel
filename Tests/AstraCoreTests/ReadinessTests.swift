import Foundation
import XCTest
@testable import AstraCore

final class ReadinessTests: XCTestCase {
    func testFocusLossInvalidatesOldQueuedInputAndItsCompletions() {
        let queue = InputEpoch()
        let old = queue.enqueue()!
        for _ in 1..<128 { XCTAssertNotNil(queue.enqueue()) }
        XCTAssertNil(queue.enqueue())
        queue.cancel()
        let current = queue.enqueue()!
        queue.completed(old)
        XCTAssertFalse(queue.isCurrent(old))
        XCTAssertTrue(queue.isCurrent(current))
        XCTAssertEqual(queue.queued, 1)
        queue.completed(current)
        XCTAssertEqual(queue.queued, 0)
    }
    func testModifierSidesAndBalancedRelease() {
        XCTAssertEqual(PCModifierKeys.scanCodes(flags: (1 << 19) | 0x40), [0x138])
        XCTAssertEqual(PCModifierKeys.scanCodes(flags: (1 << 17) | 0x2 | 0x4), [0x2a, 0x36])
        XCTAssertEqual(PCModifierKeys.scanCodes(flags: (1 << 17) | 0x4), [0x36])
        XCTAssertEqual(PCModifierKeys.scanCodes(flags: 1 << 18), [0x1d])
        XCTAssertTrue(PCModifierKeys.scanCodes(flags: 0).isEmpty)
    }
    func testClipboardLimitsRejectBinaryNulAndOversizedText() {
        XCTAssertEqual(ClipboardText.decode(Data("測試\r\nhello 👋".utf8)), "測試\r\nhello 👋")
        XCTAssertNil(ClipboardText.decode(Data([0xff,0xfe])))
        XCTAssertFalse(ClipboardText.valid("before\0after"))
        XCTAssertFalse(ClipboardText.valid(String(repeating: "x", count: ClipboardText.maximumBytes + 1)))
    }
    func testHostResourcesAreCheckedSeparatelyFromVirtualDiskCapacity() {
        let invalid = VMPreflight.assess(cpuCount: 16, memoryMiB: 16384, hostCPUs: 8,
            hostMemory: 16 * 1_073_741_824, availableStorage: 512 * 1_048_576)
        XCTAssertEqual(invalid.blockers.count, 3)
        let warning = VMPreflight.assess(cpuCount: 4, memoryMiB: 4096, hostCPUs: 8,
            hostMemory: 16 * 1_073_741_824, availableStorage: 5 * 1_073_741_824)
        XCTAssertTrue(warning.blockers.isEmpty)
        XCTAssertEqual(warning.warnings.count, 1)
    }
    func testLegacyConfigurationDefaultsToNoClipboardSharing() throws {
        let data = Data(#"{"name":"Legacy","cpuCount":4,"memoryMiB":4096,"diskFile":"windows.raw","firmwareFile":"efi_vars.fd","tpmFile":"tpmdata"}"#.utf8)
        let config = try JSONDecoder().decode(VMConfiguration.self, from: data)
        XCTAssertNil(config.schemaVersion)
        XCTAssertFalse(config.clipboardSharing ?? false)
        var future = config; future.schemaVersion = 99
        XCTAssertThrowsError(try future.validate(directory: FileManager.default.temporaryDirectory)) {
            XCTAssertTrue($0.localizedDescription.contains("newer configuration"))
        }
    }
    func testGracefulWaitDoesNotTerminateAnUnresponsiveChild() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        let exited = await ProcessTermination.waitForExit(process, timeout: 0.05)
        XCTAssertFalse(exited)
        XCTAssertTrue(process.isRunning)
        let stopped = await ProcessTermination.stop(process, grace: 0.2)
        XCTAssertTrue(stopped)
    }
    func testConfirmedStopEscalatesOnlyOwnedUnresponsiveChild() async throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; printf ready; exec /bin/sleep 30"]
        process.standardOutput = pipe
        try process.run()
        XCTAssertEqual(pipe.fileHandleForReading.readData(ofLength: 5), Data("ready".utf8))
        let stopped = await ProcessTermination.stop(process, grace: 0.1, killWait: 2)
        XCTAssertTrue(stopped)
        XCTAssertFalse(process.isRunning)
    }
}
