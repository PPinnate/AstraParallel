import XCTest
import CryptoKit
@testable import AstraCore

final class ConfigurationTests: XCTestCase {
    private func vmDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        for name in ["windows.raw", "efi_vars.fd", "tpmdata"] { try Data([0]).write(to: dir.appendingPathComponent(name)) }
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        return dir
    }
    func testSourceEscapeAndMissingFilesAreRejected() throws {
        let directory = try vmDirectory()
        XCTAssertThrowsError(try VMConfiguration(diskFile: "../../Parallels/disk.raw").validate(directory: directory))
        XCTAssertThrowsError(try VMConfiguration(diskFile: "absent.raw").validate(directory: directory))
        let link = directory.appendingPathComponent("external.raw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try VMConfiguration(diskFile: link.lastPathComponent).validate(directory: directory))
    }
    func testHardwareVirtualizationPersistentTPMAndNoInternetByDefault() throws {
        let directory = try vmDirectory()
        let plan = try LaunchPlan(configuration: VMConfiguration(), directory: directory,
                                  sockets: URL(fileURLWithPath: "/private/tmp/astra-test"), runtimeContents: URL(fileURLWithPath: "/private/tmp/Astra Test.app/Contents"))
        XCTAssertTrue(plan.engineArguments.contains("hvf,ipa-granule-size=0x1000"))
        XCTAssertFalse(plan.engineArguments.joined().contains("tcg"))
        XCTAssertTrue(plan.tpmArguments.contains("--tpm2"))
        XCTAssertTrue(plan.tpmArguments.contains { $0.contains("backend-uri=file://") && $0.contains("tpmdata") })
        XCTAssertTrue(plan.engineArguments.contains("tpm-crb-device,tpmdev=tpm0"))
        XCTAssertFalse(plan.engineArguments.contains("-netdev"))
        XCTAssertFalse(plan.engineArguments.joined().contains("hostfwd"))
        XCTAssertEqual(plan.environment["NPT_BACKEND"], "dxmt")
        XCTAssertNil(plan.environment["D3DMETAL_FRAMEWORK_PATH"])
        XCTAssertFalse(plan.engineArguments.joined().contains("/Applications/UTM.app"))
        XCTAssertFalse(plan.environment.values.joined().contains("/Applications/UTM.app"))
        XCTAssertEqual(plan.environment["NPT_D3D11_LIBRARY_PATH"], "/private/tmp/Astra Test.app/Contents/Frameworks/AstraDXMT.dylib")
    }
    func testPointerMappingHonorsLetterboxingAnd4KCoordinates() {
        let size = CGSize(width: 3840, height: 2160)
        XCTAssertEqual(DisplayGeometry.guestPoint(viewPoint: CGPoint(x: 500, y: 500), viewSize: CGSize(width: 1000, height: 1000), guestSize: size), CGPoint(x: 1920, y: 1080))
        XCTAssertNil(DisplayGeometry.guestPoint(viewPoint: CGPoint(x: 500, y: 20), viewSize: CGSize(width: 1000, height: 1000), guestSize: size))
        XCTAssertNil(DisplayGeometry.guestPoint(viewPoint: .zero, viewSize: .zero, guestSize: size))
    }
    func testPlaybackUsesUSBClassDeviceWithoutChangingExistingPCITopology() throws {
        let plan = try LaunchPlan(configuration: VMConfiguration(), directory: vmDirectory(),
                                  sockets: URL(fileURLWithPath: "/private/tmp/astra-test"), runtimeContents: URL(fileURLWithPath: "/private/tmp/Astra Test.app/Contents"))
        let arguments = plan.engineArguments
        XCTAssertTrue(arguments.contains("spice,id=audio0"))
        XCTAssertTrue(arguments.contains("usb-audio,id=sound0,bus=usb.0,audiodev=audio0,multi=off"))
        XCTAssertFalse(arguments.contains { $0.contains("intel-hda") || $0.contains("hda-output") })
        XCTAssertLessThan(arguments.firstIndex(of: "qemu-xhci,id=usb")!,
                          arguments.firstIndex(of: "usb-audio,id=sound0,bus=usb.0,audiodev=audio0,multi=off")!)
        XCTAssertTrue(arguments.contains("usb-tablet,bus=usb.0"))
        XCTAssertTrue(arguments.contains("usb-mouse,bus=usb.0"))
    }
    func testUTMQcowNVRAMIsNotTreatedAsRawFlash() throws {
        let directory = try vmDirectory()
        try Data([0x51, 0x46, 0x49, 0xfb]).write(to: directory.appendingPathComponent("efi_vars.fd"))
        let plan = try LaunchPlan(configuration: VMConfiguration(), directory: directory,
                                  sockets: URL(fileURLWithPath: "/private/tmp/astra-test"), runtimeContents: URL(fileURLWithPath: "/private/tmp/Astra Test.app/Contents"))
        XCTAssertTrue(plan.engineArguments.contains { $0.hasPrefix("if=pflash,format=qcow2,unit=1,") })
    }
    func testIncompleteAndAlteredRendererPackagesAreRejected() throws {
        let directory = try vmDirectory()
        for name in ["Frameworks", "MacOS", "Resources"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertNil(try BundledGraphicsRenderer.verifiedPackage(in: directory))
        let library = directory.appendingPathComponent("Frameworks/AstraDXMT.dylib")
        let worker = directory.appendingPathComponent("MacOS/AstraRenderServer")
        let bytes = Data("Astra test renderer".utf8)
        try bytes.write(to: library)
        XCTAssertThrowsError(try BundledGraphicsRenderer.verifiedPackage(in: directory))
        try bytes.write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = ["version": "test", "sha256": digest, "worker_sha256": digest]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("Resources/AstraDXMT.json"))
        XCTAssertEqual(try BundledGraphicsRenderer.verifiedPackage(in: directory)?.library, library)
        try Data("changed".utf8).write(to: library)
        XCTAssertThrowsError(try BundledGraphicsRenderer.verifiedPackage(in: directory))
        try bytes.write(to: library)
        try Data("changed worker".utf8).write(to: worker)
        XCTAssertThrowsError(try BundledGraphicsRenderer.verifiedPackage(in: directory))
    }
}
