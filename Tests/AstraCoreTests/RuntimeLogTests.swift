import XCTest
@testable import AstraCore

final class RuntimeLogTests: XCTestCase {
    func testTwoSequentialChildProcessesShareTheLogWriter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try RuntimeLogSink(url: url)
        for text in ["first", "second"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
            process.arguments = ["%s\n", text]
            process.standardOutput = log.outputHandle
            process.standardError = log.outputHandle
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        log.finish()
        XCTAssertTrue(log.waitUntilFinished(seconds: 3))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first\nsecond\n")
    }

    func testLogLimitContinuesDrainingAndReportsDiscardedBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try RuntimeLogSink(url: url, limitBytes: 32)
        try log.outputHandle.write(contentsOf: Data(repeating: 65, count: 1000))
        log.finish()
        XCTAssertTrue(log.waitUntilFinished(seconds: 3))
        let output = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(output.hasPrefix(String(repeating: "A", count: 32)))
        XCTAssertTrue(output.contains("Discarded 968 bytes"))
        XCTAssertLessThan(output.utf8.count, 400)
    }
}
