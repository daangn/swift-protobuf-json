//
// StorageSalvager.swift
//
// Apple emits a copy-on-write storage helper for messages large enough or
// recursive enough to warrant it. The helper consists of two pieces that
// the *struct body* references directly:
//
//     nonisolated extension Foo: SwiftProtobuf.Message, … {
//       fileprivate class _StorageClass {
//         var _field1: T? = nil
//         …
//         init(copying source: _StorageClass) { … }
//       }
//
//       fileprivate mutating func _uniqueStorage() -> _StorageClass { … }
//
//       // …binary serialization beyond this point
//     }
//
// When SwiftProtobufStripper drops everything below the runtime-support
// marker, both pieces vanish — and the struct above the marker, which
// projects every message property through `_storage._field` / sets it via
// `_uniqueStorage()._field = newValue`, no longer compiles.
//
// The salvager rescues those two pieces and emits them back as a
// SwiftProtobuf-free extension of the same type. The body of each piece
// is plain Foundation Swift (typed nullable properties, an `init(copying:)`,
// `isKnownUniquelyReferenced`), so no further fix-up is needed.
//

import Foundation

enum StorageSalvager {

  /// Looks past the SwiftProtobuf runtime marker (everything else has
  /// already been stripped) and returns one `extension Foo { … }` block
  /// per message that needed heap storage. The block contains exactly
  /// the `_StorageClass` declaration and `_uniqueStorage()` method, with
  /// the original indentation flattened by two columns so they sit at
  /// the top level of the extension we emit.
  ///
  /// If `keepingSwiftNames` is non-nil the salvager filters its output
  /// to extensions whose target type (or its outer enclosing type) is
  /// in that set. This keeps us from emitting a storage extension for
  /// a struct that EntryPointsFilter already dropped — which would
  /// leave the extension orphaned and the file uncompilable.
  static func salvage(from contents: String, keepingSwiftNames: Set<String>? = nil) -> [String] {
    let lines = contents.components(separatedBy: "\n")
    var results: [String] = []
    var i = 0
    while i < lines.count {
      guard let target = appleBinaryExtensionTarget(in: lines[i]) else {
        i += 1
        continue
      }
      let blockEnd = findTopLevelClosingBrace(in: lines, from: i + 1) ?? (lines.count - 1)
      let rootName = target.split(separator: ".").first.map(String.init) ?? target
      if let keep = keepingSwiftNames, !keep.contains(rootName) {
        i = blockEnd + 1
        continue
      }
      if let salvage = salvageWithinExtension(
        lines: lines, body: (i + 1)..<blockEnd, target: target
      ) {
        results.append(salvage)
      }
      i = blockEnd + 1
    }
    return results
  }

  // MARK: - Apple binary-extension recognition

  /// Returns the target type name iff this line opens an
  /// `extension <Name>: SwiftProtobuf.Message …` block at column 0,
  /// optionally prefixed with `nonisolated ` (newer swift-protobuf
  /// releases add it for Swift concurrency). Other top-level extensions
  /// (e.g. `_ProtoNameProviding`-only enum extensions) are ignored
  /// because they never carry storage.
  private static func appleBinaryExtensionTarget(in line: String) -> String? {
    // Anchor at column 0 — Apple emits the storage extension at the top
    // level, never indented inside another declaration. Rejecting
    // indented lines first also short-circuits the vast majority of
    // input cheaply.
    guard !line.hasPrefix(" ") else { return nil }

    // Substring slicing only — no allocation. Drop the optional
    // `nonisolated ` modifier, then require the `extension ` keyword.
    var rest = line[...]
    if rest.hasPrefix("nonisolated ") {
      rest = rest.dropFirst("nonisolated ".count)
    }
    guard rest.hasPrefix("extension ") else { return nil }
    guard rest.contains("SwiftProtobuf.Message") else { return nil }

    let tail = rest.dropFirst("extension ".count)
    let name = tail.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
    guard !name.isEmpty else { return nil }
    return String(name)
  }

  private static func findTopLevelClosingBrace(in lines: [String], from: Int) -> Int? {
    for i in from..<lines.count where lines[i] == "}" {
      return i
    }
    return nil
  }

  // MARK: - Salvage inside one binary extension

  private static func salvageWithinExtension(
    lines: [String],
    body: Range<Int>,
    target: String
  ) -> String? {
    // Gate on `_StorageClass`: only copy-on-write messages need salvage.
    // A message without heap storage keeps real stored properties, so its
    // `==` is correctly synthesised by Swift from the `extension X:
    // Equatable {}` we emit — there is nothing to rescue, and emitting a
    // "copy-on-write storage" section for it would be both redundant and
    // misleading. Bail out before touching `==` when no storage is present.
    guard
      let storageRange = findIndentedBlock(
        in: lines, within: body,
        openingMatch: { $0.hasPrefix("  fileprivate class _StorageClass") }
      )
    else {
      return nil
    }

    var salvaged: [String] = []
    salvaged.append(contentsOf: lines[storageRange].map { dropIndent($0, by: 2) })
    salvaged.append("")

    if let range = findIndentedBlock(
      in: lines, within: body,
      openingMatch: { $0.hasPrefix("  fileprivate mutating func _uniqueStorage()") }
    ) {
      salvaged.append(contentsOf: lines[range].map { dropIndent($0, by: 2) })
      salvaged.append("")
    }

    // A copy-on-write message's `static func ==` compares through
    // `_storage` (reference identity short-circuit + `withExtendedLifetime`
    // field compare). Swift cannot synthesise that — a synthesised `==`
    // would compare the `_storage` class field by reference identity and
    // report equal storages as unequal. So for storage messages the real
    // `==` MUST be salvaged. Its body is plain Foundation Swift, so it
    // survives the move into a SwiftProtobuf-free extension intact.
    // Apple writes `static func ==` at internal visibility by default and
    // `public static func ==` when the user passes `Visibility=Public`.
    // Recognise both — our `extension X: Equatable {}` needs the
    // implementation either way.
    if let range = findIndentedBlock(
      in: lines, within: body,
      openingMatch: {
        $0.hasPrefix("  static func ==(") || $0.hasPrefix("  public static func ==(")
      }
    ) {
      salvaged.append(contentsOf: lines[range].map { dropIndent($0, by: 2) })
      salvaged.append("")
    }

    // Trim the trailing blank we appended after each block.
    while salvaged.last == "" { salvaged.removeLast() }
    return """
      extension \(target) {
        \(salvaged.joined(separator: "\n  "))
      }
      """
  }

  /// Finds a declaration at column-2 inside the given range whose opening
  /// line matches `openingMatch`. Returns the inclusive `Range<Int>` of
  /// the whole block, terminated by the matching column-2 `}` line.
  private static func findIndentedBlock(
    in lines: [String],
    within body: Range<Int>,
    openingMatch: (String) -> Bool
  ) -> ClosedRange<Int>? {
    var i = body.lowerBound
    while i < body.upperBound {
      if openingMatch(lines[i]) {
        for j in (i + 1)..<body.upperBound where lines[j] == "  }" {
          return i...j
        }
        return i...(body.upperBound - 1)
      }
      i += 1
    }
    return nil
  }

  private static func dropIndent(_ line: String, by columns: Int) -> String {
    guard line.count >= columns,
      line.prefix(columns).allSatisfy({ $0 == " " })
    else {
      return line
    }
    return String(line.dropFirst(columns))
  }
}
