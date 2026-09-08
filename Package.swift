// swift-tools-version: 6.1
import PackageDescription

// NOTE: This host has only the Command Line Tools toolchain (no Xcode), so the
// XCTest and swift-testing modules are unavailable. Tests therefore run through
// a small self-contained harness executable (`sleepguard-tests`) that exits
// non-zero on any failed assertion, which `swift run sleepguard-tests` executes.
let package = Package(
  name: "SleepGuardInspector",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "SleepGuardCore", targets: ["SleepGuardCore"]),
    .executable(name: "sleepguard", targets: ["sleepguard"]),
    .executable(name: "SleepGuardMenuBar", targets: ["SleepGuardMenuBar"]),
    .executable(name: "sleepguard-tests", targets: ["sleepguard-tests"]),
  ],
  targets: [
    .target(name: "SleepGuardCore"),
    .executableTarget(name: "sleepguard", dependencies: ["SleepGuardCore"]),
    .executableTarget(name: "SleepGuardMenuBar", dependencies: ["SleepGuardCore"]),
    .executableTarget(name: "sleepguard-tests", dependencies: ["SleepGuardCore"]),
  ]
)
