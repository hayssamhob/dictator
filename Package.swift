// swift-tools-version: 6.0
// Minimal SPM manifest exposing DictatorCore as a library so sibling
// projects can depend on it via `.package(path:)` without touching the
// XcodeGen-generated Dictator.xcodeproj (the app target stays Xcode-only).
import PackageDescription

let package = Package(
    name: "Dictator",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "DictatorCore", targets: ["DictatorCore"]),
    ],
    targets: [
        .target(
            name: "DictatorCore",
            path: "Sources/DictatorCore"
        ),
    ]
)
