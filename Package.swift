// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RedFund",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RedFund", targets: ["RedFund"])
    ],
    targets: [
        .executableTarget(
            name: "RedFund",
            path: "Sources/RedFund",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "RedFundTests",
            dependencies: ["RedFund"],
            path: "Tests/RedFundTests"
        )
    ]
)
