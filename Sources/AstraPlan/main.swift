import Foundation
import AstraCore

do {
    guard CommandLine.arguments.count == 3 else {
        throw ConfigurationError.invalid("Usage: AstraPlan WORKSPACE SOCKET_DIRECTORY")
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let directory = root.appendingPathComponent("vm/windows-arm")
    let config = try JSONDecoder().decode(VMConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    let plan = try LaunchPlan(configuration: config, directory: directory,
                              sockets: URL(fileURLWithPath: CommandLine.arguments[2]),
                              runtimeContents: root.appendingPathComponent("dist/Astra Parallel.app/Contents"))
    let record: [String: Any] = ["engine_arguments": plan.engineArguments, "tpm_arguments": plan.tpmArguments,
                               "environment": plan.environment]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
