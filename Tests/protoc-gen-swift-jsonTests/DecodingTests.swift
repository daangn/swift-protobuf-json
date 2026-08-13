//
// DecodingTests — runtime behaviour tests for generated Decodable code.
//
// GoldenTests proves the emitter produces the expected Swift text.
// These tests prove the emitted text behaves like a proto3 JSON decoder:
//   - present scalars round-trip,
//   - absent / null scalars fall back to the proto3 default,
//   - lossy decoding tolerates type mismatch without throwing.
//
// FixtureSyncTests ensures each compiled file under DecodingFixtures stays
// byte-identical to its counterpart under Goldens/Expected.
//

import Foundation
import Testing

@Suite("Decoding")
struct DecodingTests {

  // MARK: - Happy path

  @Test("scalars: present fields round-trip through JSONDecoder")
  func scalarsPresentRoundTrip() throws {
    let json = #"{"name":"hi","count":42}"#
    let value = try decode(Goldens_Scalars.self, from: json)
    #expect(value.name == "hi")
    #expect(value.count == 42)
  }

  // MARK: - proto3 defaults

  @Test("scalars: missing fields fall back to proto3 zero values")
  func scalarsMissingFallBackToDefaults() throws {
    let value = try decode(Goldens_Scalars.self, from: "{}")
    #expect(value.name == "")
    #expect(value.count == 0)
  }

  @Test("scalars: explicit JSON null falls back to proto3 zero values")
  func scalarsNullFallBackToDefaults() throws {
    let json = #"{"name":null,"count":null}"#
    let value = try decode(Goldens_Scalars.self, from: json)
    #expect(value.name == "")
    #expect(value.count == 0)
  }

  // MARK: - Lossy fallback

  @Test("scalars: type mismatch is lossy, not fatal")
  func scalarsTypeMismatchFallsBack() throws {
    // `count` is typed as Int32 in the emitted struct. A string here would
    // throw under strict Decodable; our emitter wraps each decode in `try?`
    // so the field falls back to its proto3 default instead.
    let json = #"{"name":"hi","count":"oops"}"#
    let value = try decode(Goldens_Scalars.self, from: json)
    #expect(value.name == "hi")
    #expect(value.count == 0)
  }

  // MARK: - Enums

  @Test("enum decodes proto names, stringified numbers, raw integers")
  func enumWireFormats() throws {
    let byName = try decode(Goldens_Account.self, from: #"{"status":"STATUS_ACTIVE"}"#)
    let byStringInt = try decode(Goldens_Account.self, from: #"{"status":"1"}"#)
    let byInt = try decode(Goldens_Account.self, from: #"{"status":1}"#)
    #expect(byName.status == .active)
    #expect(byStringInt.status == .active)
    #expect(byInt.status == .active)
  }

  @Test("enum: unknown string routes to UNRECOGNIZED")
  func enumUnknownString() throws {
    let value = try decode(Goldens_Account.self, from: #"{"status":"STATUS_FUTURE"}"#)
    if case .UNRECOGNIZED = value.status {
      // OK — unknown string maps to UNRECOGNIZED bucket with sentinel 0.
    } else {
      Issue.record("expected .UNRECOGNIZED, got \(value.status)")
    }
  }

  @Test("enum: missing falls back to the value at number 0")
  func enumMissing() throws {
    let value = try decode(Goldens_Account.self, from: "{}")
    #expect(value.status == .unspecified)
  }

  // MARK: - Repeated

  @Test("repeated scalar decodes from JSON array")
  func repeatedScalarPresent() throws {
    let value = try decode(
      Goldens_Article.self,
      from: #"{"keywords":["alpha","beta"]}"#
    )
    #expect(value.keywords == ["alpha", "beta"])
  }

  @Test("repeated message decodes from JSON array")
  func repeatedMessagePresent() throws {
    let value = try decode(
      Goldens_Article.self,
      from: #"{"tags":[{"label":"swift"},{"label":"protobuf"}]}"#
    )
    #expect(value.tags.map(\.label) == ["swift", "protobuf"])
  }

  @Test("repeated: missing falls back to []")
  func repeatedMissing() throws {
    let value = try decode(Goldens_Article.self, from: "{}")
    #expect(value.keywords.isEmpty)
    #expect(value.tags.isEmpty)
  }

  // MARK: - Map

  @Test("map decodes from JSON object")
  func mapPresent() throws {
    let value = try decode(
      Goldens_Sheet.self,
      from: #"{"counts":{"a":1,"b":2},"grid":{"home":{"value":"hi"}}}"#
    )
    #expect(value.counts == ["a": 1, "b": 2])
    #expect(value.grid["home"]?.value == "hi")
  }

  @Test("map: missing falls back to [:]")
  func mapMissing() throws {
    let value = try decode(Goldens_Sheet.self, from: "{}")
    #expect(value.counts.isEmpty)
    #expect(value.grid.isEmpty)
  }

  // MARK: - Nested

  @Test("nested message and enum decode together")
  func nestedDecode() throws {
    let value = try decode(
      Goldens_Tree.self,
      from: #"""
      {
        "kind": "KIND_BINARY",
        "root": {
          "id": "r",
          "children": [{"id": "a"}, {"id": "b"}]
        }
      }
      """#
    )
    #expect(value.kind == .binary)
    #expect(value.root.id == "r")
    #expect(value.root.children.map(\.id) == ["a", "b"])
  }

  // MARK: - Oneof

  @Test("oneof: first present member wins")
  func oneofText() throws {
    let value = try decode(
      Goldens_Notification.self,
      from: #"{"title":"hi","text":"hello"}"#
    )
    #expect(value.title == "hi")
    if case .text(let v) = value.body {
      #expect(v == "hello")
    } else {
      Issue.record("expected .text body, got \(String(describing: value.body))")
    }
  }

  @Test("oneof: message member decodes")
  func oneofImage() throws {
    let value = try decode(
      Goldens_Notification.self,
      from: #"{"image":{"url":"https://example.com/a.png"}}"#
    )
    if case .image(let v) = value.body {
      #expect(v.url == "https://example.com/a.png")
    } else {
      Issue.record("expected .image body, got \(String(describing: value.body))")
    }
  }

  @Test("oneof: absent stays nil")
  func oneofAbsent() throws {
    let value = try decode(Goldens_Notification.self, from: #"{"title":"hi"}"#)
    #expect(value.body == nil)
  }

  // MARK: - Cross-file dependency

  @Test("book references Author defined in library.proto")
  func crossFileReference() throws {
    let value = try decode(
      Goldens_Book.self,
      from: #"{"title":"Hi","author":{"name":"Ada"}}"#
    )
    #expect(value.title == "Hi")
    #expect(value.author.name == "Ada")
  }

  @Test("book with missing author keeps default (empty) Author")
  func crossFileMissingReference() throws {
    // Singular message refs are non-optional through Apple's emitted
    // getter; the storage stays nil, and the getter projects an empty
    // value. Either way, accessing .author shouldn't crash.
    let value = try decode(Goldens_Book.self, from: #"{"title":"Hi"}"#)
    #expect(value.title == "Hi")
    #expect(value.author.name == "")
  }

  // MARK: - Closed enum (proto2)

  @Test("closed enum: known wire values decode")
  func closedEnumKnown() throws {
    let value = try decode(Goldens_Pixel.self, from: #"{"color":"GREEN"}"#)
    #expect(value.color == .green)
  }

  @Test("closed enum: unknown wire value falls back to proto default")
  func closedEnumUnknown() throws {
    // proto2 / closed enum has no UNRECOGNIZED case; unknown wire
    // values land on the value at number 0 (.red here).
    let value = try decode(Goldens_Pixel.self, from: #"{"color":"FUCHSIA"}"#)
    #expect(value.color == .red)
  }

  // MARK: - Explicit presence (proto2 optional / proto3 optional)

  @Test("closed enum optional: present sets presence, absent leaves it unset")
  func closedEnumPresence() throws {
    // `color` is `optional Color` (proto2). A present value must flip
    // `hasColor`; an absent key must leave it false while still reading
    // back the proto default. Before the presence fix the decoder
    // eagerly assigned `.red`, so `hasColor` was always true.
    let present = try decode(Goldens_Pixel.self, from: #"{"color":"GREEN"}"#)
    #expect(present.hasColor)
    #expect(present.color == .green)

    let absent = try decode(Goldens_Pixel.self, from: "{}")
    #expect(!absent.hasColor)
    #expect(absent.color == .red)
  }

  @Test("proto3 optional scalars: present keys set hasXxx and their values")
  func optionalsPresent() throws {
    let json = #"""
    {
      "nickname": "ada",
      "retries": 7,
      "byteBudget": "9007199254740993",
      "muted": true,
      "shade": "SHADE_DARK",
      "plain": "x"
    }
    """#
    let value = try decode(Goldens_Settings.self, from: json)
    #expect(value.hasNickname)
    #expect(value.nickname == "ada")
    #expect(value.hasRetries)
    #expect(value.retries == 7)
    #expect(value.hasByteBudget)
    #expect(value.byteBudget == 9_007_199_254_740_993)  // int64 string wire
    #expect(value.hasMuted)
    #expect(value.muted == true)
    #expect(value.hasShade)
    #expect(value.shade == .dark)
    #expect(value.plain == "x")
  }

  @Test("proto3 optional scalars: absent keys leave hasXxx false (presence preserved)")
  func optionalsAbsentPreservePresence() throws {
    // The regression this whole fix is about. Each optional scalar must
    // stay unset when its key is missing — the decoder must not eagerly
    // materialize the proto3 zero, which would flip hasXxx to true.
    // Reads still project the proto3 default; only presence differs.
    let value = try decode(Goldens_Settings.self, from: "{}")
    #expect(!value.hasNickname)
    #expect(value.nickname == "")
    #expect(!value.hasRetries)
    #expect(value.retries == 0)
    #expect(!value.hasByteBudget)
    #expect(value.byteBudget == 0)
    #expect(!value.hasMuted)
    #expect(value.muted == false)
    #expect(!value.hasShade)
    #expect(value.shade == .unspecified)
    // `plain` has no presence (singular proto3 scalar); it just defaults.
    #expect(value.plain == "")
  }

  @Test("proto3 optional scalars: present-with-zero is distinct from absent")
  func optionalsPresentWithZero() throws {
    // The point of explicit presence: a field set to its zero value is
    // still "present". hasXxx must be true even though the value equals
    // the proto3 default.
    let json = #"{"nickname":"","retries":0,"muted":false,"shade":"SHADE_UNSPECIFIED"}"#
    let value = try decode(Goldens_Settings.self, from: json)
    #expect(value.hasNickname)
    #expect(value.nickname == "")
    #expect(value.hasRetries)
    #expect(value.retries == 0)
    #expect(value.hasMuted)
    #expect(value.muted == false)
    #expect(value.hasShade)
    #expect(value.shade == .unspecified)
  }

  @Test("proto3 optional scalar: explicit JSON null leaves the field unset")
  func optionalsNullStaysUnset() throws {
    // `null` decodes as "no value" via decodeIfPresent, so presence is
    // not set — consistent with an absent key.
    let value = try decode(Goldens_Settings.self, from: #"{"nickname":null,"retries":null}"#)
    #expect(!value.hasNickname)
    #expect(!value.hasRetries)
  }

  // MARK: - Int64 family (JSON string wire)

  @Test("int64/uint64: JSON string form decodes (proto3 spec, JS-unsafe range)")
  func int64StringWire() throws {
    // 9_007_199_254_740_993 = 2^53 + 1 — beyond JavaScript's safe int,
    // which is exactly why proto3 JSON serialises int64 as a string.
    let value = try decode(
      Goldens_Int64s.self,
      from: #"{"userId":"9007199254740993","byteSize":"18446744073709551615"}"#
    )
    #expect(value.userID == 9_007_199_254_740_993)
    #expect(value.byteSize == UInt64.max)
  }

  @Test("int64: raw JSON number form also decodes")
  func int64NumberWire() throws {
    let value = try decode(Goldens_Int64s.self, from: #"{"deltaValue":-42}"#)
    #expect(value.deltaValue == -42)
  }

  @Test("int64: missing falls back to 0")
  func int64Missing() throws {
    let value = try decode(Goldens_Int64s.self, from: "{}")
    #expect(value.userID == 0)
    #expect(value.byteSize == 0)
    #expect(value.childIds.isEmpty)
  }

  @Test("int64: type mismatch is lossy, not fatal")
  func int64TypeMismatch() throws {
    // Neither a number nor a parseable string → proto3 default, no throw.
    let value = try decode(Goldens_Int64s.self, from: #"{"userId":true}"#)
    #expect(value.userID == 0)
  }

  @Test("repeated int64: JSON number array decodes")
  func repeatedInt64() throws {
    // NOTE: repeated int64 is emitted as `[Int64]` without the
    // number-or-string fallback (uniform string handling would need a
    // custom Decoder). So the number-array form is what round-trips today.
    let value = try decode(Goldens_Int64s.self, from: #"{"childIds":[1,2,3]}"#)
    #expect(value.childIds == [1, 2, 3])
  }

  // MARK: - Helpers

  private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(type, from: data)
  }
}
