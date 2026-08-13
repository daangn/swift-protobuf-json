//
// PluginRunner — orchestrates one protoc invocation.
//
// We don't emit Swift code ourselves. Instead we:
//
//   1. forward the CodeGeneratorRequest we just received to Apple's
//      protoc-gen-swift (as a subprocess), letting it produce its usual
//      `*.pb.swift` files for every input proto;
//   2. take each of those files, strip the SwiftProtobuf-runtime tail
//      that lives below the "Code below here is support for the
//      SwiftProtobuf runtime." marker, leaving only the struct / enum
//      bodies; and
//   3. append a `// MARK: - JSON Decodable` section containing
//      `extension Foo: Decodable` blocks generated from the original
//      descriptors.
//
// The output preserves `import SwiftProtobuf` and Apple's struct shells
// verbatim (Apple is responsible for every proto feature, naming rule,
// well-known type, and source-code comment). We add JSON decoding and
// remove ~half the file weight that comes from the binary wire format
// extensions nobody linked to anyway.
//

import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

struct PluginRunner {
  let options: PluginOptions
  let request: Google_Protobuf_Compiler_CodeGeneratorRequest
  let descriptors: DescriptorSet

  init(
    options: PluginOptions,
    request: Google_Protobuf_Compiler_CodeGeneratorRequest
  ) {
    self.options = options
    self.request = request
    self.descriptors = DescriptorSet(protos: request.protoFile)
  }

  func generate(outputs: any GeneratorOutputs) throws {
    let appleResponse = try AppleProxy().generate(request: request)
    if !appleResponse.error.isEmpty {
      throw RunnerError.appleEmitFailed(appleResponse.error)
    }

    // Build a lookup keyed by the proto source path that Apple stamps
    // into each generated file as `// Source: <path>`. This insulates us
    // from Apple's `FileNaming` option (full_path / path_to_underscores /
    // drop_path) and from any future filename mangling — the source
    // comment is a stable invariant in their emit.
    let descriptorsByProtoName = descriptors.files.reduce(
      into: [String: FileDescriptor]()
    ) { acc, file in
      acc[file.name] = file
    }

    // Reachability and stubbing both operate against the slice of the
    // descriptor set we're actually generating code for. The full set
    // contains transitive dependencies too — those are inputs for type
    // resolution but their Swift symbols don't exist in our output, so
    // anything pointing at them is "out of scope" and gets stubbed.
    let fileToGenerate = Set(request.fileToGenerate)
    let inScopeFiles = descriptors.files.filter { fileToGenerate.contains($0.name) }
    let reachability = options.entryPoints.isEmpty
      ? nil
      : Reachability(
        entryPoints: options.entryPoints,
        files: inScopeFiles,
        namer: SwiftProtobufNamer(
          currentFile: inScopeFiles.first ?? descriptors.files.first!,
          protoFileToModuleMappings: ProtoFileToModuleMappings()
        )
      )

    for appleFile in appleResponse.file {
      var stripped = SwiftProtobufStripper.strip(appleFile.content)
      // The strip removed everything below the SwiftProtobuf-runtime
      // marker — including the `_StorageClass` / `_uniqueStorage()` pair
      // that copy-on-write messages embed inside that block and that
      // the struct body above the marker calls into. Rescue those
      // pieces (they're pure Foundation Swift) from the original Apple
      // content and concatenate them back so the struct still compiles.
      let salvagedStorage = StorageSalvager.salvage(
        from: appleFile.content,
        keepingSwiftNames: reachability?.reachableSwiftNames
      )

      // Tree-shake against the entry-points-resolved keep set before we
      // append our own Decodable extensions. That way unreachable
      // structs disappear entirely from the file *and* we skip emitting
      // a Decodable for them too.
      if let reachability {
        stripped = EntryPointsFilter.filter(
          stripped,
          keepingSwiftNames: reachability.reachableSwiftNames
        )
      }

      let suffix: String
      if let descriptor = sourceProtoPath(in: appleFile.content)
        .flatMap({ descriptorsByProtoName[$0] })
      {
        let namer = SwiftProtobufNamer(
          currentFile: descriptor,
          protoFileToModuleMappings: ProtoFileToModuleMappings()
        )
        suffix = "\n"
          + DecodableEmitter(
            file: descriptor,
            namer: namer,
            keepingSwiftNames: reachability?.reachableSwiftNames,
            codingKeyStyle: options.codingKeyStyle
          )
          .emit()
      } else {
        // Output we can't tie back to a known descriptor — pass through
        // unchanged. Apple sometimes emits grpc / extension files in
        // multi-plugin scenarios that we don't try to interpret.
        suffix = ""
      }
      let storageSection: String =
        salvagedStorage.isEmpty
        ? ""
        : "\n// MARK: - Copy-on-write storage (salvaged from Apple's binary extension)\n\n"
          + salvagedStorage.joined(separator: "\n\n")
          + "\n"
      let body = stripped + storageSection + suffix
      try outputs.add(fileName: appleFile.name, contents: body)
    }

    // Cross-package stubs: one extra file per generation, never per
    // input. Only emitted when entry_points is set (otherwise we don't
    // know which types are "out of scope").
    if let reachability,
      let stubs = CrossPackageStubEmitter.emit(
        types: reachability.outOfScopeTypes,
        options: CrossPackageStubEmitter.Options(
          timestampDecoder: options.timestampDecoder,
          additionalImports: options.additionalImports,
          structDecoder: options.structDecoder
        )
      )
    {
      try outputs.add(fileName: "cross_package_stubs.pb.swift", contents: stubs)
    }
  }

  // MARK: - Helpers

  /// Extracts the proto source path Apple stamps into each generated file
  /// as `// Source: <path>` in the leading file header. Returns nil if
  /// the marker is absent (e.g. on grpc / extension files we don't try to
  /// interpret).
  private func sourceProtoPath(in contents: String) -> String? {
    let needle = "// Source: "
    for line in contents.split(separator: "\n", maxSplits: 32, omittingEmptySubsequences: false) {
      guard line.hasPrefix(needle) else { continue }
      return String(line.dropFirst(needle.count))
    }
    return nil
  }
}

enum RunnerError: Error, CustomStringConvertible {
  case appleEmitFailed(String)

  var description: String {
    switch self {
    case .appleEmitFailed(let message):
      return "protoc-gen-swift returned an error: \(message)"
    }
  }
}
