import AstraCore
import SwiftUI

struct VMSettingsView: View {
    @ObservedObject var session: VirtualMachineSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cpus = 2
    @State private var memoryGiB = 4
    @State private var error: String?
    @State private var loaded = false
    private var cpuLimit: Int { min(16, max(2, ProcessInfo.processInfo.activeProcessorCount)) }
    private var memoryLimit: Int { max(4, min(32, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) - 2)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("VM Settings").font(.title2.bold())
            Text("Choose resources for this Mac while Windows is shut down.").foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                Stepper("CPU cores: \(cpus)", value: $cpus, in: 2...cpuLimit)
                Stepper("Memory: \(memoryGiB) GB", value: $memoryGiB, in: 4...memoryLimit)
            }.disabled(!loaded)
            Text("These settings keep this machine's Windows disk, firmware, TPM and identity together.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do { try session.saveResources(name: name, cpuCount: cpus, memoryMiB: memoryGiB * 1024); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                 .disabled(!loaded || session.isRunning || session.isStarting)
            }
        }.padding(24).frame(width: 480)
        .onAppear {
            do {
                let config = try session.selectedConfiguration()
                name = config.name; cpus = min(cpuLimit, config.cpuCount)
                memoryGiB = min(memoryLimit, max(4, config.memoryMiB / 1024)); loaded = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
