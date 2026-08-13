//
// EntryPointsFilter.swift
//
// Bridges the post-processing pipeline and the descriptor-based
// `Reachability` set. Given the source text Apple emitted for one file
// (already stripped of the SwiftProtobuf-runtime tail) and the set of
// top-level Swift names we want to keep, this returns the same text
// minus the top-level struct / enum declarations whose names aren't on
// the keep list. Everything else — file header, import line,
// `_GeneratedWithProtocGenSwiftVersion`, `extension` blocks belonging
// to a kept type — passes through unchanged.
//

import Foundation

enum EntryPointsFilter {

  /// Removes every top-level `struct` / `enum` declaration whose Swift
  /// identifier is not in `keep`. Other top-level blocks (`extension`,
  /// fileprivate helpers, the version stamp) are passed through
  /// unchanged, except for `extension <Name>:` blocks whose target
  /// type was dropped — those follow the type out the door so the
  /// emitted file stays referentially consistent.
  static func filter(_ source: String, keepingSwiftNames keep: Set<String>) -> String {
    let lines = source.components(separatedBy: "\n")
    let blocks = TopLevelBlockExtractor.extract(source)

    // Which line indices fall inside a dropped block — we'll skip these
    // when reassembling the output.
    var droppedLines: Set<Int> = []
    for block in blocks {
      if shouldDrop(block: block, in: lines, keep: keep) {
        for i in block.startLine...block.endLine { droppedLines.insert(i) }
      }
    }

    // Walk the input, copying through every line that isn't part of a
    // dropped block. We also collapse runs of blank lines so the output
    // doesn't end up with awkward gaps where blocks used to be.
    var result: [String] = []
    var previousWasBlank = false
    for (index, line) in lines.enumerated() {
      if droppedLines.contains(index) { continue }
      let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
      if isBlank && previousWasBlank { continue }
      result.append(line)
      previousWasBlank = isBlank
    }
    return result.joined(separator: "\n")
  }

  private static func shouldDrop(
    block: TopLevelBlock,
    in lines: [String],
    keep: Set<String>
  ) -> Bool {
    switch block.kind {
    case .namedStruct(let name), .namedEnum(let name):
      return !keep.contains(name)
    case .other:
      // Drop extension blocks whose target type was filtered out.
      let opening = lines[block.startLine]
      guard opening.hasPrefix("extension ") || opening.hasPrefix("public extension ") else {
        return false
      }
      guard let targetName = extractExtensionTarget(opening) else { return false }
      return !keep.contains(targetName)
    }
  }

  /// Parses `extension Foo: Bar {…` and `extension Foo.Nested: Bar {…`
  /// style lines and returns just the top-level token before any dot
  /// ("Foo" in both cases). The keep set is keyed on top-level Swift
  /// names, so a nested-type extension survives whenever its outer
  /// type does. Returns `nil` on shapes we don't recognise — those
  /// pass through untouched.
  private static func extractExtensionTarget(_ line: String) -> String? {
    var tail = Substring(line)
    if tail.hasPrefix("public ") { tail = tail.dropFirst("public ".count) }
    guard tail.hasPrefix("extension ") else { return nil }
    tail = tail.dropFirst("extension ".count)
    let root = tail.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
    guard !root.isEmpty else { return nil }
    return String(root)
  }
}
