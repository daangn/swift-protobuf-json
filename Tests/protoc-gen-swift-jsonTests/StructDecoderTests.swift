import Foundation
import SwiftProtobuf
import Testing

@testable import protoc_gen_swift_json

// Mirror of the recursive JSON `Decodable` that CrossPackageStubEmitter
// emits for `struct_decoder=true` (see `structBlock()`). The emitted *text*
// is verified by CrossPackageStubEmitterTests; this compiles the same code
// and exercises its decode behaviour end-to-end (the way the timestamp
// `decomposition` test mirrors the emitted arithmetic).

private struct _JSONObjectKey: Swift.CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

extension SwiftProtobuf.Google_Protobuf_Value: @retroactive Decodable {
  public init(from decoder: any Swift.Decoder) throws {
    self.init()
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self.nullValue = .nullValue
    } else if let bool = try? container.decode(Bool.self) {
      self.boolValue = bool
    } else if let number = try? container.decode(Double.self) {
      self.numberValue = number
    } else if let string = try? container.decode(String.self) {
      self.stringValue = string
    } else if let list = try? container.decode(SwiftProtobuf.Google_Protobuf_ListValue.self) {
      self.listValue = list
    } else if let structValue = try? container.decode(SwiftProtobuf.Google_Protobuf_Struct.self) {
      self.structValue = structValue
    }
  }
}

extension SwiftProtobuf.Google_Protobuf_ListValue: @retroactive Decodable {
  public init(from decoder: any Swift.Decoder) throws {
    self.init()
    var container = try decoder.unkeyedContainer()
    var values: [SwiftProtobuf.Google_Protobuf_Value] = []
    while !container.isAtEnd {
      values.append(try container.decode(SwiftProtobuf.Google_Protobuf_Value.self))
    }
    self.values = values
  }
}

extension SwiftProtobuf.Google_Protobuf_Struct: @retroactive Decodable {
  public init(from decoder: any Swift.Decoder) throws {
    self.init()
    let container = try decoder.container(keyedBy: _JSONObjectKey.self)
    var fields: [String: SwiftProtobuf.Google_Protobuf_Value] = [:]
    for key in container.allKeys {
      fields[key.stringValue] = try container.decode(
        SwiftProtobuf.Google_Protobuf_Value.self, forKey: key
      )
    }
    self.fields = fields
  }
}

@Suite("StructDecoder")
struct StructDecoderTests {

  @Test("decodes a mixed JSON object into Struct.fields")
  func decodesMixedObject() throws {
    let json = """
      {
        "s": "hello",
        "n": 42,
        "b": true,
        "nothing": null,
        "list": [1, "two", false],
        "nested": { "inner": "x" }
      }
      """.data(using: .utf8)!

    let value = try JSONDecoder().decode(SwiftProtobuf.Google_Protobuf_Struct.self, from: json)

    #expect(value.fields["s"]?.stringValue == "hello")
    #expect(value.fields["n"]?.numberValue == 42)
    #expect(value.fields["b"]?.boolValue == true)
    #expect(value.fields["nothing"]?.kind == .nullValue(.nullValue))

    let list = try #require(value.fields["list"]?.listValue)
    #expect(list.values.count == 3)
    #expect(list.values[0].numberValue == 1)
    #expect(list.values[1].stringValue == "two")
    #expect(list.values[2].boolValue == false)

    #expect(value.fields["nested"]?.structValue.fields["inner"]?.stringValue == "x")
  }

  @Test("empty object decodes to empty fields")
  func decodesEmptyObject() throws {
    let json = "{}".data(using: .utf8)!
    let value = try JSONDecoder().decode(SwiftProtobuf.Google_Protobuf_Struct.self, from: json)
    #expect(value.fields.isEmpty)
  }
}
