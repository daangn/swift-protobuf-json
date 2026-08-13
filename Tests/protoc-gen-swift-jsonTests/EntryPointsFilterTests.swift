//
// EntryPointsFilterTests — line-based tree-shake of Apple's emitted text.
// Reachability is tested separately; here we just check that given a
// pre-computed keep set, the filter removes exactly the unreachable
// top-level blocks (struct, enum) and their dangling extensions.
//

import Foundation
import Testing

@testable import protoc_gen_swift_json

@Suite("EntryPointsFilter")
struct EntryPointsFilterTests {

  @Test("keeps named top-level types and drops the rest")
  func dropsUnreachableTypes() {
    let input = """
      public struct Keep: Sendable {
        public var id: String = ""
      }

      public struct Drop: Sendable {
        public var trash: String = ""
      }

      public enum DropEnum {
        case a
      }
      """
    let kept = EntryPointsFilter.filter(input, keepingSwiftNames: ["Keep"])
    #expect(kept.contains("public struct Keep"))
    #expect(!kept.contains("Drop"))
    #expect(!kept.contains("DropEnum"))
  }

  @Test("drops extensions targeting filtered-out types")
  func dropsDanglingExtensions() {
    let input = """
      public struct Keep: Sendable {}

      public struct Drop: Sendable {}

      extension Keep: Decodable {}

      extension Drop: Decodable {}
      """
    let kept = EntryPointsFilter.filter(input, keepingSwiftNames: ["Keep"])
    #expect(kept.contains("extension Keep"))
    #expect(!kept.contains("extension Drop"))
  }

  @Test("passes through extensions on kept types (qualified name target)")
  func passesQualifiedExtensions() {
    let input = """
      public struct Keep: Sendable {}

      extension Keep: Decodable {}
      extension Keep.Nested: Decodable {}
      """
    let kept = EntryPointsFilter.filter(input, keepingSwiftNames: ["Keep"])
    #expect(kept.contains("extension Keep:"))
    // Qualified extension targets ("Keep.Nested") match by prefix.
    #expect(kept.contains("extension Keep.Nested:"))
  }

  @Test("preserves fileprivate helpers and other non-struct-or-enum blocks")
  func preservesOtherBlocks() {
    let input = """
      fileprivate struct _GeneratedWithProtocGenSwiftVersion {
        // bookkeeping
      }

      public struct Drop: Sendable {}
      """
    let kept = EntryPointsFilter.filter(input, keepingSwiftNames: [])
    #expect(kept.contains("_GeneratedWithProtocGenSwiftVersion"))
    #expect(!kept.contains("public struct Drop"))
  }
}
