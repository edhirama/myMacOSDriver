// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacDriver",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDriverHost", targets: ["MacDriverHost"]),
        .executable(name: "driverctl", targets: ["driverctl"]),
        .executable(name: "drivertasks", targets: ["DriverTasks"]),
        .library(name: "DriverProtocol", targets: ["DriverProtocol"]),
        .library(name: "DriverClient", targets: ["DriverClient"]),
    ],
    targets: [
        // Declarations for the private CoreGraphics / HIServices symbols we rely on.
        .target(name: "CPrivate", path: "Sources/CPrivate"),
        // Wire types shared by the host and every client: JSON value, request, response, error codes.
        .target(name: "DriverProtocol", path: "Sources/DriverProtocol"),
        // Everything with OS lifetime: virtual display, capture, accessibility, input, tools, IPC.
        .target(
            name: "DriverCore",
            dependencies: ["CPrivate", "DriverProtocol"],
            path: "Sources/DriverCore",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Menu-bar host app: owns the display, mirror window, Take Control / Give Back.
        .executableTarget(name: "MacDriverHost", dependencies: ["DriverCore"], path: "Sources/MacDriverHost"),
        // CLI client: `driverctl call '{"name":...}'`.
        // Swift client: `try Driver().call(["name": ..., "arguments": [...]])`.
        .target(name: "DriverClient", dependencies: ["DriverProtocol"], path: "Sources/DriverClient"),
        .executableTarget(name: "driverctl", dependencies: ["DriverClient"], path: "Sources/driverctl"),
        // The five example tasks, written against the Swift client: `drivertasks 1 5`.
        .executableTarget(name: "DriverTasks", dependencies: ["DriverClient"], path: "examples/swift/DriverTasks"),
        // Test fixture: a small app with known controls, driven by Tests/E2E/fixture.py.
        .executableTarget(name: "DriverFixture", path: "Sources/DriverFixture"),
        .testTarget(name: "DriverCoreTests", dependencies: ["DriverCore", "DriverProtocol"], path: "Tests/DriverCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)
