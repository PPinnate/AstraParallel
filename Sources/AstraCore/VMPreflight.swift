import Foundation

public struct VMPreflight: Equatable {
    public var blockers: [String] = []
    public var warnings: [String] = []
    public static func assess(cpuCount: Int, memoryMiB: Int, hostCPUs: Int, hostMemory: UInt64,
                              availableStorage: Int64?) -> VMPreflight {
        var result = VMPreflight()
        if cpuCount > hostCPUs { result.blockers.append("This VM requests \(cpuCount) CPU cores, but this Mac has \(hostCPUs).") }
        let requested = UInt64(max(0, memoryMiB)) * 1_048_576
        if requested >= hostMemory {
            result.blockers.append("The VM's memory allocation leaves no memory for macOS. Choose a smaller allocation.")
        } else if requested > hostMemory / 4 * 3 {
            result.warnings.append("This VM uses more than three quarters of this Mac's memory. Other apps may become slow.")
        }
        if let availableStorage {
            if availableStorage < 1_073_741_824 {
                result.blockers.append("Less than 1 GB is available on the VM volume. Free space before starting Windows.")
            } else if availableStorage < 10 * 1_073_741_824 {
                result.warnings.append("Less than 10 GB is available on the VM volume. Sparse disks still need free space as Windows writes data.")
            }
        } else {
            result.warnings.append("Available space on the VM volume could not be checked.")
        }
        return result
    }
    public static func availableBytes(at directory: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let bytes = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return bytes.int64Value
    }
}
