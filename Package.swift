// swift-tools-version: 5.10.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

// The FSRSOptimizer target wraps the `fsrs` Rust crate via a uniffi-generated
// Swift wrapper, distributed as `FSRSRustCore.xcframework`. The xcframework is
// produced by `scripts/build-xcframework.sh` and lives at `build/` for local
// development. Tagged releases publish a zipped artifact whose URL + checksum
// can replace the local path below.
//
// The optimizer is opt-in: building it requires the prebuilt xcframework to
// exist. Set `FSRS_BUILD_OPTIMIZER=1` to include `FSRSOptimizer` in the
// package. Without that flag, the package contains only the core FSRS
// scheduling library, exactly as before.
let buildOptimizer = ProcessInfo.processInfo.environment["FSRS_BUILD_OPTIMIZER"] == "1"

var products: [Product] = [
    .library(name: "FSRS", targets: ["FSRS"]),
]
var targets: [Target] = [
    .target(
        name: "FSRS",
        path: "Sources/FSRS/",
        swiftSettings: [
            .enableExperimentalFeature("StrictConcurrency=complete"),
        ]
    ),
    .testTarget(
        name: "FSRSTests",
        dependencies: ["FSRS"],
        path: "./Tests/FSRSTests"
    ),
]

if buildOptimizer {
    products.append(.library(name: "FSRSOptimizer", targets: ["FSRSOptimizer"]))
    targets.append(contentsOf: [
        .binaryTarget(
            name: "fsrs_rs_swiftFFI",
            path: "build/FSRSRustCore.xcframework"
        ),
        .target(
            name: "FSRSOptimizer",
            dependencies: ["FSRS", "fsrs_rs_swiftFFI"],
            path: "Sources/FSRSOptimizer"
        ),
        .testTarget(
            name: "FSRSOptimizerTests",
            dependencies: ["FSRSOptimizer", "FSRS"],
            path: "Tests/FSRSOptimizerTests"
        ),
    ])
}

let package = Package(
    name: "FSRS",
    platforms: [
        .macOS(.v10_13), .iOS(.v14),
    ],
    products: products,
    targets: targets
)
