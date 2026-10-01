import AstraCore
import SwiftUI
import UniformTypeIdentifiers

struct NewVirtualMachineView: View {
    @ObservedObject var session: VirtualMachineSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Windows 11"
    @State private var iso: URL?
    @State private var parent: URL?
    @State private var diskGiB = 256
    @State private var memoryGiB = max(4, min(12, Int(ProcessInfo.processInfo.physicalMemory / (3 * 1024 * 1024 * 1024))))
    @State private var cpuCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    @State private var creating = false
    @State private var error: String?

    private var safeName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validName: Bool { !safeName.isEmpty && !safeName.contains("/") && !safeName.contains(":") && safeName != "." && safeName != ".." }
    private var maximumMemoryGiB: Int { max(4, min(32, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) - 2)) }
    private var freeGiB: Int? {
        guard let parent, let values = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let bytes = values.volumeAvailableCapacity else { return nil }
        return bytes / (1024 * 1024 * 1024)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Windows VM").font(.title2.bold())
            Text("Use a Windows 11 ARM64 ISO. Astra includes the VM engine and guest drivers.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                LabeledContent("Windows ISO") {
                    HStack {
                        Text(iso?.lastPathComponent ?? "Not selected").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose ISO…") { chooseISO() }.accessibilityLabel("Choose Windows ISO")
                    }.accessibilityElement(children: .contain)
                }.accessibilityElement(children: .contain)
                LabeledContent("Save in") {
                    HStack {
                        Text(parent?.path ?? "Choose a folder for your VM").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose Folder…") { chooseParent() }.accessibilityLabel("Choose VM save folder")
                    }.accessibilityElement(children: .contain)
                }.accessibilityElement(children: .contain)
                Stepper("Virtual disk: \(diskGiB) GB", value: $diskGiB, in: 64...1024, step: 16)
                Stepper("Memory: \(memoryGiB) GB", value: $memoryGiB, in: 4...maximumMemoryGiB)
                Stepper("CPU cores: \(cpuCount)", value: $cpuCount, in: 2...min(16, max(2, ProcessInfo.processInfo.activeProcessorCount)))
            }
            Text("The disk grows as Windows and games use it. Your VM will be saved as \(safeName.isEmpty ? "Windows 11" : safeName).astravm.")
                .font(.caption).foregroundStyle(.secondary)
            if let freeGiB, freeGiB < 30 {
                Label("Only \(freeGiB) GB is free on this volume. Free more space before installing Windows or games.", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if creating { ProgressView().controlSize(.small); Text("Creating VM…") }
                Button("Create and Start") { create() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(iso == nil || parent == nil || !validName || creating)
            }
        }
        .padding(24).frame(width: 580).disabled(creating)
    }
    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.title = "Choose Windows 11 ARM64 ISO"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { result in if result == .OK { iso = panel.url } }
    }
    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save this VM"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.begin { result in if result == .OK { parent = panel.url } }
    }
    private func create() {
        guard let iso, let parent, validName else { return }
        let assessment = VMPreflight.assess(cpuCount: cpuCount, memoryMiB: memoryGiB * 1024,
            hostCPUs: ProcessInfo.processInfo.activeProcessorCount, hostMemory: ProcessInfo.processInfo.physicalMemory,
            availableStorage: VMPreflight.availableBytes(at: parent))
        guard assessment.blockers.isEmpty else { error = assessment.blockers.joined(separator: "\n"); return }
        creating = true; error = nil
        let destination = parent.appendingPathComponent(safeName + ".astravm", isDirectory: true)
        let name = safeName, disk = diskGiB, cpu = cpuCount, memory = memoryGiB * 1024
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        Task { @MainActor in
            do {
                _ = try await Task.detached {
                    try VMCreation.create(at: destination, name: name, diskGiB: disk,
                                          cpuCount: cpu, memoryMiB: memory, iso: iso, runtimeContents: contents)
                }.value
                try session.adoptVM(destination, installationISO: iso)
                creating = false; dismiss(); session.start()
            } catch { self.error = error.localizedDescription; creating = false }
        }
    }
}
