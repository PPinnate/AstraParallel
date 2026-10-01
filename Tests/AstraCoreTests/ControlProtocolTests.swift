import Foundation
import XCTest
import Darwin
@testable import AstraCore

final class ControlProtocolTests: XCTestCase {
    func testQMPFragmentsEventsAndWrongIDsDoNotConfuseReplies() throws {
        let server = try SocketFixture { peer in
            try peer.sendJSON(["QMP": ["version": [:]]], fragmented: true)
            let capabilities = try peer.receive()
            XCTAssertEqual(capabilities["execute"] as? String, "qmp_capabilities")
            try peer.sendJSON(["event": "RESUME"])
            try peer.sendJSON(["return": [:], "id": capabilities["id"]!])
            let command = try peer.receive()
            XCTAssertEqual(command["execute"] as? String, "query-status")
            try peer.sendJSON(["return": ["status": "wrong"], "id": "old-client"])
            try peer.sendJSON(["return": ["status": "running"], "id": command["id"]!], fragmented: true)
        }
        let result = try QMPClient.command("query-status", socketURL: server.url)
        XCTAssertEqual((result["return"] as? [String: String])?["status"], "running")
        try server.finish()
    }

    func testQGAResynchronizesAndShutdownReusesTheConnection() throws {
        let server = try SocketFixture { peer in
            let sync = try peer.receive(expectSentinel: true)
            XCTAssertEqual(sync["execute"] as? String, "guest-sync-delimited")
            let token = (sync["arguments"] as! [String: Any])["id"]!
            try peer.send(Data("stale incomplete JSON {\n".utf8))
            try peer.send(Data([0xff]))
            try peer.sendJSON(["return": 0])
            try peer.sendJSON(["return": token], fragmented: true)
            let ping = try peer.receive()
            XCTAssertEqual(ping["execute"] as? String, "guest-ping")
            try peer.sendJSON(["return": [:], "id": ping["id"]!])
            let shutdown = try peer.receive()
            XCTAssertEqual(shutdown["execute"] as? String, "guest-shutdown")
            XCTAssertEqual((shutdown["arguments"] as? [String:String])?["mode"], "powerdown")
            // No reply is correct for successful guest-shutdown.
        }
        try QGAClient.requestShutdown(socketURL: server.url, timeout: 2)
        try server.finish()
    }

    func testOperationDeadlineIncludesPartialReplyDrip() throws {
        let server = try SocketFixture { peer in
            for _ in 0..<8 {
                try? peer.send(Data([32]))
                Thread.sleep(forTimeInterval: 0.04)
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try QMPClient.command("query-status", socketURL: server.url, timeout: 0.15))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.6)
        try server.finish()
    }

    func testMissingGuestSentinelCannotBeMistakenForHealthyAgent() throws {
        let server = try SocketFixture { peer in
            let sync = try peer.receive(expectSentinel: true)
            try peer.sendJSON(["return": (sync["arguments"] as! [String:Any])["id"]!])
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertThrowsError(try QGAClient.ping(socketURL: server.url, timeout: 0.1))
        try server.finish()
    }

    func testExplicitErrorIsReported() throws {
        let server = try SocketFixture { peer in
            try peer.sendJSON(["QMP": [:]])
            let capabilities = try peer.receive()
            try peer.sendJSON(["return": [:], "id": capabilities["id"]!])
            let command = try peer.receive()
            try peer.sendJSON(["error": ["class":"GenericError","desc":"not available"],"id":command["id"]!])
        }
        XCTAssertThrowsError(try QMPClient.command("query-status", socketURL: server.url)) {
            XCTAssertTrue($0.localizedDescription.contains("not available"))
        }
        try server.finish()
    }

    func testSameSocketOwnershipWaitIsBounded() throws {
        let server = try SocketFixture { _ in Thread.sleep(forTimeInterval: 0.4) }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? QMPClient.command("query-status", socketURL: server.url, timeout: 0.3)
            finished.signal()
        }
        XCTAssertEqual(server.accepted.wait(timeout: .now() + 1), .success)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try QMPClient.command("query-status", socketURL: server.url, timeout: 0.08))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.25)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        try server.finish()
    }
}

private final class SocketFixture {
    let url = URL(fileURLWithPath: "/private/tmp/astra-protocol-\(UUID().uuidString).sock")
    let accepted = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var fd: Int32
    private var error: Error?
    init(_ body: @escaping (Peer) throws -> Void) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(url.path.utf8CString).map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { let code = errno; close(fd); fd = -1; throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        DispatchQueue.global().async {
            var descriptor = pollfd(fd: self.fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 3000) > 0 else { self.finished.signal(); return }
            let client = accept(self.fd, nil, nil)
            guard client >= 0 else { self.finished.signal(); return }
            self.accepted.signal()
            defer { close(client); self.finished.signal() }
            do { try body(Peer(fd: client)) } catch { self.error = error }
        }
    }
    func finish() throws {
        XCTAssertEqual(finished.wait(timeout: .now() + 4), .success)
        if let error { throw error }
    }
    deinit { if fd >= 0 { close(fd) }; _ = Darwin.unlink(url.path) }
    final class Peer {
        let fd: Int32
        init(fd: Int32) {
            self.fd = fd
            var timeout = timeval(tv_sec: 2, tv_usec: 0), one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        func send(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                    guard count > 0 else { throw POSIXError(.EPIPE) }; sent += count
                }
            }
        }
        func sendJSON(_ object: [String: Any], fragmented: Bool = false) throws {
            var bytes = try JSONSerialization.data(withJSONObject: object); bytes.append(contentsOf: [13,10])
            if fragmented { for byte in bytes { try send(Data([byte])) } }
            else { try send(bytes) }
        }
        func receive(expectSentinel: Bool = false) throws -> [String: Any] {
            var data = Data(), byte: UInt8 = 0
            if expectSentinel { guard read(fd, &byte, 1) == 1, byte == 0xff else { throw POSIXError(.EPROTO) } }
            while true {
                guard read(fd, &byte, 1) == 1 else { throw POSIXError(.EIO) }
                if byte == 10 { break }; data.append(byte)
            }
            return try JSONSerialization.jsonObject(with: data) as! [String:Any]
        }
    }
}
