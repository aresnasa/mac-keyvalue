// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacKeyValue",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MacKeyValue",
            targets: ["MacKeyValue"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.16.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "MacKeyValue",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "MacKeyValueTests",
            dependencies: ["MacKeyValue"],
            path: "Tests"
        )
    ]
)
