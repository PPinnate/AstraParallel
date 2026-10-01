import Foundation
import Darwin

public enum VMConfigurationStore {
    /// Resource changes require the same exclusive lock used by the VM engine.
    /// Keep UUID, disk, firmware, TPM, ISO and integration policy unchanged.
    public static func updateResources(at directory: URL, name: String, cpuCount: Int,
                                       memoryMiB: Int) throws -> VMConfiguration {
        let lock = open(directory.appendingPathComponent(".run.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ConfigurationError.invalid("Could not lock this VM's configuration.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw ConfigurationError.invalid("This VM is open in another process. Shut it down before changing its resources.")
        }
        defer { flock(lock, LOCK_UN) }
        let manifest = directory.appendingPathComponent("manifest.json")
        var config = try JSONDecoder().decode(VMConfiguration.self, from: Data(contentsOf: manifest))
        try config.validate(directory: directory)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw ConfigurationError.invalid("Use a VM name between 1 and 80 characters.") }
        config.name = trimmed; config.cpuCount = cpuCount; config.memoryMiB = memoryMiB
        try config.validate(directory: directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: manifest, options: .atomic)
        return config
    }
}
