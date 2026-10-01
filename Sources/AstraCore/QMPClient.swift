import Foundation

/// QMP has a greeting and capability handshake; QGA uses a separate sync protocol.
public enum QMPClient {
    public static func command(_ name: String, socketURL: URL, arguments: [String: Any]? = nil,
                               timeout: TimeInterval = 5) throws -> [String: Any] {
        try ControlSocket.withConnection(to: socketURL, timeout: timeout) { connection in
            guard try connection.receive()["QMP"] != nil else {
                throw ConfigurationError.invalid("VM did not send a QMP greeting.")
            }
            _ = try connection.execute("qmp_capabilities")
            return try connection.execute(name, arguments: arguments)
        }
    }
    public static func requestGuestShutdown(socketURL: URL) throws {
        try QGAClient.requestShutdown(socketURL: socketURL)
    }
}
