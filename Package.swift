// swift-tools-version:5.9
import Foundation
import PackageDescription

/// Command Line Tools keep TestingMacros beside the compiler, in a folder `swift test` does not
/// search. Without this flag the test target fails to expand `@Test` / `@Suite`.
let testingMacroFlags: [SwiftSetting] = {
    let relative = "usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    let roots = [
        "/Library/Developer/CommandLineTools",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
    ]
    for root in roots {
        let library = (root as NSString).appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: library) {
            return [.unsafeFlags(["-plugin-path", (library as NSString).deletingLastPathComponent])]
        }
    }
    return []
}()

let package = Package(
    name: "TailCat",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TailCat", targets: ["TailCat"]),
    ],
    targets: [
        // Rules, persistence and the tailcat process supervisor. No UI, so it can be unit-tested.
        .target(name: "TailCatCore", resources: [.process("Resources")]),
        // Menu bar app + management window.
        .executableTarget(name: "TailCat", dependencies: ["TailCatCore"]),
        .testTarget(name: "TailCatCoreTests", dependencies: ["TailCatCore"], swiftSettings: testingMacroFlags),
    ]
)
