//
// SwiftProtobufStripper.swift
//
// Apple's protoc-gen-swift output is split into two parts by a fixed marker
// line:
//
//     // MARK: - Code below here is support for the SwiftProtobuf runtime.
//
// Everything above the marker is the struct / enum body itself: properties,
// nested types, getters/setters, the default `init()`. Everything below is
// `extension Foo: SwiftProtobuf.Message, _MessageImplementationBase, …`
// — the binary wire format conformance, `_protobuf_nameMap` bytecode,
// `decodeMessage`, `traverse`, equality, and so on. JSON-only consumers
// don't link any of it, so we drop the tail wholesale.
//
// We deliberately do *not* touch the body above the marker. That keeps the
// stripper trivially correct: as Apple ships new proto features, new
// well-known types, new naming rules, anything that lands above the marker
// flows through to our output unmodified. The only invariant the stripper
// depends on is the existence of the marker line — which Apple has emitted
// since the first version of the plugin and is unlikely to remove because
// it's part of the published output format.
//
// If a future Apple release drops the marker we fall back to passing the
// content through unchanged. Tests would then flag the binary tail as
// unexpected and we'd add an alternative rule.
//

import Foundation

enum SwiftProtobufStripper {

  /// The exact marker line Apple's protoc-gen-swift emits between the
  /// generated struct/enum bodies and the SwiftProtobuf runtime extensions.
  static let marker =
    "// MARK: - Code below here is support for the SwiftProtobuf runtime."

  /// Returns the prefix of `contents` up to (but not including) the
  /// runtime-support marker, with trailing whitespace normalised to a
  /// single newline. If the marker is not present (e.g. an empty proto
  /// with no extensions, or a future Apple release that drops it) the
  /// input is returned unchanged.
  static func strip(_ contents: String) -> String {
    guard let range = contents.range(of: marker) else {
      return contents
    }
    let head = contents[..<range.lowerBound]
    return head.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }
}
