// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LLMkit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "LLMkit",
            targets: ["LLMkit"]
        ),
    ],
    targets: [
        .target(
            name: "LLMkit"
        ),
    ]
)
