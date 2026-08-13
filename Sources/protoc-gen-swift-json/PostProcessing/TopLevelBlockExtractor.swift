//
// TopLevelBlockExtractor.swift
//
// Apple's protoc-gen-swift output has a stable shape that lets us pick
// top-level declarations out without parsing Swift syntax:
//
//   - Every top-level declaration starts at column 0. Apple never
//     indents `struct`, `enum`, `extension`, or any other top-level
//     keyword.
//
//   - Every top-level declaration's closing brace is the line that
//     contains *only* `}` at column 0.
//
//   - Nested declarations (struct inside struct, enum inside struct,
//     etc.) sit inside the parent's body and are therefore indented;
//     they never look like top-level openings to this extractor.
//
//   - File-level fileprivate helpers (`fileprivate struct
//     _GeneratedWithProtocGenSwiftVersion`, `fileprivate let
//     _protobuf_package`) also start at column 0 and follow the same
//     `}` rule, so we treat them as just another block kind and let
//     callers decide whether to keep them.
//
// The extractor returns each block's line range plus, when the block
// is a named declaration we recognise (struct or enum), the Swift
// identifier. That's all the entry_points filter needs to map each
// block back to the descriptors it was produced from.
//

import Foundation

enum TopLevelBlockKind {
  /// `struct <Name>:` or `public struct <Name>:` at column 0.
  case namedStruct(String)
  /// `enum <Name>:` or `public enum <Name>:` at column 0.
  case namedEnum(String)
  /// Anything else that starts at column 0 (extensions, fileprivate
  /// helpers, version-stamps). The extractor doesn't try to look inside.
  case other
}

struct TopLevelBlock {
  let kind: TopLevelBlockKind
  /// Inclusive start line index in the input.
  let startLine: Int
  /// Inclusive end line index in the input.
  let endLine: Int
}

enum TopLevelBlockExtractor {

  /// Returns every top-level block (declarations starting at column 0
  /// and ending at a column-0 closing brace) in the order they appear
  /// in `source`.
  static func extract(_ source: String) -> [TopLevelBlock] {
    let lines = source.components(separatedBy: "\n")
    var blocks: [TopLevelBlock] = []
    var cursor = 0
    while cursor < lines.count {
      guard let kind = classifyOpening(lines[cursor]) else {
        cursor += 1
        continue
      }
      let end = findClosingBrace(in: lines, startingAfter: cursor) ?? cursor
      blocks.append(TopLevelBlock(kind: kind, startLine: cursor, endLine: end))
      cursor = end + 1
    }
    return blocks
  }

  // MARK: - Internals

  /// Returns the kind of top-level block opening this line represents,
  /// or `nil` if the line doesn't start one. Comments, blank lines,
  /// indented lines, and anything that doesn't introduce a new
  /// declaration return `nil`.
  private static func classifyOpening(_ line: String) -> TopLevelBlockKind? {
    // Only column-0 starts count.
    guard let first = line.first, !first.isWhitespace else { return nil }

    // We look at the first non-`public` token.
    var tail = Substring(line)
    if tail.hasPrefix("public ") { tail = tail.dropFirst("public ".count) }

    if tail.hasPrefix("struct "), let name = extractIdentifier(after: "struct ", in: tail) {
      return .namedStruct(name)
    }
    if tail.hasPrefix("enum "), let name = extractIdentifier(after: "enum ", in: tail) {
      return .namedEnum(name)
    }

    // Other top-level starts we should still recognise as blocks so the
    // extractor advances past them: `extension`, `fileprivate struct`,
    // `fileprivate let`, comments at column 0, anything ending in `{`.
    if line.hasSuffix("{")
      || tail.hasPrefix("extension ")
      || tail.hasPrefix("fileprivate ")
    {
      return .other
    }
    return nil
  }

  private static func extractIdentifier(after prefix: String, in line: Substring) -> String? {
    let afterPrefix = line.dropFirst(prefix.count)
    let identifier = afterPrefix.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
    guard !identifier.isEmpty else { return nil }
    return String(identifier)
  }

  /// Finds the index of the first line at or after `startingAfter` that
  /// is exactly `}` — Apple's convention for the closing brace of any
  /// top-level declaration. Returns `nil` if we run off the end (in
  /// which case the caller treats the opening line itself as the end).
  private static func findClosingBrace(in lines: [String], startingAfter: Int) -> Int? {
    for i in (startingAfter + 1)..<lines.count where lines[i] == "}" {
      return i
    }
    return nil
  }
}
