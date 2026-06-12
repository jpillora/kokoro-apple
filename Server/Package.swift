// swift-tools-version: 6.2
// Companion package for the kokoro-ios fork: macOS executables (CLI demo and
// HTTP TTS server) plus shared helpers. Lives in its own package so the root
// package stays byte-close to upstream (mlalma/kokoro-ios) and iOS consumers
// of KokoroSwift never resolve server-only dependencies like FlyingFox.

import PackageDescription

let package = Package(
  name: "KokoroServer",
  platforms: [
    .macOS(.v15)
  ],
  dependencies: [
    .package(name: "KokoroSwift", path: ".."),
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
    .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
    .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.26.0"),
  ],
  targets: [
    // Helpers shared by the demo and the server (voice loading, text
    // chunking, WAV encoding).
    .target(
      name: "KokoroKit",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
      ]
    ),
    .executableTarget(
      name: "KokoroDemo",
      dependencies: [
        "KokoroKit",
        .product(name: "KokoroSwift", package: "KokoroSwift"),
        .product(name: "MLX", package: "mlx-swift"),
      ]
    ),
    .executableTarget(
      name: "KokoroServer",
      dependencies: [
        "KokoroKit",
        .product(name: "KokoroSwift", package: "KokoroSwift"),
        .product(name: "FlyingFox", package: "FlyingFox"),
        .product(name: "MLX", package: "mlx-swift"),
      ]
    ),
    .testTarget(
      name: "KokoroKitTests",
      dependencies: ["KokoroKit"]
    ),
  ]
)
