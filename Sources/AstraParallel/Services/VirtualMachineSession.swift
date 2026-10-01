import AppKit
import AstraCore
import CocoaSpiceNoUsb
import Combine
import AstraPlatform
import UniformTypeIdentifiers

final class VirtualMachineSession: NSObject, ObservableObject, CSConnectionDelegate {
    enum Phase: String { case stopped = "Stopped", starting = "Starting", running = "Running"
        case shuttingDown = "Shutting down", forceStopping = "Powering off", finalizing = "Finalizing VM state", failed = "Needs attention" }
    @Published private(set) var phase: Phase = .stopped
    @Published var status = "Stopped"
    @Published var showHealth = false
    @Published var showVMSettings = false
    @Published private(set) var displayConnected = false
    @Published private(set) var guestControlHealthy = false
    @Published private(set) var clipboardSharing = false
    @Published private(set) var storageWarning: String?
    @Published private(set) var resourceWarnings: [String] = []
    var canPowerOff: Bool { (engine?.isRunning == true || tpm?.isRunning == true) && phase != .forceStopping && phase != .finalizing }
    private let clipboard = ClipboardBridge()
    private var finalizationTimer: Timer?
    private var healthTimer: Timer?
    private var healthCheckInFlight = false
    private var cleanupInFlight = false
    private func transition(_ value: Phase) { phase = value; status = value.rawValue }
    private func updateClipboard() {
        clipboard.configure(connection: connection, allowed: clipboardSharing && applicationActive && guestAgentConnected && isRunning)
    }
    @Published var detail = "Create or open a Windows virtual machine to get started."
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var guestSize = CGSize.zero
    @Published var display: CSDisplay?
    @Published var input: CSInput?
    @Published var guestAgentConnected = false
    @Published var internet = UserDefaults.standard.object(forKey: "AstraInternetEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(internet, forKey: "AstraInternetEnabled") }
    }
    @Published var captureMouse = false
    @Published var captureError: String?
    @Published var useNativeCursor = UserDefaults.standard.object(forKey: "AstraNativeCursor") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useNativeCursor, forKey: "AstraNativeCursor") }
    }
    @Published var nativeCursorAvailable = false
    @Published var lowLatencyDisplay = true
    @Published var resolution = UserDefaults.standard.string(forKey: "AstraResolution") ?? "Automatic" {
        didSet { UserDefaults.standard.set(resolution, forKey: "AstraResolution") }
    }
    @Published var isFullScreen = false
    @Published var playbackVolume = min(1.0, max(0.0, UserDefaults.standard.object(forKey: "AstraPlaybackVolume") as? Double ?? 1.0)) {
        didSet {
            UserDefaults.standard.set(playbackVolume, forKey: "AstraPlaybackVolume")
            applyPlaybackControls()
        }
    }
    @Published var playbackMuted = UserDefaults.standard.bool(forKey: "AstraPlaybackMuted") {
        didSet {
            UserDefaults.standard.set(playbackMuted, forKey: "AstraPlaybackMuted")
            applyPlaybackControls()
        }
    }
    @Published var muteAudioInBackground = UserDefaults.standard.object(forKey: "AstraMuteAudioInBackground") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(muteAudioInBackground, forKey: "AstraMuteAudioInBackground")
            applyPlaybackControls()
        }
    }
    @Published private(set) var applicationActive = true
    var effectivePlaybackMuted: Bool { playbackMuted || (muteAudioInBackground && !applicationActive) }

    func setApplicationActive(_ active: Bool) {
        applicationActive = active
        applyPlaybackControls()
        updateClipboard()
    }

    private func applyPlaybackControls() {
        connection?.playbackVolume = Float(playbackVolume)
        connection?.playbackMuted = effectivePlaybackMuted
    }

    var playbackStatistics: [String: Any] { connection?.playbackStatistics ?? [:] }

    @Published var machineDirectory: URL?
    @Published var machineName = "Windows 11 ARM"
    @Published var showNewVMWizard = false
    @Published var showGuestToolsHelp = false
    @Published var installerAttached = false
    private var scopedURLs: [URL] = []
    let inputDispatcher = InputDispatcher()
    var evidenceDirectory: URL { (machineDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent("evidence", isDirectory: true) }
    private var selectedVM: URL?
    private var selectedRuntime: URL?
    private var accessBookmarks: [String: String] = [:]
    private var engine: Process?
    private var tpm: Process?
    private var connection: CSConnection?
    private var socketDirectory: URL?
    private var log: RuntimeLogSink?
    private var lockFD: Int32 = -1
    private var generation = UUID()

    override init() {
        super.init()
        restoreApprovedFolders()
    }

    func start() {
        guard !isRunning, !isStarting else { return }
        restoreApprovedFolders()
        guard let vm = selectedVM else { showNewVMWizard = true; return }
        guard selectedRuntime != nil else { status = "Connection unavailable"; return }
        isStarting = true; transition(.starting); storageWarning = nil; resourceWarnings = []
        let token = UUID(); generation = token
        Task { @MainActor [self] in
            do {
                let fm = FileManager.default
                let configuration = try await Task.detached {
                    let config = try JSONDecoder().decode(VMConfiguration.self, from: Data(contentsOf: vm.appendingPathComponent("manifest.json")))
                    try config.validate(directory: vm)
                    return config
                }.value
                guard generation == token else { return }
                let assessment = VMPreflight.assess(cpuCount: configuration.cpuCount, memoryMiB: configuration.memoryMiB,
                    hostCPUs: ProcessInfo.processInfo.activeProcessorCount, hostMemory: ProcessInfo.processInfo.physicalMemory,
                    availableStorage: VMPreflight.availableBytes(at: vm))
                resourceWarnings = assessment.warnings
                if !assessment.blockers.isEmpty { throw ConfigurationError.invalid(assessment.blockers.joined(separator: "\n")) }
                if let iso = configuration.installationISO {
                    guard accessBookmarks["ASTRA_INSTALL_ISO_BOOKMARK"] != nil,
                          FileManager.default.isReadableFile(atPath: iso) else {
                        throw ConfigurationError.invalid("Choose the Windows installation ISO again, or eject it after installation.")
                    }
                }
                lockFD = open(vm.appendingPathComponent(".run.lock").path, O_CREAT | O_RDWR, 0o600)
                guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                    if lockFD >= 0 { close(lockFD); lockFD = -1 }
                    throw ConfigurationError.invalid("This Astra VM is already open in another process.")
                }
                guard let engineURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AstraEngine") else {
                    throw ConfigurationError.invalid("The bundled VM engine is missing.")
                }
                let bookmarks = accessBookmarks
                let runtime = try await Task.detached { try EngineRuntime.temporaryDirectory(engineURL: engineURL, bookmarks: bookmarks) }.value
                guard generation == token else { return }
                // Resolve the app-group URL in this process to acquire its scoped
                // container access; a path returned by a child is not a grant.
                guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.local.astra"),
                      runtime.standardizedFileURL.path.hasPrefix(group.standardizedFileURL.path + "/") else {
                    throw ConfigurationError.invalid("Astra cannot access its shared runtime container.")
                }
                // The engine creates this directory within its own container rights.
                let sockets = runtime
                socketDirectory = sockets
                let online = internet
                let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
                let plan = try await Task.detached {
                    try BundledVirtualizationRuntime.verify(in: contents)
                    let renderer = try BundledGraphicsRenderer.verifiedPackage(in: contents)
                    return try LaunchPlan(configuration: configuration, directory: vm, sockets: sockets,
                                   runtimeContents: contents, internet: online,
                                   graphicsLibrary: renderer?.library, renderWorker: renderer?.worker)
                }.value
                guard generation == token else { return }
                let evidence = evidenceDirectory
                try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let logURL = evidence.appendingPathComponent("runtime-\(stamp)-\(token.uuidString.prefix(6)).log")
                log = try RuntimeLogSink(url: logURL)
                let tpmProcess = Process()
                tpmProcess.executableURL = engineURL
                tpmProcess.arguments = ["--swtpm"] + plan.tpmArguments
                // Passing Pipe itself lets Process close the parent writer after
                // the first launch. Both children need the explicitly owned handle.
                tpmProcess.standardOutput = log?.outputHandle; tpmProcess.standardError = log?.outputHandle
                tpmProcess.environment = ["PATH": "/usr/bin:/bin", "APP_SANDBOX_GROUP_ID": "group.local.astra"].merging(bookmarks) { _, value in value }
                try tpmProcess.run(); tpm = tpmProcess
                try await waitForSocket(sockets.appendingPathComponent("tpm.sock"), process: tpmProcess)
                guard generation == token else { return }
                guard generation == token else { return }
                let process = Process()
                process.executableURL = engineURL
                process.arguments = plan.engineArguments
                process.environment = plan.environment.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a }
                    .merging(bookmarks) { _, value in value }
                process.standardOutput = log?.outputHandle; process.standardError = log?.outputHandle
                process.terminationHandler = { [weak self] finished in
                    DispatchQueue.main.async {
                        guard self?.generation == token else { return }
                        guard let self, self.generation == token else { return }
                        self.finish(exitCode: finished.terminationStatus)
                    }
                }
                try process.run(); engine = process
                isRunning = true
                let runRecord: [String: Any] = ["engine_pid": process.processIdentifier, "tpm_pid": tpmProcess.processIdentifier,
                    "socket_directory": sockets.path, "runtime_log": logURL.path, "backend": "dxmt", "internet": internet,
                    "started_at": stamp, "engine_arguments": plan.engineArguments,
                    "graphics_library": plan.environment["NPT_D3D11_LIBRARY_PATH"] ?? "",
                    "render_worker": plan.environment["RENDER_SERVER_EXEC_PATH"] ?? ""]
                try JSONSerialization.data(withJSONObject: runRecord, options: [.prettyPrinted, .sortedKeys])
                    .write(to: evidence.appendingPathComponent("current-run.json"), options: .atomic)
                try await waitForSocket(sockets.appendingPathComponent("display.sock"), process: process)
                guard generation == token else { return }
                astra_configure_glib_context(CSMain.shared.glibMainContext)
                guard CSMain.shared.spiceStart() || CSMain.shared.running else {
                    throw ConfigurationError.invalid("Could not start the SPICE client.")
                }
                let client = CSConnection(unixSocketFile: sockets.appendingPathComponent("display.sock"))
                client.delegate = self
                client.audioEnabled = true
                connection = client
                client.session.shareClipboard = false
                applyPlaybackControls()
                guard client.connect() else { throw ConfigurationError.invalid("Could not connect the guest display.") }
                isStarting = false; transition(.running)
                startHealthChecks()
                updateClipboard()
                detail = "DXMT / Metal · TPM 2.0 · \(internet ? "Internet enabled" : "Offline")"
            } catch {
                guard generation == token else { return }
                transition(.failed); detail = error.localizedDescription; isStarting = false
                if let engine, engine.isRunning {
                    // Keep ownership and expose Power Off even if display setup
                    // failed. No silent hard cut of an already booting guest.
                    isRunning = true
                    if let socketDirectory {
                        let control = socketDirectory.appendingPathComponent("control.sock")
                        _ = try? await Task.detached { try QMPClient.command("quit", socketURL: control, timeout: 2) }.value
                    }
                } else {
                    await releaseResources(finalPhase: .failed)
                }
            }
        }
    }

    func openExistingVM() {
        guard !isRunning, !isStarting else { return }
        let panel = NSOpenPanel()
        panel.title = "Open an Astra Windows VM"
        panel.message = "Choose an .astravm package or your existing windows-arm folder."
        panel.prompt = "Open VM"
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            do { try self.adoptVM(url) }
            catch { self.status = "Could not open VM"; self.detail = error.localizedDescription }
        }
    }

    func adoptVM(_ url: URL, installationISO: URL? = nil) throws {
        guard !isRunning, !isStarting else { throw ConfigurationError.invalid("Shut down Windows before opening another VM.") }
        let configuration = try JSONDecoder().decode(VMConfiguration.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
        try configuration.validate(directory: url)
        for old in scopedURLs { old.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        accessBookmarks.removeValue(forKey: "ASTRA_VM_BOOKMARK")
        accessBookmarks.removeValue(forKey: "ASTRA_INSTALL_ISO_BOOKMARK")
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        accessBookmarks["ASTRA_VM_BOOKMARK"] = try url.bookmarkData().base64EncodedString()
        selectedVM = url; machineDirectory = url; machineName = configuration.name
        installerAttached = configuration.installationISO != nil
        clipboardSharing = configuration.clipboardSharing ?? false
        rememberFolder(url, key: "AstraVMFolder")
        if let installationISO {
            try grantISO(installationISO)
        } else if let path = configuration.installationISO,
                  let data = UserDefaults.standard.data(forKey: isoBookmarkKey(url)) {
            var stale = false
            if let restored = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale),
               restored.standardizedFileURL.path == path {
                try grantISO(restored)
            }
        }
        transition(.stopped)
        detail = "\(configuration.cpuCount) CPUs · \(configuration.memoryMiB / 1024) GB memory · DirectX / Metal"
    }

    private func isoBookmarkKey(_ vm: URL) -> String { "AstraInstallationISO." + vm.standardizedFileURL.path }

    private func grantISO(_ url: URL) throws {
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        accessBookmarks["ASTRA_INSTALL_ISO_BOOKMARK"] = try url.bookmarkData().base64EncodedString()
        if let selectedVM { rememberFolder(url, key: isoBookmarkKey(selectedVM)) }
    }

    func chooseInstallationISO() {
        guard !isRunning, !isStarting, selectedVM != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Windows 11 ARM installation ISO"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            do {
                try self.grantISO(url)
                try self.updateInstallationISO(url.path)
                self.detail = "Installation ISO: " + url.lastPathComponent
            } catch { self.detail = error.localizedDescription }
        }
    }

    private func updateInstallationISO(_ path: String?) throws {
        guard let selectedVM else { return }
        let manifest = selectedVM.appendingPathComponent("manifest.json")
        var config = try JSONDecoder().decode(VMConfiguration.self, from: Data(contentsOf: manifest))
        config.installationISO = path
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: manifest, options: .atomic)
        installerAttached = path != nil
    }

    func ejectInstallationISO() {
        guard !isStarting, installerAttached else { return }
        Task { @MainActor in
            do {
                if isRunning, let socketDirectory {
                    let socket = socketDirectory.appendingPathComponent("control.sock")
                    _ = try await Task.detached {
                        try QMPClient.command("eject", socketURL: socket, arguments: ["device": "windows-install-media", "force": true])
                    }.value
                }
                try updateInstallationISO(nil)
                accessBookmarks.removeValue(forKey: "ASTRA_INSTALL_ISO_BOOKMARK")
                detail = "Windows installation ISO ejected."
            } catch { detail = error.localizedDescription }
        }
    }

    func attachGuestTools() {
        showGuestToolsHelp = true
        guard isRunning, let socketDirectory else { return }
        let socket = socketDirectory.appendingPathComponent("control.sock")
        let image = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Astra Guest Tools.iso")
        Task { @MainActor in
            do {
                _ = try await Task.detached {
                    try QMPClient.command("blockdev-change-medium", socketURL: socket,
                        arguments: ["device": "astra-tools-media", "filename": image.path, "format": "raw"])
                }.value
                detail = "Astra Guest Tools is available in Windows under This PC."
            } catch { detail = error.localizedDescription }
        }
    }

    private func rememberFolder(_ url: URL, key: String) {
        if let data = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func restoreApprovedFolders() {
        if selectedVM == nil, let data = UserDefaults.standard.data(forKey: "AstraVMFolder") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale) {
                try? adoptVM(url)
            }
        }
        if selectedRuntime == nil {
            do {
                guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.local.astra") else {
                    throw ConfigurationError.invalid("Astra could not prepare its shared connection folder.")
                }
                let runtime = group.appendingPathComponent("Runtime", isDirectory: true)
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                accessBookmarks["ASTRA_RUNTIME_BOOKMARK"] = try runtime.bookmarkData().base64EncodedString()
                selectedRuntime = runtime
            } catch { detail = error.localizedDescription }
        }
    }

    private func waitForSocket(_ url: URL, process: Process) async throws {
        for _ in 0..<100 {
            guard process.isRunning else { throw ConfigurationError.invalid("The VM component exited. See the runtime log.") }
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ConfigurationError.invalid("Timed out waiting for \(url.lastPathComponent). See the runtime log.")
    }

    func shutDown() {
        guard let sockets = socketDirectory, let engine, engine.isRunning,
              phase != .shuttingDown, phase != .forceStopping, phase != .finalizing else { return }
        let token = generation
        transition(.shuttingDown); captureMouse = false
        if let input { inputDispatcher.release(input, buttons: CSInputButton(rawValue: 1 | 2 | 4 | 32 | 64)) }
        Task { @MainActor in
            do {
                try await Task.detached {
                    do { try QGAClient.requestShutdown(socketURL: sockets.appendingPathComponent("guest.sock"), timeout: 3) }
                    catch { _ = try QMPClient.command("system_powerdown", socketURL: sockets.appendingPathComponent("control.sock"), timeout: 3) }
                }.value
                let exited = await ProcessTermination.waitForExit(engine, timeout: 30)
                guard generation == token, phase == .shuttingDown else { return }
                if !exited {
                    transition(.running); status = "Shutdown not completed"
                    detail = "Windows is still running. Save your work and try Shut Down again, or choose Power Off for an unresponsive VM."
                }
            } catch {
                guard generation == token, engine.isRunning, phase == .shuttingDown else { return }
                transition(.running); status = "Shutdown request failed"; detail = error.localizedDescription
            }
        }
    }

    func forceStop() {
        guard canPowerOff else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Power off Windows?"
        alert.informativeText = "This stops the VM immediately. Unsaved work can be lost. Use Shut Down when Windows is responding."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Power Off")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let ownedEngine = engine
        let socket = socketDirectory?.appendingPathComponent("control.sock")
        generation = UUID() // invalidate old startup, health and exit callbacks.
        captureMouse = false; isStarting = true; transition(.forceStopping)
        healthTimer?.invalidate(); healthTimer = nil
        Task { @MainActor in
            if let ownedEngine, ownedEngine.isRunning {
                if let socket {
                    _ = try? await Task.detached { try QMPClient.command("quit", socketURL: socket, timeout: 2) }.value
                }
                if !(await ProcessTermination.waitForExit(ownedEngine, timeout: 1)),
                   !(await ProcessTermination.stop(ownedEngine)) {
                    transition(.failed); status = "VM process has not exited"
                    detail = "The VM lock is still held. Retry Power Off before reopening or moving this machine."
                    return
                }
            }
            await releaseResources(finalPhase: .stopped, forceTPM: true)
        }
    }

    private func finish(exitCode: Int32) {
        guard !cleanupInFlight else { return }
        if exitCode != 0 { detail = "The VM engine exited (\(exitCode)). Open VM Status for its runtime log." }
        Task { @MainActor in await releaseResources(finalPhase: exitCode == 0 ? .stopped : .failed) }
    }

    private func releaseResources(finalPhase: Phase, forceTPM: Bool = false) async {
        guard !cleanupInFlight, engine?.isRunning != true else { return }
        cleanupInFlight = true
        defer { cleanupInFlight = false }
        finalizationTimer?.invalidate(); finalizationTimer = nil
        healthTimer?.invalidate(); healthTimer = nil
        captureMouse = false; isRunning = false; isStarting = true
        transition(.finalizing)
        clipboard.configure(connection: nil, allowed: false)
        connection?.disconnect(); connection = nil
        display = nil; input = nil; guestSize = .zero
        guestAgentConnected = false; guestControlHealthy = false; displayConnected = false
        if let tpm, tpm.isRunning {
            tpm.terminate()
            var stopped = await ProcessTermination.waitForExit(tpm, timeout: 3)
            if !stopped, forceTPM { stopped = await ProcessTermination.stop(tpm, grace: 1) }
            guard stopped else {
                transition(.failed); status = "TPM is still finalizing"
                detail = "The VM lock remains held while TPM state is being written. Use Power Off only if it remains unresponsive."
                let token = generation
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak tpm] timer in
                    guard let self, self.generation == token else { timer.invalidate(); return }
                    guard tpm?.isRunning != true else { return }
                    timer.invalidate()
                    Task { @MainActor in
                        guard self.generation == token else { return }
                        await self.releaseResources(finalPhase: finalPhase)
                    }
                }
                finalizationTimer = timer; RunLoop.main.add(timer, forMode: .common)
                return
            }
        }
        engine = nil; tpm = nil; socketDirectory = nil
        log?.finish(); log = nil
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        isStarting = false; transition(finalPhase)
    }

    func selectedConfiguration() throws -> VMConfiguration {
        guard let selectedVM else { throw ConfigurationError.invalid("Choose a VM first.") }
        return try JSONDecoder().decode(VMConfiguration.self, from: Data(contentsOf: selectedVM.appendingPathComponent("manifest.json")))
    }

    func saveResources(name: String, cpuCount: Int, memoryMiB: Int) throws {
        guard !isRunning, !isStarting, let selectedVM else {
            throw ConfigurationError.invalid("Shut down Windows before changing its resources.")
        }
        let assessment = VMPreflight.assess(cpuCount: cpuCount, memoryMiB: memoryMiB,
            hostCPUs: ProcessInfo.processInfo.activeProcessorCount, hostMemory: ProcessInfo.processInfo.physicalMemory,
            availableStorage: nil)
        guard assessment.blockers.isEmpty else { throw ConfigurationError.invalid(assessment.blockers.joined(separator: "\n")) }
        let config = try VMConfigurationStore.updateResources(at: selectedVM, name: name, cpuCount: cpuCount, memoryMiB: memoryMiB)
        machineName = config.name
        detail = "\(config.cpuCount) CPUs · \(config.memoryMiB / 1024) GB memory · Settings saved"
    }

    func setClipboardSharing(_ allowed: Bool) {
        guard let selectedVM else { return }
        do {
            let manifest = selectedVM.appendingPathComponent("manifest.json")
            var config = try JSONDecoder().decode(VMConfiguration.self, from: Data(contentsOf: manifest))
            config.clipboardSharing = allowed
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: manifest, options: .atomic)
            clipboardSharing = allowed; updateClipboard()
        } catch { detail = "Could not save clipboard preference: " + error.localizedDescription }
    }

    func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([evidenceDirectory])
    }

    private func startHealthChecks() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refreshHealth() }
        healthTimer = timer; RunLoop.main.add(timer, forMode: .common)
        refreshHealth()
    }

    func refreshHealth() {
        guard !healthCheckInFlight, isRunning, phase == .running, let socketDirectory else { return }
        let token = generation
        let socket = socketDirectory.appendingPathComponent("guest.sock")
        healthCheckInFlight = true
        if let selectedVM, let bytes = VMPreflight.availableBytes(at: selectedVM) {
            storageWarning = bytes < 10 * 1_073_741_824
                ? "Only \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) remains on the VM volume. Free space to avoid failed Windows writes." : nil
        }
        Task { @MainActor in
            let healthy = await Task.detached { (try? QGAClient.ping(socketURL: socket, timeout: 2)) != nil }.value
            healthCheckInFlight = false
            guard generation == token, isRunning else { return }
            guestControlHealthy = healthy
        }
    }

    func requestResolution(_ size: CGSize? = nil) {
        guard let display else { return }
        let desired = size ?? (resolution == "4K" ? CGSize(width: 3840, height: 2160) : CGSize(width: 1920, height: 1080))
        display.requestResolution(CGRect(origin: .zero, size: desired))
    }

    func saveScreenshot() {
        guard let display else { return }
        let size = display.displaySize
        let name = "guest-\(Int(size.width))x\(Int(size.height))-\(UUID().uuidString.prefix(8)).png"
        let url = evidenceDirectory.appendingPathComponent(name)
        display.screenshot { [weak self] screenshot in
            guard let screenshot else { return }
            screenshot.write(to: url, atomically: true)
            DispatchQueue.main.async { self?.detail = "Screenshot saved: \(name)" }
        }
    }

    func spiceConnected(_ connection: CSConnection) {
        DispatchQueue.main.async {
            guard self.connection === connection else { return }
            self.displayConnected = true
            if self.phase == .running { self.status = self.phase.rawValue }
        }
    }
    func spiceDisconnected(_ connection: CSConnection) {
        DispatchQueue.main.async {
            guard self.connection === connection else { return }
            self.displayConnected = false; self.captureMouse = false
            self.guestAgentConnected = false; self.updateClipboard()
            if self.isRunning, self.phase == .running { self.status = "Display disconnected" }
        }
    }
    func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        DispatchQueue.main.async {
            guard self.connection === connection else { return }
            self.input = input
            self.inputDispatcher.setMouseMode(input, relative: false)
        }
    }
    func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        DispatchQueue.main.async {
            guard self.connection === connection else { return }
            self.captureMouse = false; self.input = nil
        }
    }
    func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        DispatchQueue.main.async {
            guard self.connection === connection, self.phase != .finalizing, self.phase != .forceStopping else { return }
            self.detail = message ?? "SPICE connection error"
        }
    }
    func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        DispatchQueue.main.async {
            guard self.connection === connection else { return }
            if display.isPrimaryDisplay {
                self.display = display; self.guestSize = display.displaySize
                if self.guestAgentConnected, self.resolution != "Automatic" { self.requestResolution() }
            }
        }
    }
    func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        DispatchQueue.main.async { if self.connection === connection, display.isPrimaryDisplay { self.guestSize = display.displaySize } }
    }
    func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        DispatchQueue.main.async { if self.connection === connection, self.display === display { self.display = nil; self.guestSize = .zero } }
    }
    func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        DispatchQueue.main.async {
            guard self.connection === connection else { return }
            self.guestAgentConnected = true
            self.updateClipboard()
            if self.resolution != "Automatic" { self.requestResolution() }
        }
    }
    func spiceAgentDisconnected(_ connection: CSConnection) {
        DispatchQueue.main.async {
            guard self.connection === connection else { return }
            self.guestAgentConnected = false; self.updateClipboard()
        }
    }
    func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
}
