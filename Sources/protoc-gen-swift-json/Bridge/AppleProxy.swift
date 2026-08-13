//
// AppleProxy.swift
//
// Spawns Apple's `protoc-gen-swift` as a subprocess and forwards the same
// CodeGeneratorRequest we received, capturing its CodeGeneratorResponse.
// This is the heart of the post-processing approach: we let Apple do all
// the emit work (struct shells, enum cases, naming, source code comments,
// every proto feature it supports today and tomorrow), and we restrict
// ourselves to (a) stripping the binary-only runtime extensions Apple
// appends and (b) injecting a `Decodable` conformance.
//
// Why subprocess and not an in-process call:
//   Apple's `SwiftGeneratorPlugin` is `internal` in the swift-protobuf
//   package. Even though we depend on swift-protobuf at build time, the
//   only way to reach its generator is the protoc plugin contract — i.e.
//   spawn it as a child process and talk to it over stdin/stdout.
//

import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

struct AppleProxy {
  /// Where to look for `protoc-gen-swift`, in priority order.
  ///   1. `PROTOC_GEN_SWIFT` env var (operator escape hatch)
  ///   2. sibling binary next to our own executable
  ///   3. `which protoc-gen-swift` (PATH lookup)
  func generate(
    request: Google_Protobuf_Compiler_CodeGeneratorRequest
  ) throws -> Google_Protobuf_Compiler_CodeGeneratorResponse {
    let binaryPath = try locateProtocGenSwift()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    // Write the request on a background queue to avoid a deadlock when the
    // request is large enough to fill the pipe buffer before the child
    // starts reading.
    let requestData: Data = try request.serializedBytes()
    DispatchQueue.global(qos: .userInitiated).async {
      let handle = stdinPipe.fileHandleForWriting
      do {
        try handle.write(contentsOf: requestData)
        try handle.close()
      } catch {
        // Best effort — if the child died before we finished writing, the
        // error surfaces below via the non-zero exit status.
      }
    }

    let responseData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let stderrText =
        String(data: stderrData, encoding: .utf8) ?? "<non-utf8 stderr>"
      throw AppleProxyError.appleFailed(
        status: process.terminationStatus,
        message: stderrText
      )
    }

    return try Google_Protobuf_Compiler_CodeGeneratorResponse(
      serializedBytes: responseData
    )
  }

  // MARK: - Binary discovery

  private func locateProtocGenSwift() throws -> String {
    let fm = FileManager.default

    if let override = ProcessInfo.processInfo.environment["PROTOC_GEN_SWIFT"],
      !override.isEmpty, fm.isExecutableFile(atPath: override)
    {
      return override
    }

    if let executableURL = Bundle.main.executableURL {
      let sibling =
        executableURL
        .deletingLastPathComponent()
        .appendingPathComponent("protoc-gen-swift")
        .path
      if fm.isExecutableFile(atPath: sibling) {
        return sibling
      }
    }

    if let pathLookup = whichInPATH("protoc-gen-swift") {
      return pathLookup
    }

    throw AppleProxyError.protocGenSwiftNotFound
  }

  private func whichInPATH(_ name: String) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["which", name]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
      try task.run()
    } catch {
      return nil
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let trimmed = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let path = trimmed, !path.isEmpty,
      FileManager.default.isExecutableFile(atPath: path)
    else { return nil }
    return path
  }
}

enum AppleProxyError: Error, CustomStringConvertible {
  case appleFailed(status: Int32, message: String)
  case protocGenSwiftNotFound

  var description: String {
    switch self {
    case .appleFailed(let status, let message):
      return "protoc-gen-swift exited with status \(status): \(message)"
    case .protocGenSwiftNotFound:
      return """
        protoc-gen-swift not found. swift-protobuf-json wraps Apple's \
        protoc-gen-swift binary; install it (e.g. `brew install \
        swift-protobuf`, or `swift build -c release --product \
        protoc-gen-swift` in apple/swift-protobuf) and either put it on \
        PATH, drop it next to protoc-gen-swift-json, or point at it with \
        the PROTOC_GEN_SWIFT environment variable.
        """
    }
  }
}
