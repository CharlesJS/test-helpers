// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "test-helpers",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "DiskImageHelper",
            targets: ["DiskImageHelper"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system", from: "1.7.5"),
        .package(url: "https://github.com/CharlesJS/lzfse-swift", branch: "main"),
    ],
    targets: [
        .target(
            name: "DiskImageHelper",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
                .product(name: "LZFSE", package: "lzfse-swift", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "DiskImageHelperTests",
            dependencies: ["DiskImageHelper"],
            resources: [
                .copy("fixtures")
            ]
        ),
    ]
)
