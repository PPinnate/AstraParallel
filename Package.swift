// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Runtime libraries live in the app. The build can link against a staging
// bundle or a previously packaged standalone app, without an installed UTM.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let frameworks = ProcessInfo.processInfo.environment["ASTRA_BUILD_FRAMEWORKS"]
    ?? root + "/dist/Astra Parallel.app/Contents/Frameworks"
let package = Package(
    name: "AstraParallel",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AstraParallel", targets: ["AstraParallel"]),
               .executable(name: "AstraPlan", targets: ["AstraPlan"])],
    dependencies: [.package(path: "vendor/CocoaSpice")],
    targets: [
        .target(name: "AstraCore"),
        .target(name: "AstraPlatform", sources: ["GPoll.c"]),
        .executableTarget(name: "AstraPlan", dependencies: ["AstraCore"]),
        .executableTarget(
            name: "AstraParallel",
            dependencies: ["AstraCore", "AstraPlatform", .product(name: "CocoaSpiceNoUsb", package: "CocoaSpice")],
            linkerSettings: [
                .unsafeFlags(["-F", frameworks, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("spice-client-glib-2.0.8"),
                .linkedFramework("glib-2.0.0"), .linkedFramework("gobject-2.0.0"),
                .linkedFramework("gio-2.0.0"), .linkedFramework("gstreamer-1.0.0"),
                .linkedFramework("gstapp-1.0.0"), .linkedFramework("gstbase-1.0.0"),
                .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                .linkedFramework("IOSurface"), .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox")
            ]),
        .testTarget(name: "AstraCoreTests", dependencies: ["AstraCore"])
    ]
)
