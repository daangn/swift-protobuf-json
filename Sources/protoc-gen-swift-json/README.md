# protoc-gen-swift-json source layout

This directory contains the SwiftPM executable target for `protoc-gen-swift-json`.

SwiftPM compiles every `.swift` file under this target path recursively, so the files are grouped by responsibility rather than by separate modules.

## Directory structure

```text
Sources/protoc-gen-swift-json/
├── Plugin.swift
├── Entry/
│   ├── PluginRunner.swift
│   └── PluginOptions.swift
├── Bridge/
│   └── AppleProxy.swift
├── Emitters/
│   └── DecodableEmitter.swift
├── PostProcessing/
│   ├── SwiftProtobufStripper.swift
│   ├── StorageSalvager.swift
│   └── TopLevelBlockExtractor.swift
├── TreeShaking/
│   ├── Reachability.swift
│   ├── EntryPointsFilter.swift
│   └── CrossPackageStubEmitter.swift
└── Support/
    └── Queue.swift
```

## Groups

### Entry

Executable entry point and request orchestration.

- **`Plugin.swift`** lives at the target root so it is the first file readers see. It defines the `@main` plugin type and adapts `SwiftProtobufPluginLibrary.CodeGenerator` into this package's pipeline.
- **`PluginRunner.swift`** coordinates generation for each request: proxy Apple's output, post-process it, append JSON decoding, and return final files.
- **`PluginOptions.swift`** parses `--swift-json_opt=...` values and separates options owned by this plugin from options forwarded to Apple's generator.

### Bridge

Integration with Apple's `swift-protobuf` generator.

- **`AppleProxy.swift`** locates and spawns `protoc-gen-swift`, forwards the same `CodeGeneratorRequest`, and captures Apple's generated response.

### Emitters

Code generation owned by this plugin.

- **`DecodableEmitter.swift`** walks protobuf descriptors and emits `Decodable` conformances, `CodingKeys`, enum decoding, map decoding, repeated decoding, oneof decoding, and proto3 default fallbacks.

### PostProcessing

Text-level transformations over Apple's generated Swift output.

- **`SwiftProtobufStripper.swift`** removes generated binary wire-format runtime support from Apple's output.
- **`StorageSalvager.swift`** preserves storage declarations needed by the retained struct shells.
- **`TopLevelBlockExtractor.swift`** extracts top-level Swift blocks used by source filtering.

### TreeShaking

Optional `entry_points` support.

- **`Reachability.swift`** computes descriptor reachability from configured entry-point Swift type names.
- **`EntryPointsFilter.swift`** removes unreachable generated declarations and extensions from the output.
- **`CrossPackageStubEmitter.swift`** emits stubs needed when reachable entry points reference types outside the current generation scope.

### Support

Small shared data structures and helpers.

- **`Queue.swift`** provides FIFO queue semantics for breadth-first traversal without using `Array.removeFirst()`.

## Pipeline

```text
Plugin.swift
  -> PluginRunner.swift
  -> AppleProxy.swift
  -> Reachability.swift (when entry_points is set)
  -> SwiftProtobufStripper.swift
  -> StorageSalvager.swift
  -> EntryPointsFilter.swift (when entry_points is set)
  -> DecodableEmitter.swift
  -> combine stripped declarations + salvaged storage + Decodable extensions
  -> CodeGeneratorResponse

Reachability.outOfScopeTypes
  -> CrossPackageStubEmitter.swift
  -> cross_package_stubs.pb.swift
```
