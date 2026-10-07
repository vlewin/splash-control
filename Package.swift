// swift-tools-version:5.10
import PackageDescription

// The app links Apple-only frameworks, and `swift test` builds every target,
// so on Linux the executable would fail on `import AppKit`. Gate it to macOS;
// the kit and its tests stay cross-platform.
#if os(macOS)
  let appTargets: [Target] = [
    .executableTarget(
      name: "SplashControl",
      dependencies: ["SplashControlKit"],
      path: "Sources/SplashControl"
    )
  ]
#else
  let appTargets: [Target] = []
#endif

let package = Package(
    name: "SplashControl",
    // Platform floor matches splash 1.2.1 (macOS 26.4+, GPU family 9).
    platforms: [.macOS("26.4")],
    targets: [
        // DTOs live in a small public library: SPM forbids test targets from
        // depending on executable targets, and the app imports the kit.
        .target(
            name: "SplashControlKit",
            path: "Sources/SplashControlKit"
        ),
    ] + appTargets + [
        .testTarget(
            name: "SplashControlKitTests",
            dependencies: ["SplashControlKit"],
            path: "Tests/SplashControlKitTests"
        ),
    ]
)
