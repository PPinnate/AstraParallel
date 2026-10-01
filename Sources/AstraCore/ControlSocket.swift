import Foundation
import Darwin

/// Serializes transactions per socket. One monotonic deadline covers waiting
/// for ownership, connecting, handshakes, every write and every reply.
final class ControlSocket {
    private final class Gate {
        let semaphore = DispatchSemaphore(value: 1)
        var users = 0
    }
    private static let gateLock = NSLock()
    private static var gates: [String: Gate] = [:]
    private var fd: Int32
    private let deadline: TimeInterval
    private var buffer = Data()
    private let maximumReply = 1_048_576

    static func withConnection<T>(to url: URL, timeout: TimeInterval,
                                  _ body: (ControlSocket) throws -> T) throws -> T {
        guard timeout.isFinite, timeout > 0, timeout <= 120 else {
            throw ConfigurationError.invalid("Invalid control-operation deadline.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let key = url.standardizedFileURL.path
        gateLock.lock()
        let gate = gates[key] ?? Gate()
        gate.users += 1; gates[key] = gate
        gateLock.unlock()
        defer {
            gateLock.lock(); gate.users -= 1
            if gate.users == 0 { gates.removeValue(forKey: key) }
            gateLock.unlock()
        }
        guard gate.semaphore.wait(timeout: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime)) == .success else {
            throw ConfigurationError.invalid("Timed out waiting for the VM control channel.")
        }
        defer { gate.semaphore.signal() }
        let connection = try ControlSocket(url: url, deadline: deadline)
        return try body(connection)
    }
    private init(url: URL, deadline: TimeInterval) throws {
        self.deadline = deadline
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.failure("create VM control socket") }
        // Invalidate the descriptor on failure regardless of initializer cleanup.
        do {
            var noSignal: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Self.failure("configure VM control socket") }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(url.path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw ConfigurationError.invalid("VM control socket path is too long.")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw Self.failure("connect to VM") }
                try wait(POLLOUT)
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { throw Self.failure("check VM connection") }
                guard error == 0 else { throw Self.failure("connect to VM", code: error) }
            }
        } catch { close(fd); fd = -1; throw error }
    }
    deinit { if fd >= 0 { close(fd) } }
    private func checkDeadline() throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw ConfigurationError.invalid("VM control operation timed out.")
        }
    }
    private func wait(_ events: Int32) throws {
        while true {
            try checkDeadline()
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let milliseconds = Int32(max(1, ceil((deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw Self.failure("use VM control socket", code: EBADF) }
                return // read/write supplies the precise error for HUP/ERR.
            }
            if result < 0, errno != EINTR { throw Self.failure("wait for VM control socket") }
        }
    }
    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                try wait(POLLOUT)
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if count > 0 { sent += count }
                else if count < 0, errno == EINTR || errno == EAGAIN { continue }
                else { throw Self.failure("write VM request") }
            }
        }
    }
    func sendJSON(_ object: [String: Any]) throws {
        var request = try JSONSerialization.data(withJSONObject: object)
        guard request.count <= maximumReply else { throw ConfigurationError.invalid("VM control request is too large.") }
        request.append(10); try send(request)
    }
    private func readChunk() throws {
        while true {
            try wait(POLLIN)
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
                guard buffer.count <= maximumReply else { throw ConfigurationError.invalid("VM control reply is too large.") }
                return
            }
            if count == 0 { throw ConfigurationError.invalid("VM control connection closed before a reply.") }
            if errno != EINTR && errno != EAGAIN { throw Self.failure("read VM reply") }
        }
    }
    func discardUntilSentinel() throws {
        while true {
            try checkDeadline()
            if let sentinel = buffer.firstIndex(of: 0xff) {
                buffer.removeSubrange(...sentinel); return
            }
            buffer.removeAll(keepingCapacity: true)
            try readChunk()
        }
    }
    func receive(allowSentinel: Bool = false) throws -> [String: Any] {
        while true {
            try checkDeadline()
            let newline = buffer.firstIndex(of: 10)
            if allowSentinel, let marker = buffer.firstIndex(of: 0xff), newline == nil || marker < newline! {
                buffer.removeSubrange(...marker); continue
            }
            if let newline {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                if line.allSatisfy({ $0 == 13 || $0 == 32 }) { continue }
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ConfigurationError.invalid("Invalid VM control reply.")
                }
                return value
            }
            try readChunk()
        }
    }
    func execute(_ command: String, arguments: [String: Any]? = nil, wait: Bool = true) throws -> [String: Any] {
        let id = UUID().uuidString
        var object: [String: Any] = ["execute": command, "id": id]
        if let arguments { object["arguments"] = arguments }
        try sendJSON(object)
        if !wait { return ["request_sent": true] }
        while true {
            let reply = try receive()
            guard reply["id"] as? String == id else { continue }
            if let error = reply["error"] as? [String: Any] {
                throw ConfigurationError.invalid("VM control: \((error["desc"] as? String ?? "Command failed").prefix(500))")
            }
            guard reply["return"] != nil else { throw ConfigurationError.invalid("VM control response is missing its result.") }
            return reply
        }
    }
    private static func failure(_ operation: String, code: Int32 = errno) -> ConfigurationError {
        .invalid("Could not \(operation): \(String(cString: strerror(code)))")
    }
}
