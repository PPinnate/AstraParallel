import Foundation

public enum VMCreation {
    /// Creates a new machine only. Never overwrites or borrows an existing
    /// machine's disk, firmware variables, or TPM identity.
    public static func create(at destination: URL, name: String, diskGiB: Int,
                              cpuCount: Int, memoryMiB: Int, iso: URL,
                              runtimeContents: URL) throws -> VMConfiguration {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (64...1024).contains(diskGiB), (2...16).contains(cpuCount), (4096...32768).contains(memoryMiB),
              iso.isFileURL, fm.isReadableFile(atPath: iso.path) else {
            throw ConfigurationError.invalid("Choose a new VM folder, a readable Windows ARM ISO, and supported VM sizes.")
        }
        let template = runtimeContents.appendingPathComponent("Resources/qemu/edk2-arm-vars.fd")
        guard fm.isReadableFile(atPath: template.path) else {
            throw ConfigurationError.invalid("Astra's fresh firmware template is missing.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".astra-creating-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let disk = temporary.appendingPathComponent("windows.raw")
        guard fm.createFile(atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigurationError.invalid("Could not create the new virtual disk.")
        }
        let handle = try FileHandle(forWritingTo: disk)
        do { try handle.truncate(atOffset: UInt64(diskGiB) * 1024 * 1024 * 1024); try handle.close() }
        catch { try? handle.close(); throw error }
        try fm.copyItem(at: template, to: temporary.appendingPathComponent("efi_vars.fd"))
        // swtpm initializes an empty state store on this machine's first boot.
        try Data().write(to: temporary.appendingPathComponent("tpmdata"))
        let config = VMConfiguration(name: name, cpuCount: cpuCount, memoryMiB: memoryMiB,
                                     installationISO: iso.path, machineUUID: UUID().uuidString)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: temporary.appendingPathComponent("manifest.json"))
        try config.validate(directory: temporary)
        try fm.moveItem(at: temporary, to: destination)
        return config
    }
}
