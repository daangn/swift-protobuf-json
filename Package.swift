// swift-tools-version: 6.0
//
// swift-protobuf-json
//
// A Swift protoc plugin that emits Decodable structs for JSON-only Protocol
// Buffers transport. It preserves Apple's SwiftProtobuf-backed type shells
// while stripping the generated binary wire-format extensions.

import PackageDescription

let package = Package(
  name: "swift-protobuf-json",
  platforms: [
    .macOS(.v13),
  ],
  products: [
    .executable(
      name: "protoc-gen-swift-json",
      targets: ["protoc-gen-swift-json"]
    ),
  ],
  dependencies: [
    // Apple's plugin SDK — provides Descriptor / FileGenerator abstractions
    // we build on top of. Vendored as binary plugin in the future to drop the
    // build-time dep.
    .package(
      url: "https://github.com/apple/swift-protobuf.git",
      from: "1.30.0"
    ),
  ],
  targets: [
    .executableTarget(
      name: "protoc-gen-swift-json",
      dependencies: [
        .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
      ],
      path: "Sources/protoc-gen-swift-json",
      exclude: ["README.md"]
    ),
    .testTarget(
      name: "protoc-gen-swift-jsonTests",
      dependencies: [
        "protoc-gen-swift-json",
        // The DecodingFixtures sources are byte-identical copies of the
        // plugin's output and therefore `import SwiftProtobuf`. Linking
        // it here lets the test target compile them directly so
        // JSONDecoder can exercise the emitted Decodable conformances.
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      path: "Tests/protoc-gen-swift-jsonTests",
      resources: [
        // Fixtures (.proto, .descriptorset, raw Apple emit) and the
        // expected post-processed output. GoldenTests reads them at
        // runtime and never shells out — neither protoc nor protoc-gen-
        // swift is invoked from the test binary.
        .copy("Goldens"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
