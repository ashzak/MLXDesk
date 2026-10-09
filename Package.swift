// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MLXDesk",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MLXDesk", targets: ["MLXDesk"]),
        .executable(name: "Qwen35Diag", targets: ["Qwen35Diag"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        // Pinned explicitly: mlx-swift-lm 3.31.4 only requires .upToNextMinor(from: "0.31.4"),
        // which SwiftPM would otherwise satisfy with the newest 0.31.x it can find --
        // 0.31.6, which bumped its own swift-tools-version to 6.3. No Xcode currently on
        // GitHub's hosted macOS runners ships Swift tools >= 6.3, so CI can't build it.
        // 0.31.4 itself only needs tools-version 5.12.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
        ,.package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.5")
    ],
    targets: [
        .executableTarget(
            name: "MLXDesk",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
                ,.product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(name: "MLXDeskTests", dependencies: ["MLXDesk"]),
        .executableTarget(
            name: "Qwen35Diag",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
