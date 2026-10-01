import Foundation

public enum QGAClient {
    public static func ping(socketURL: URL, timeout: TimeInterval = 3) throws {
        _ = try command("guest-ping", socketURL: socketURL, timeout: timeout)
    }
    public static func command(_ name: String, socketURL: URL, arguments: [String: Any]? = nil,
                               timeout: TimeInterval = 5) throws -> [String: Any] {
        try ControlSocket.withConnection(to: socketURL, timeout: timeout) { connection in
            try synchronize(connection)
            return try connection.execute(name, arguments: arguments)
        }
    }
    public static func requestShutdown(socketURL: URL, timeout: TimeInterval = 5) throws {
        try ControlSocket.withConnection(to: socketURL, timeout: timeout) { connection in
            try synchronize(connection)
            _ = try connection.execute("guest-ping")
            // No success reply is sent for this command. Reuse the synchronized
            // connection; transmission is not proof that Windows shut down.
            _ = try connection.execute("guest-shutdown", arguments: ["mode": "powerdown"], wait: false)
        }
    }
    private static func synchronize(_ connection: ControlSocket) throws {
        let token = Int64.random(in: 1...Int64.max)
        try connection.send(Data([0xff]))
        try connection.sendJSON(["execute": "guest-sync-delimited", "arguments": ["id": token]])
        // Discard stale partial JSON until the sentinel and our exact token.
        try connection.discardUntilSentinel()
        while true {
            let reply = try connection.receive(allowSentinel: true)
            if let echoed = reply["return"] as? NSNumber, echoed.int64Value == token { return }
        }
    }
}
