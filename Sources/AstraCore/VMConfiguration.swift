import Foundation

public struct VMConfiguration: Codable {
    public var schemaVersion: Int?
    public var name: String
    public var cpuCount: Int
    public var memoryMiB: Int
    public var diskFile: String
    public var firmwareFile: String
    public var tpmFile: String
    public var installationISO: String?
    public var machineUUID: String?
    public var clipboardSharing: Bool?

    public init(name: String = "Windows 11 ARM", cpuCount: Int = 8, memoryMiB: Int = 12288,
                diskFile: String = "windows.raw", firmwareFile: String = "efi_vars.fd", tpmFile: String = "tpmdata",
                installationISO: String? = nil, machineUUID: String? = nil) {
        self.schemaVersion = 1
        self.clipboardSharing = false
        self.name = name; self.cpuCount = cpuCount; self.memoryMiB = memoryMiB
        self.diskFile = diskFile; self.firmwareFile = firmwareFile; self.tpmFile = tpmFile
        self.installationISO = installationISO
        self.machineUUID = machineUUID
    }

    public func validate(directory: URL) throws {
        guard schemaVersion == nil || schemaVersion == 1 else {
            throw ConfigurationError.invalid("This VM uses a newer configuration format. Update Astra before opening it.")
        }
        guard (2...16).contains(cpuCount), (4096...32768).contains(memoryMiB) else {
            throw ConfigurationError.invalid("Unsupported CPU or memory allocation.")
        }
        if let machineUUID, UUID(uuidString: machineUUID) == nil {
            throw ConfigurationError.invalid("Invalid VM identity.")
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for name in [diskFile, firmwareFile, tpmFile] {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(",") else {
                throw ConfigurationError.invalid("VM files must be plain filenames inside this VM folder.")
            }
            let file = directory.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
                  FileManager.default.fileExists(atPath: file.path) else {
                throw ConfigurationError.invalid("VM file missing or outside the VM folder: \(name)")
            }
        }
    }
}

public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum DisplayGeometry {
    public static func guestPoint(viewPoint: CGPoint, viewSize: CGSize, guestSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0, guestSize.width > 0, guestSize.height > 0 else { return nil }
        let scale = min(viewSize.width / guestSize.width, viewSize.height / guestSize.height)
        let origin = CGPoint(x: (viewSize.width - guestSize.width * scale) / 2,
                             y: (viewSize.height - guestSize.height * scale) / 2)
        let point = CGPoint(x: (viewPoint.x - origin.x) / scale, y: (viewPoint.y - origin.y) / scale)
        guard point.x >= 0, point.y >= 0, point.x < guestSize.width, point.y < guestSize.height else { return nil }
        return point
    }
}

public struct LaunchPlan {
    public let engineArguments: [String]
    public let tpmArguments: [String]
    public let environment: [String: String]

    public init(configuration c: VMConfiguration, directory: URL, sockets: URL,
                runtimeContents: URL, internet: Bool = false, graphicsLibrary: URL? = nil, renderWorker: URL? = nil) throws {
        try c.validate(directory: directory)
        func optionPath(_ url: URL) -> String { url.path.replacingOccurrences(of: ",", with: ",,") }
        let resources = runtimeContents.appendingPathComponent("Resources/qemu")
        let frameworks = runtimeContents.appendingPathComponent("Frameworks")
        let dxmt = (graphicsLibrary ?? frameworks.appendingPathComponent("AstraDXMT.dylib")).path
        let firmware = directory.appendingPathComponent(c.firmwareFile)
        let firmwareHandle = try FileHandle(forReadingFrom: firmware)
        defer { try? firmwareHandle.close() }
        // UTM stores its 64 MiB NVRAM as QCOW2 even though its suffix is .fd.
        let magic = try firmwareHandle.read(upToCount: 4) ?? Data()
        let firmwareFormat = magic == Data([0x51, 0x46, 0x49, 0xfb]) ? "qcow2" : "raw"
        let tpmSocket = sockets.appendingPathComponent("tpm.sock")
        tpmArguments = ["socket", "--tpm2", "--tpmstate",
                        "backend-uri=file://\(optionPath(directory.appendingPathComponent(c.tpmFile))),mode=0600",
                        "--ctrl", "type=unixio,path=\(optionPath(tpmSocket)),mode=0600,terminate",
                        "--flags", "not-need-init"]
        environment = [
            "ANGLE_DEFAULT_PLATFORM": "metal", "NPT_BACKEND": "dxmt",
            "APP_SANDBOX_GROUP_ID": "group.local.astra",
            "VK_DRIVER_FILES": runtimeContents.appendingPathComponent("Resources/vulkan/icd.d/MoltenVK_icd.json").path,
            "NPT_D3D11_LIBRARY_PATH": dxmt, "NPT_DXGI_LIBRARY_PATH": dxmt,
            "NPT_D3D12_LIBRARY_PATH": dxmt,
            "RENDER_SERVER_EXEC_PATH": (renderWorker ?? runtimeContents.appendingPathComponent("MacOS/AstraRenderServer")).path,
            "VIRGL_LOG_LEVEL": "debug"
        ]
        var args = [
            "-name", "Astra Parallel Windows ARM", "-L", resources.path,
            "-machine", "virt,gic-version=3", "-accel", "hvf,ipa-granule-size=0x1000", "-cpu", "host",
            "-smp", "cpus=\(c.cpuCount),sockets=1,cores=\(c.cpuCount),threads=1", "-m", "\(c.memoryMiB)",
            "-nodefaults", "-vga", "none", "-display", "none",
            "-spice", "unix=on,addr=\(optionPath(sockets.appendingPathComponent("display.sock"))),disable-ticketing=on,image-compression=off,playback-compression=off,streaming-video=off,gl=es",
            "-device", "virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,xres=3840,yres=2160",
            "-audiodev", "spice,id=audio0",
            "-drive", "if=pflash,format=raw,unit=0,file=\(optionPath(resources.appendingPathComponent("edk2-aarch64-secure-code.fd"))),readonly=on",
            "-drive", "if=pflash,format=\(firmwareFormat),unit=1,file=\(optionPath(firmware))",
            "-drive", "if=none,id=disk,format=raw,file=\(optionPath(directory.appendingPathComponent(c.diskFile)))",
            "-device", "nvme,drive=disk,serial=\(c.machineUUID.map { "astra-" + $0.replacingOccurrences(of: "-", with: "").prefix(12) } ?? "astra-lab"),bootindex=1",
            "-chardev", "socket,id=chrtpm,path=\(optionPath(tpmSocket))",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-crb-device,tpmdev=tpm0",
            "-device", "qemu-xhci,id=usb", "-device", "usb-kbd,bus=usb.0",
            "-device", "usb-tablet,bus=usb.0", "-device", "usb-mouse,bus=usb.0",
            // Playback-only USB Audio Class device uses Windows' inbox driver
            // and does not move any of the existing PCI devices to new slots.
            "-device", "usb-audio,id=sound0,bus=usb.0,audiodev=audio0,multi=off",
            "-device", "virtio-serial-pci",
            "-chardev", "spicevmc,id=vdagent,name=vdagent",
            "-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0",
            "-chardev", "socket,id=qga,path=\(optionPath(sockets.appendingPathComponent("guest.sock"))),server=on,wait=off",
            "-device", "virtserialport,chardev=qga,name=org.qemu.guest_agent.0",
            "-qmp", "unix:\(optionPath(sockets.appendingPathComponent("control.sock"))),server=on,wait=off",
            "-rtc", "base=localtime", "-device", "virtio-rng-pci"
        ]
        if internet {
            args += ["-device", "virtio-net-pci,netdev=net0", "-netdev", "user,id=net0"]
        } else { args += ["-nic", "none"] }
        if let machineUUID = c.machineUUID { args += ["-uuid", machineUUID] }
        // Keep the disk first so Windows reboots into the installed OS. The
        // installer is the next boot option while the new disk is still empty.
        if let iso = c.installationISO {
            args += ["-drive", "if=none,id=windows-install-media,media=cdrom,format=raw,readonly=on,file=\(optionPath(URL(fileURLWithPath: iso)))",
                     "-device", "usb-storage,id=windows-install-cd,bus=usb.0,drive=windows-install-media,removable=on,bootindex=2"]
        }
        let tools = runtimeContents.appendingPathComponent("Resources/Astra Guest Tools.iso")
        if FileManager.default.fileExists(atPath: tools.path) {
            args += ["-drive", "if=none,id=astra-tools-media,media=cdrom,format=raw,readonly=on,file=\(optionPath(tools))",
                     "-device", "usb-storage,id=astra-tools-cd,bus=usb.0,drive=astra-tools-media,removable=on"]
        }
        engineArguments = args
    }
}
