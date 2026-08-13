//
// DecodableEmitter.swift
//
// For each top-level and nested message / enum in a FileDescriptor we emit
// one Swift `extension … : Decodable { … }` block. The struct / enum
// themselves are produced by Apple's protoc-gen-swift; this emitter only
// adds the JSON decoding behaviour on top.
//
// Decoding policy:
//   - proto3 default semantics. A missing key (or one decoded as JSON
//     `null`) yields the proto3 zero value: "" for string, 0 for numeric
//     scalars, false for bool, Data() for bytes, [] for repeated, [:] for
//     map, and the enum value at number 0 (or the first declared value)
//     for enums.
//   - Explicit presence is preserved. For fields that track presence
//     (singular messages, proto3 `optional` scalars/enums, proto2 fields)
//     a missing key leaves the backing storage `nil` (`hasXxx == false`)
//     rather than materializing the zero value. Reading the field still
//     returns the proto3 default, but callers relying on `hasXxx` /
//     `clearXxx` can tell "unset" apart from "present with default value".
//   - Lossy. Any decode failure on a field — wrong JSON type, malformed
//     bytes, an enum string we don't recognise — collapses that field to
//     its proto3 default rather than throwing out of the entire message.
//     This lets clients survive backend evolution that adds, removes, or
//     retypes fields.
//   - Enums accept both the proto name ("STATUS_ACTIVE") and the numeric
//     value ("1" / 1) on the wire, per the proto3 JSON spec.
//   - Apple's enums already include an `UNRECOGNIZED(Int)` case for open
//     enums; we use that as the fallback bucket for unrecognised values.
//   - Oneofs are decoded by trying each member in declaration order and
//     taking the first one that produces a value.
//

import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

struct DecodableEmitter {
  let file: FileDescriptor
  let namer: SwiftProtobufNamer
  /// If non-nil, top-level messages and enums whose Swift names aren't
  /// in this set are skipped — entry_points tree-shaking. `nil` means
  /// "emit everything", which is the no-entry_points default.
  let keepingSwiftNames: Set<String>?
  /// How `CodingKeys` raw values map to JSON keys.
  let codingKeyStyle: CodingKeyStyle

  init(
    file: FileDescriptor,
    namer: SwiftProtobufNamer,
    keepingSwiftNames: Set<String>? = nil,
    codingKeyStyle: CodingKeyStyle = .camelCase
  ) {
    self.file = file
    self.namer = namer
    self.keepingSwiftNames = keepingSwiftNames
    self.codingKeyStyle = codingKeyStyle
  }

  func emit() -> String {
    var printer = CodePrinter(addNewlines: true)
    printer.print("// MARK: - JSON Decodable")

    for enumDescriptor in file.enums where shouldEmitTopLevel(enum: enumDescriptor) {
      emit(enum: enumDescriptor, printer: &printer)
    }
    for message in file.messages where shouldEmitTopLevel(message: message) {
      emit(message: message, printer: &printer)
    }

    return printer.content
  }

  private func shouldEmitTopLevel(message: Descriptor) -> Bool {
    guard let keep = keepingSwiftNames else { return true }
    return keep.contains(namer.fullName(message: message))
  }

  private func shouldEmitTopLevel(enum descriptor: EnumDescriptor) -> Bool {
    guard let keep = keepingSwiftNames else { return true }
    return keep.contains(namer.fullName(enum: descriptor))
  }

  // MARK: - Recursive walk for nested types

  private func emit(message: Descriptor, printer p: inout CodePrinter) {
    emitMessageExtension(message, printer: &p)
    for nestedEnum in message.enums {
      emit(enum: nestedEnum, printer: &p)
    }
    for nested in message.messages {
      guard !nested.options.mapEntry else { continue }
      emit(message: nested, printer: &p)
    }
  }

  // MARK: - Enum extension

  private func emit(enum descriptor: EnumDescriptor, printer p: inout CodePrinter) {
    let swiftFullName = namer.fullName(enum: descriptor)
    let defaultCase = defaultEnumCase(descriptor)
    let isClosed = descriptor.isClosed

    p.print("", "extension \(swiftFullName): Decodable {")
    p.withIndentation { p in
      p.print("public init(from decoder: any Swift.Decoder) throws {")
      p.withIndentation { p in
        p.print(
          """
          let container = try decoder.singleValueContainer()
          let raw: String
          if let stringValue = try? container.decode(String.self) {
            raw = stringValue
          } else if let intValue = try? container.decode(Int.self) {
            raw = String(intValue)
          } else {
            self = \(defaultCase)
            return
          }
          """
        )
        p.print("switch raw {")
        for value in descriptor.values {
          let caseName = namer.relativeName(enumValue: value)
          p.print("case \"\(value.name)\", \"\(value.number)\": self = .\(caseName)")
        }
        if isClosed {
          // proto2 / closed-enum: Apple emits no `UNRECOGNIZED(Int)`
          // case to route through. Stay lossy by collapsing unknown
          // wire values to the proto default. Callers that need
          // strict behaviour can wrap their decoder.
          p.print(
            """
            default:
              self = \(defaultCase)
            }
            """
          )
        } else {
          p.print(
            """
            default:
              self = .UNRECOGNIZED(Int(raw) ?? 0)
            }
            """
          )
        }
      }
      p.print("}")
    }
    p.print("}")
  }

  private func defaultEnumCase(_ descriptor: EnumDescriptor) -> String {
    let candidate = descriptor.values.first(where: { $0.number == 0 })
      ?? descriptor.values.first
    guard let value = candidate else { return ".UNRECOGNIZED(0)" }
    return ".\(namer.relativeName(enumValue: value))"
  }

  // MARK: - Message extension

  private func emitMessageExtension(_ descriptor: Descriptor, printer p: inout CodePrinter) {
    let swiftFullName = namer.fullName(message: descriptor)
    let topLevelFields = descriptor.fields.filter { $0.realContainingOneof == nil }
    let oneofs = descriptor.oneofs.filter { !$0.isSynthetic }

    p.print("", "extension \(swiftFullName): Decodable {")
    p.withIndentation { p in
      generateCodingKeys(
        printer: &p,
        topLevelFields: topLevelFields,
        oneofs: oneofs
      )
      generateInit(
        printer: &p,
        topLevelFields: topLevelFields,
        oneofs: oneofs
      )
    }
    p.print("}")

    // Restore the auto-synthesized Equatable conformance that Apple
    // provided via a hand-written `static func ==` inside the binary
    // extension we just stripped. Every stored property the message
    // carries — scalars, `SwiftProtobuf.UnknownStorage`, nested message
    // refs — already conforms to Equatable, so an empty extension is
    // enough to let the compiler synthesize `==` for us. This also
    // unblocks any `OneOf_*` enum that names this message in one of its
    // cases, since Apple declares those as `Equatable, Sendable`.
    p.print("extension \(swiftFullName): Equatable {}")
  }

  private func generateCodingKeys(
    printer p: inout CodePrinter,
    topLevelFields: [FieldDescriptor],
    oneofs: [OneofDescriptor]
  ) {
    let allKeyEntries =
      topLevelFields.map { (jsonName(for: $0), swiftPropertyName(for: $0)) }
      + oneofs.flatMap { oneof in
        oneof.fields.map { (jsonName(for: $0), swiftPropertyName(for: $0)) }
      }
    guard !allKeyEntries.isEmpty else { return }

    p.print("public enum CodingKeys: String, CodingKey {")
    p.withIndentation { p in
      for (json, swiftName) in allKeyEntries {
        p.print("case \(swiftName) = \"\(json)\"")
      }
    }
    p.print("}")
  }

  private func generateInit(
    printer p: inout CodePrinter,
    topLevelFields: [FieldDescriptor],
    oneofs: [OneofDescriptor]
  ) {
    p.print("", "public init(from decoder: any Swift.Decoder) throws {")
    p.withIndentation { p in
      p.print("self.init()")
      if topLevelFields.isEmpty && oneofs.isEmpty { return }

      p.print("let container = try decoder.container(keyedBy: CodingKeys.self)")
      for field in topLevelFields {
        emitFieldInit(field: field, printer: &p)
      }
      for oneof in oneofs {
        emitOneofInit(oneof: oneof, printer: &p)
      }
    }
    p.print("}")
  }

  // MARK: - Field-level emit

  private func emitFieldInit(field: FieldDescriptor, printer p: inout CodePrinter) {
    let swiftName = swiftPropertyName(for: field)
    let decodeType = decodeType(for: field)

    // Fields that track explicit presence — singular messages, proto3
    // `optional` scalars/enums, proto2 fields — must NOT eagerly
    // materialize the proto3 default for an absent key. Apple backs them
    // with a fileprivate `_<name>: T?` storage (plus `hasXxx` / `clearXxx`
    // accessors), and the `self.init()` we already called leaves that
    // storage at `nil`. Assigning a default through the computed setter
    // would flip the storage to non-nil, so `hasXxx` would report `true`
    // for a key that never appeared on the wire — destroying the
    // unset-vs-zero distinction the field is meant to carry. So for
    // presence fields we assign only on a successful decode and otherwise
    // leave the storage `nil` (unset). No-presence fields (repeated, map,
    // singular proto3 scalars without `optional`) keep proto3 default
    // semantics, where missing collapses to the zero value.
    if field.hasPresence {
      if isInt64ish(field) {
        // int64 family is serialised as a JSON string (proto3 JSON spec);
        // try the number form, then the string form. Presence-preserving:
        // assign only when one of the two forms yields a value.
        p.print(
          """
          if let v =
            (try? container.decodeIfPresent(\(decodeType).self, forKey: .\(swiftName)))
            ?? (try? container.decodeIfPresent(String.self, forKey: .\(swiftName))).flatMap(\(decodeType).init) {
            self.\(swiftName) = v
          }
          """
        )
      } else {
        p.print(
          "if let v = try? container.decodeIfPresent(\(decodeType).self, forKey: .\(swiftName)) {"
        )
        p.printIndented("self.\(swiftName) = v")
        p.print("}")
      }
    } else if isInt64ish(field) {
      // proto3 JSON spec: int64/uint64/sint64/fixed64/sfixed64 fields
      // are serialised as JSON *strings* (to dodge JavaScript's 2^53
      // safe-int limit). Try the number form first, fall through to
      // the string form, finish with the proto3 default.
      let defaultExpr = defaultExpression(for: field)
      p.print(
        """
        self.\(swiftName) =
          (try? container.decodeIfPresent(\(decodeType).self, forKey: .\(swiftName)))
          ?? (try? container.decodeIfPresent(String.self, forKey: .\(swiftName))).flatMap(\(decodeType).init)
          ?? \(defaultExpr)
        """
      )
    } else {
      let defaultExpr = defaultExpression(for: field)
      p.print(
        "self.\(swiftName) = "
          + "(try? container.decodeIfPresent(\(decodeType).self, forKey: .\(swiftName))) ?? \(defaultExpr)"
      )
    }
  }

  /// proto3 wire types serialised as JSON strings — int64 family.
  /// `repeated`/`map` of these still wrap each element in a string;
  /// handling that uniformly needs a custom Decoder for `[Int64]`,
  /// which is out of scope here.
  private func isInt64ish(_ field: FieldDescriptor) -> Bool {
    guard !field.isRepeated && !field.isMap else { return false }
    switch field.type {
    case .int64, .uint64, .sint64, .fixed64, .sfixed64:
      return true
    default:
      return false
    }
  }

  private func emitOneofInit(oneof: OneofDescriptor, printer p: inout CodePrinter) {
    let oneofPropertyName =
      namer.messagePropertyName(oneof: oneof, prefixed: "").name
    let oneofTypeName = namer.fullName(oneof: oneof)
    let members = oneof.fields
    guard !members.isEmpty else { return }

    for (index, member) in members.enumerated() {
      let memberName = swiftPropertyName(for: member)
      let memberDecodeType = decodeType(for: member)
      let memberCaseName = oneofCaseName(for: member, oneofType: oneofTypeName)
      let prefix = index == 0 ? "if" : "} else if"
      p.print(
        "\(prefix) let v = try? container.decodeIfPresent(\(memberDecodeType).self, forKey: .\(memberName)) {"
      )
      p.printIndented("self.\(oneofPropertyName) = \(memberCaseName)(v)")
    }
    p.print("}")
  }

  // MARK: - Naming / type helpers

  private func swiftPropertyName(for field: FieldDescriptor) -> String {
    namer.messagePropertyNames(
      field: field,
      prefixed: "",
      includeHasAndClear: false
    ).name
  }

  private func jsonName(for field: FieldDescriptor) -> String {
    switch codingKeyStyle {
    case .camelCase:
      // proto3 JSON spec — the descriptor's `jsonName` already carries
      // the lowerCamelCase form.
      return field.jsonName ?? field.name
    case .snakeCase:
      // The proto field name is already snake_case (proto convention).
      return field.name
    }
  }

  /// The dotted relative name Apple emits for a oneof case, used as the
  /// case constructor — e.g. `Smoke_User.OneOf_Choice.text`.
  private func oneofCaseName(for field: FieldDescriptor, oneofType: String) -> String {
    let memberName = swiftPropertyName(for: field)
    return "\(oneofType).\(memberName)"
  }

  /// The Swift type passed to `decodeIfPresent`. `T?` would yield a
  /// double-optional from `decodeIfPresent(T.self, …)`, so for singular
  /// message references we feed the non-optional base type.
  private func decodeType(for field: FieldDescriptor) -> String {
    if field.isMap {
      let (key, value) = mapTypes(for: field)
      return "[\(key): \(value)]"
    }
    if field.isRepeated {
      return "[\(baseSwiftType(for: field))]"
    }
    return baseSwiftType(for: field)
  }

  private func defaultExpression(for field: FieldDescriptor) -> String {
    if field.isMap { return "[:]" }
    if field.isRepeated { return "[]" }
    switch field.type {
    case .message, .group:
      return "nil"
    case .enum:
      guard let enumDescriptor = field.enumType else { return ".UNRECOGNIZED(0)" }
      let defaultCase = defaultEnumCase(enumDescriptor)
      return "\(namer.fullName(enum: enumDescriptor))\(defaultCase)"
    case .string: return "\"\""
    case .bool: return "false"
    case .bytes: return "Data()"
    default: return "0"
    }
  }

  private func baseSwiftType(for field: FieldDescriptor) -> String {
    switch field.type {
    case .string: return "String"
    case .int32, .sint32, .sfixed32: return "Int32"
    case .int64, .sint64, .sfixed64: return "Int64"
    case .uint32, .fixed32: return "UInt32"
    case .uint64, .fixed64: return "UInt64"
    case .bool: return "Bool"
    case .double: return "Double"
    case .float: return "Float"
    case .bytes: return "Data"
    case .enum:
      guard let enumDescriptor = field.enumType else { return "String" }
      return namer.fullName(enum: enumDescriptor)
    case .message, .group:
      guard let messageDescriptor = field.messageType else { return "String" }
      return namer.fullName(message: messageDescriptor)
    }
  }

  private func mapTypes(for field: FieldDescriptor) -> (key: String, value: String) {
    guard let entry = field.messageType, entry.fields.count >= 2 else {
      return ("String", "String")
    }
    let keyField = entry.fields[0]
    let valueField = entry.fields[1]
    return (baseSwiftType(for: keyField), decodeType(for: valueField))
  }
}
