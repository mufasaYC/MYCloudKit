// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MYCloudKit",
    platforms: [
        .iOS(.v15),
        .watchOS(.v8),
        .macCatalyst(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "MYCloudKit",
            targets: ["MYCloudKit"]
        ),
    ],
    targets: [
        .target(
            name: "MYCloudKit"
        )
    ]
)
