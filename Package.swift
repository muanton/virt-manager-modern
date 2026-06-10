// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VirtManagerModern",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LibvirtKit", targets: ["LibvirtKit"]),
        .executable(name: "vmm-probe", targets: ["vmm-probe"]),
        .executable(name: "VirtManagerModern", targets: ["App"]),
    ],
    dependencies: [
        // Pinned to the 1.0.0 commit (not the version tag): RoyalVNCKit bundles
        // C crypto targets with unsafe build flags, which SwiftPM only permits
        // when the dependency is referenced by revision/branch rather than version.
        .package(
            url: "https://github.com/royalapplications/royalvnc.git",
            revision: "60a92e1a60e928b29c16230598efd5a97c134139"
        ),
    ],
    targets: [
        // C interop with the Homebrew libvirt library (resolved via pkg-config).
        .systemLibrary(
            name: "CLibvirt",
            path: "Sources/CLibvirt",
            pkgConfig: "libvirt",
            providers: [.brew(["libvirt"])]
        ),

        // Swift wrappers over the libvirt C API. No UI here.
        .target(
            name: "LibvirtKit",
            dependencies: ["CLibvirt"]
        ),

        // Parses/edits libvirt domain XML.
        .target(
            name: "DomainModel"
        ),

        // SSH tunnelling + VNC console session. Uses Swift 5 language mode because
        // RoyalVNCKit's types aren't Sendable-annotated and we bridge its
        // background-thread callbacks onto the main actor by hand.
        .target(
            name: "ConsoleKit",
            dependencies: [
                "DomainModel",
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // C interop with Homebrew spice-gtk (spice-client-glib), via pkg-config.
        .systemLibrary(
            name: "CSpice",
            path: "Sources/CSpice",
            pkgConfig: "spice-client-glib-2.0",
            providers: [.brew(["spice-gtk"])]
        ),

        // A C shim that hides the GObject/GLib machinery behind a small,
        // Swift-callable API (session lifecycle, framebuffer, input).
        .target(
            name: "SpiceShim",
            dependencies: ["CSpice"]
        ),

        // Swift wrapper + NSView renderer for the SPICE console. Reuses
        // ConsoleKit's SSH tunnel; Swift 5 mode for the GObject-style C interop.
        .target(
            name: "SpiceKit",
            dependencies: ["SpiceShim", "ConsoleKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Linking smoke test: prints the libvirt + spice versions.
        .executableTarget(
            name: "vmm-probe",
            dependencies: ["LibvirtKit", "SpiceKit"]
        ),

        // The SwiftUI application.
        .executableTarget(
            name: "App",
            dependencies: ["LibvirtKit", "DomainModel", "ConsoleKit", "SpiceKit"]
        ),

        .testTarget(
            name: "LibvirtKitTests",
            dependencies: ["LibvirtKit", "DomainModel"]
        ),
    ]
)
