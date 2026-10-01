import Foundation

public enum EngineRuntime {
    public static func temporaryDirectory(engineURL: URL, bookmarks: [String: String] = [:]) throws -> URL {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = engineURL
        process.arguments = ["--astra-new-runtime"]
        process.environment = ["PATH": "/usr/bin:/bin"].merging(bookmarks) { _, value in value }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); throw ConfigurationError.invalid("The engine sandbox did not initialize in time.") }
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ConfigurationError.invalid("The engine sandbox could not initialize. \(message.prefix(1000))")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let path = dictionary["temporary_directory"], path.hasPrefix("/") else {
            throw ConfigurationError.invalid("The engine did not report a temporary directory.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
