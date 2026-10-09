// swift-tools-version:5.10
import PackageDescription

// The app links Apple-only frameworks, and `swift test` builds every target,
// so on Linux the executable would fail on `import AppKit`. Gate the app and
// its tests to macOS; the kit and its tests stay cross-platform.
#if os(macOS)
  let appTargets: [Target] = [
    .executableTarget(
      name: "SplashControl",
      dependencies: ["SplashControlKit"],
      path: "Sources/SplashControl"
    ),
    // SPM 5.5+ lets a test target depend on an executable target.
    .testTarget(
      name: "SplashControlTests",
      dependencies: ["SplashControl"],
      path: "Tests/SplashControlTests"
    ),
  ]
#else
  let appTargets: [Target] = []
#endif

let package = Package(
    name: "SplashControl",
    // Platform floor matches splash 1.3.0 (macOS 26.4+, GPU family 9).
    platforms: [.macOS("26.4")],
    targets: [
        // DTOs live in a small public library: the app is macOS-gated above,
        // the kit stays cross-platform and testable on any OS. (SPM 5.5+
        // allows test targets to depend on executable targets; the split is
        // a portability choice, not a tool limitation.)
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
