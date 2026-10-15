// swift-tools-version: 6.0
import PackageDescription

let coreBuildDir = Context.packageDirectory + "/../core/build"

let package = Package(
    name: "Wisp",
    platforms: [.macOS(.v14)],
    targets: [
        // C module exposing wisp.h; links the Go static archive and what the Go runtime needs.
        .target(
            name: "CWisp",
            linkerSettings: [
                .unsafeFlags(["-L" + coreBuildDir]),
                .linkedLibrary("wisp"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("resolv"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "Wisp",
            dependencies: ["CWisp"]
        ),
    ]
)
