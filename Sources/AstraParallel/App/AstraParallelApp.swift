import SwiftUI

@main
struct AstraParallelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var session = VirtualMachineSession()
    var body: some Scene {
        WindowGroup("Astra Parallel") {
            ContentView(session: session).onAppear {
                delegate.session = session
                session.setApplicationActive(NSApp.isActive)
                delegate.synchronizeWindows()
                if CommandLine.arguments.contains("--start-vm"), !delegate.didAutoStart {
                    delegate.didAutoStart = true
                    session.start()
                }
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle("Capture Mouse for Games", isOn: $session.captureMouse)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(session.input == nil)
                Toggle("Low-Latency Display", isOn: $session.lowLatencyDisplay)
                if session.nativeCursorAvailable { Toggle("Use macOS Cursor", isOn: $session.useNativeCursor) }
            }
            CommandMenu("Audio") {
                Toggle("Mute VM Audio", isOn: $session.playbackMuted)
                Button("Increase VM Volume") { session.playbackVolume = min(1, session.playbackVolume + 0.1) }
                Button("Decrease VM Volume") { session.playbackVolume = max(0, session.playbackVolume - 0.1) }
                Divider()
                Toggle("Mute in Background", isOn: $session.muteAudioInBackground)
            }
            CommandMenu("Virtual Machine") {
                Button("VM Status…") { session.showHealth = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("VM Settings…") { session.showVMSettings = true }
                    .disabled(session.machineDirectory == nil || session.isRunning || session.isStarting)
                Toggle("Share Text Clipboard", isOn: Binding(get: { session.clipboardSharing }, set: session.setClipboardSharing))
                    .disabled(session.machineDirectory == nil)
                Divider()
                Button("Power Off…") { session.forceStop() }.disabled(!session.canPowerOff)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Windows VM…") { session.showNewVMWizard = true }
                    .keyboardShortcut("n").disabled(session.isRunning || session.isStarting)
                Button("Open Existing VM…") { session.openExistingVM() }
                    .keyboardShortcut("o").disabled(session.isRunning || session.isStarting)
                Divider()
                Button("Start Windows") { session.start() }.disabled(session.isRunning || session.isStarting)
                Button("Shut Down Windows") { session.shutDown() }.disabled(!session.isRunning)
                Button("Save Guest Screenshot") { session.saveScreenshot() }.disabled(session.display == nil)
                Button("Install Astra Guest Tools…") { session.attachGuestTools() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var session: VirtualMachineSession?
    var didAutoStart = false
    private var observers: [NSObjectProtocol] = []
    private var fullScreenToolbars: [ObjectIdentifier: Bool] = [:]
    func applicationDidBecomeActive(_ notification: Notification) { session?.setApplicationActive(true) }
    func applicationDidResignActive(_ notification: Notification) { session?.setApplicationActive(false) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for (name, value) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let window = note.object as? NSWindow,
                      window.title == "Astra Parallel" else { return }
                self.synchronize(window, fullScreen: value)
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window.title == "Astra Parallel" else { return }
            self?.synchronize(window)
        })
        synchronizeWindows()
    }
    func synchronizeWindows() {
        for window in NSApp.windows where window.title == "Astra Parallel" { synchronize(window) }
    }
    private func synchronize(_ window: NSWindow, fullScreen: Bool? = nil) {
        let value = fullScreen ?? window.styleMask.contains(.fullScreen)
        let id = ObjectIdentifier(window)
        if value {
            if fullScreenToolbars[id] == nil { fullScreenToolbars[id] = window.toolbar?.isVisible ?? true }
            // Also handle windows restored fullscreen before observers attach.
            // Hiding NSToolbar releases its content-layout inset without changing
            // SwiftUI's toolbar structure or accessibility identity.
            window.toolbar?.isVisible = false
        } else if let visible = fullScreenToolbars.removeValue(forKey: id) {
            window.toolbar?.isVisible = visible
        }
        if session?.isFullScreen != value { session?.isFullScreen = value }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session, session.isRunning || session.isStarting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Windows is still running"
        alert.informativeText = "Shut down Windows before quitting Astra Parallel. This preserves the guest disk and TPM state."
        alert.addButton(withTitle: "Shut Down Windows")
        alert.addButton(withTitle: "Keep Running")
        if alert.runModal() == .alertFirstButtonReturn { session.shutDown() }
        return .terminateCancel
    }
}
