import SwiftUI

struct ContentView: View {
    @ObservedObject var session: VirtualMachineSession
    @State private var audioControlsPresented = false
    var body: some View {
        VStack(spacing: 0) {
            if let warning = session.storageWarning {
                HStack {
                    Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    Spacer()
                    Button("VM Status…") { session.showHealth = true }
                }.font(.callout).padding(12).background(.orange.opacity(0.12))
            }
            if session.isRunning {
                GuestDisplayView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "desktopcomputer").font(.system(size: 64, weight: .light)).foregroundStyle(.secondary)
                    Text(session.machineDirectory == nil ? "Your Windows VM, on your Mac" : session.machineName).font(.largeTitle.weight(.semibold))
                    Text(session.detail).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                    if session.isStarting { ProgressView(session.status) }
                    if session.machineDirectory != nil {
                        Button("Start Windows") { session.start() }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(session.isStarting)
                    }
                    HStack {
                        Button("New Windows VM…") { session.showNewVMWizard = true }
                        Button("Open Existing VM…") { session.openExistingVM() }
                    }.disabled(session.isStarting)
                    if let directory = session.machineDirectory {
                        Text(directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text("Choose a Windows 11 ARM64 ISO to begin. No UTM installation is required.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !session.isFullScreen {
              Divider()
              HStack {
                Circle().fill(session.isRunning ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(session.status)
                if session.guestSize.width > 0 {
                    Text("Guest \(Int(session.guestSize.width)) × \(Int(session.guestSize.height))").foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.captureError ?? (session.captureMouse ? "Control + Option releases the mouse" : (session.installerAttached ? "Windows installer attached · Press a key if asked to boot from the ISO" : "Capture Mouse for Games enables mouse look · Control + Option releases")))
                    .foregroundStyle(.secondary)
              }.font(.caption).padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
        .frame(minWidth: 850, minHeight: 550)
        .sheet(isPresented: $session.showNewVMWizard) { NewVirtualMachineView(session: session) }
        .sheet(isPresented: $session.showGuestToolsHelp) { GuestToolsView() }
        .sheet(isPresented: $session.showHealth) { VMHealthView(session: session) }
        .sheet(isPresented: $session.showVMSettings) { VMSettingsView(session: session) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("Internet", isOn: $session.internet).disabled(session.isRunning || session.isStarting)
                Picker("Resolution", selection: $session.resolution) {
                    Text("Automatic").tag("Automatic")
                    Text("1920 × 1080").tag("1080p")
                    Text("3840 × 2160").tag("4K")
                }.frame(width: 155)
                .onChange(of: session.resolution) { _, value in
                    if value != "Automatic" { session.requestResolution() }
                }
                Button { audioControlsPresented.toggle() } label: {
                    Label("VM Audio", systemImage: session.effectivePlaybackMuted || session.playbackVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .help("VM volume and mute")
                .popover(isPresented: $audioControlsPresented) { AudioControlsView(session: session) }
                Toggle("Capture Mouse for Games", isOn: $session.captureMouse)
                    .disabled(session.input == nil)
                    .help(session.captureError ?? "Command + Shift + M captures trackpad or mouse movement for games. Control + Option releases it.")
                Menu {
                    Button("VM Status…") { session.showHealth = true }
                    Button("VM Settings…") { session.showVMSettings = true }
                        .disabled(session.machineDirectory == nil || session.isRunning || session.isStarting)
                    Toggle("Share Text Clipboard", isOn: Binding(get: { session.clipboardSharing }, set: session.setClipboardSharing))
                        .disabled(session.machineDirectory == nil)
                    Divider()
                    Button("Install Astra Guest Tools…") { session.attachGuestTools() }
                    Button("Choose Windows ISO…") { session.chooseInstallationISO() }.disabled(session.isRunning || session.isStarting)
                    Button("Eject Windows Installer") { session.ejectInstallationISO() }.disabled(!session.installerAttached)
                    Divider()
                    Button("Power Off…") { session.forceStop() }.disabled(!session.canPowerOff)
                } label: { Label("VM Tools", systemImage: "opticaldisc") }
                .accessibilityLabel("VM Tools")
                .help("Install guest drivers or manage the Windows ISO")
                Button { session.saveScreenshot() } label: { Label("Save Screenshot", systemImage: "camera") }
                    .disabled(session.display == nil)
                Button { session.shutDown() } label: { Label("Shut Down", systemImage: "power") }
                    .disabled(!session.isRunning)
            }
        }
    }
}
