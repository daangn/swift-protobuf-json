//
// Plugin.swift — protoc-gen-swift-json entry point.
//
// We piggy-back on `SwiftProtobufPluginLibrary.CodeGenerator`: it handles
// the protoc wire (stdin CodeGeneratorRequest → stdout CodeGeneratorResponse),
// --version/--help flag parsing, and ProtoCompilerContext / GeneratorOutputs
// plumbing. We only have to fill in `generate(...)`. The actual emission is
// delegated to `PluginRunner`.
//

import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

@main
struct ProtocGenSwiftJSON: CodeGenerator {

  var version: String? { "1.0.1" }

  var projectURL: String? { "https://github.com/daangn/swift-protobuf-json" }

  var copyrightLine: String? { "Copyright (c) 2026 Karrot. Apache 2.0." }

  var supportedFeatures: [Google_Protobuf_Compiler_CodeGeneratorResponse.Feature] {
    [.proto3Optional]
  }

  func generate(
    files: [FileDescriptor],
    parameter: any CodeGeneratorParameter,
    protoCompilerContext: any ProtoCompilerContext,
    generatorOutputs: any GeneratorOutputs
  ) throws {
    // Apple's CodeGenerator hands us only the files to *generate*, not their
    // transitive dependencies. protoc-gen-swift (which we're about to fork)
    // needs the dependency descriptors in the request to resolve
    // cross-package field types — without them it traps on the first
    // unresolved reference. Same for our DescriptorSet downstream. So we
    // walk FileDescriptor.dependencies and collect every transitive proto
    // before handing the request off.
    var forwarded = Google_Protobuf_Compiler_CodeGeneratorRequest()
    var visited: Set<String> = []
    var ordered: [Google_Protobuf_FileDescriptorProto] = []
    func collect(_ descriptor: FileDescriptor) {
      guard visited.insert(descriptor.name).inserted else { return }
      for dep in descriptor.dependencies { collect(dep) }
      ordered.append(descriptor.proto)
    }
    for file in files { collect(file) }
    forwarded.protoFile = ordered
    forwarded.fileToGenerate = files.map { $0.name }
    if let version = protoCompilerContext.version {
      forwarded.compilerVersion = version
    }
    // PluginOptions strips its own keys (entry_points etc.) out of the
    // raw parameter and leaves the rest in `forwardableRawParameter`,
    // which is what Apple's plugin sees. Without this Apple rejects
    // unknown keys and the whole codegen fails.
    let options = try PluginOptions(rawParameter: parameter.parameter)
    forwarded.parameter = options.forwardableRawParameter

    let runner = PluginRunner(options: options, request: forwarded)
    try runner.generate(outputs: generatorOutputs)
  }
}
