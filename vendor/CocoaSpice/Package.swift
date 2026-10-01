// swift-tools-version:5.5
// Modified for Astra Parallel; see repository docs/upstream-notices.md.
// Existing upstream copyright notices and the component license are retained.

import PackageDescription

let package = Package(
    name: "CocoaSpice",
    platforms: [
        .iOS(.v11), .macOS(.v10_14)
    ],
    products: [
        .library(
            name: "CocoaSpice",
            targets: ["CocoaSpice"]),
        .library(
            name: "CocoaSpiceNoUsb",
            targets: ["CocoaSpiceNoUsb"]),
    ],
    targets: [
        .target(
            name: "CocoaSpiceRenderer",
            dependencies: [],
            resources: [
                // Astra development build uses the matching installed UTM metallib.
                // The project build script compiles this source when Metal tools exist.
                .copy("CSShaders.metal")]),
        .target(
            name: "CocoaSpice",
            dependencies: ["CocoaSpiceRenderer"],
            exclude: ["ExternalHeaders"],
            cSettings: [
                .define("WITH_USB_SUPPORT"),
                .headerSearchPath("ExternalHeaders"),
                .headerSearchPath("ExternalHeaders/glib-2.0"),
                .headerSearchPath("ExternalHeaders/gstreamer-1.0"),
                .headerSearchPath("ExternalHeaders/libusb-1.0"),
                .headerSearchPath("ExternalHeaders/spice-1"),
                .headerSearchPath("ExternalHeaders/spice-client-glib-2.0")]),
        .target(
            name: "CocoaSpiceNoUsb",
            dependencies: ["CocoaSpiceRenderer"],
            exclude: [
                "ExternalHeaders",
                "CSUSBDevice.m",
                "CSUSBManager.m"],
            cSettings: [
                .headerSearchPath("ExternalHeaders"),
                .headerSearchPath("ExternalHeaders/glib-2.0"),
                .headerSearchPath("ExternalHeaders/gstreamer-1.0"),
                .headerSearchPath("ExternalHeaders/spice-1"),
                .headerSearchPath("ExternalHeaders/spice-client-glib-2.0")]),
        .testTarget(
            name: "CocoaSpiceTests",
            dependencies: ["CocoaSpice"],
            linkerSettings: [
                .linkedLibrary("glib-2.0"),
                .linkedLibrary("gstreamer-1.0"),
                .linkedLibrary("usb-1.0"),
                .linkedLibrary("spice-client-glib-2.0")]),
    ]
)
