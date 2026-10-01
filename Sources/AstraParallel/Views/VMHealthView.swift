import SwiftUI

struct VMHealthView: View {
    @ObservedObject var session: VirtualMachineSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("VM Status").font(.title2.bold())
            Text(session.machineDirectory == nil ? "No VM selected" : session.machineName).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                row("Session", session.status)
                row("VM engine", session.isRunning ? "Running" : "Stopped")
                row("Display connection", session.displayConnected ? "Connected" : (session.isRunning ? "Not connected" : "Not running"))
                row("Desktop integration", session.guestAgentConnected ? "Connected" : (session.isRunning ? "Guest tools not connected" : "Not running"))
                row("Windows control", session.guestControlHealthy ? "Responding" : (session.isRunning ? "Guest agent not responding" : "Not running"))
                row("Text clipboard", session.clipboardSharing ? "Enabled while Astra is active" : "Off for this VM")
            }
            Text("Windows control and desktop integration are separate services. A Windows installer normally has neither until guest tools are installed.")
                .font(.callout).foregroundStyle(.secondary)
            if let warning = session.storageWarning { Label(warning, systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange) }
            ForEach(session.resourceWarnings, id: \.self) { Text($0).foregroundStyle(.orange) }
            Text(session.detail).font(.callout).textSelection(.enabled)
            Divider()
            Toggle("Share text clipboard with this VM", isOn: Binding(get: { session.clipboardSharing }, set: session.setClipboardSharing))
                .disabled(session.machineDirectory == nil)
            Text("When enabled, copied text can pass between macOS and Windows while Astra is in front. Images and files are not shared. This preference is saved for this VM.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open Logs") { session.revealLogs() }.disabled(session.machineDirectory == nil)
                Button("Check Again") { session.refreshHealth() }.disabled(!session.isRunning)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
    private func row(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}
