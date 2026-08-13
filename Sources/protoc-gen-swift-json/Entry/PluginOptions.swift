//
// PluginOptions — parsed from protoc's `--swift-json_opt=key=value,key=value`.
//
// protoc passes the raw parameter string straight through; we strip out
// every key we own (entry_points / coding_key_style / timestamp_decoder)
// and keep the
// leftovers in `forwardableRawParameter` so PluginRunner can hand them
// to Apple's protoc-gen-swift untouched.
//

import Foundation

/// How CodingKeys should map Swift property names back to the JSON wire
/// names. proto3 JSON spec says lowerCamelCase, but some backends
/// serialise field names verbatim from the proto descriptor
/// (snake_case).
enum CodingKeyStyle: String {
  /// proto3 JSON spec — lowerCamelCase. `info_section` ↔ `infoSection`.
  case camelCase
  /// proto field name verbatim. `info_section` ↔ `info_section`.
  case snakeCase
}

struct PluginOptions {
  var entryPoints: Set<String> = []
  /// Style for the raw value emitted into `enum CodingKeys: String,
  /// CodingKey`. Default matches the proto3 JSON spec; flip to
  /// `snakeCase` when the backend serialises field names verbatim.
  var codingKeyStyle: CodingKeyStyle = .camelCase
  /// Swift type name to delegate `Google_Protobuf_Timestamp` JSON
  /// decoding to. When set, the cross-package stub for
  /// `SwiftProtobuf.Google_Protobuf_Timestamp` decodes a JSON string
  /// via `try <TypeName>.decode(_: String) -> Date` and splits the
  /// resulting `Date` into `seconds` / `nanos`. When `nil`, the stub
  /// falls back to the default zero-value behaviour.
  ///
  /// The plugin doesn't depend on or import the delegate type — it just
  /// substitutes the literal name into the generated code. Callers are
  /// responsible for making the type visible (either it lives in the
  /// generated module, or it's imported via Apple plugin options).
  var timestampDecoder: String? = nil
  /// Modules the generated `cross_package_stubs.pb.swift` should import
  /// in addition to `Foundation` and `SwiftProtobuf`. Needed when the
  /// delegate type referenced by an option like `timestamp_decoder`
  /// lives in a separate module from the generated output. Pass as a
  /// semicolon-delimited list: `additional_imports=ModuleA;ModuleB`.
  var additionalImports: [String] = []
  /// When true, `SwiftProtobuf.Google_Protobuf_Struct` (and the
  /// `Google_Protobuf_Value` / `Google_Protobuf_ListValue` it nests) get a
  /// real recursive JSON `Decodable` in `cross_package_stubs.pb.swift`
  /// instead of the zero-value stub — so arbitrary-JSON fields (proto
  /// `google.protobuf.Struct`) carry their payload instead of silently
  /// decoding to an empty struct. No delegate needed: JSON → Struct is
  /// universal. Enable with `struct_decoder=true`.
  var structDecoder: Bool = false
  /// Pairs we didn't recognise. PluginRunner re-joins them and hands
  /// them to Apple's protoc-gen-swift so users can pass plugin-foreign
  /// options through on the same `--swift-json_opt=…` invocation.
  private(set) var forwardableRawParameter: String = ""

  init(rawParameter: String) throws {
    var forwardable: [String] = []
    let pairs = rawParameter
      .split(separator: ",", omittingEmptySubsequences: true)
      .map(String.init)
    for pair in pairs {
      let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard kv.count == 2 else {
        throw PluginOptionError.invalidPair(pair)
      }
      let key = kv[0].trimmingCharacters(in: .whitespaces)
      let value = kv[1].trimmingCharacters(in: .whitespaces)
      switch key {
      case "entry_points":
        self.entryPoints = Set(
          value.split(separator: ";").map(String.init)
        )
      case "doc_comments", "module_name", "skip_unresolved_imports":
        throw PluginOptionError.unknownKey(key)
      case "coding_key_style":
        switch value.lowercased() {
        case "snake_case", "snakecase":
          self.codingKeyStyle = .snakeCase
        case "camel_case", "camelcase", "":
          self.codingKeyStyle = .camelCase
        default:
          throw PluginOptionError.invalidPair("coding_key_style=\(value)")
        }
      case "timestamp_decoder":
        self.timestampDecoder = value.isEmpty ? nil : value
      case "struct_decoder":
        self.structDecoder = (value.lowercased() == "true")
      case "additional_imports":
        self.additionalImports = value
          .split(separator: ";", omittingEmptySubsequences: true)
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
      default:
        // Not one of ours — keep it intact so we can pass it through to
        // Apple's plugin. Preserves the original spacing as best as we
        // can after trimming.
        forwardable.append("\(key)=\(value)")
      }
    }
    self.forwardableRawParameter = forwardable.joined(separator: ",")
  }
}

enum PluginOptionError: Error, CustomStringConvertible {
  case invalidPair(String)
  case unknownKey(String)

  var description: String {
    switch self {
    case .invalidPair(let pair):
      return "invalid plugin option pair (expected `key=value`): \(pair)"
    case .unknownKey(let key):
      return "unsupported plugin option key: \(key)"
    }
  }
}
