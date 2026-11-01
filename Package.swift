// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XMBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "XMBridge", targets: ["XMBridge"]),
    ],
    targets: [
        // Pure protocol code (framing, session, command set, state). No Bluetooth dependency, so it is unit-testable.
        .target(name: "MDRKit"),
        // The menu bar app: IOBluetooth RFCOMM transport + SwiftUI.
        .executableTarget(
            name: "XMBridge",
            dependencies: ["MDRKit"],
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        .testTarget(name: "MDRKitTests", dependencies: ["MDRKit"]),
    ]
)
