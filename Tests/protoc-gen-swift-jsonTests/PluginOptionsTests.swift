import Foundation
import Testing

@testable import protoc_gen_swift_json

@Suite("PluginOptions")
struct PluginOptionsTests {
  @Test("empty parameter yields defaults")
  func defaults() throws {
    let options = try PluginOptions(rawParameter: "")
    #expect(options.entryPoints.isEmpty)
    #expect(options.codingKeyStyle == .camelCase)
    #expect(options.timestampDecoder == nil)
    #expect(options.additionalImports.isEmpty)
  }

  @Test("entry_points parses semicolon-separated list")
  func entryPoints() throws {
    let options = try PluginOptions(
      rawParameter: "entry_points=Foo;Bar;Baz"
    )
    #expect(options.entryPoints == ["Foo", "Bar", "Baz"])
  }

  @Test(
    "지원하지 않는 option을 전달하면 명확한 오류를 반환해요",
    arguments: ["doc_comments", "module_name", "skip_unresolved_imports"]
  )
  func unsupportedOption(key: String) {
    #expect(throws: PluginOptionError.self) {
      _ = try PluginOptions(rawParameter: "\(key)=true")
    }
  }

  @Test("unknown key is forwarded to Apple's plugin")
  func unknownKey() throws {
    let options = try PluginOptions(rawParameter: "Visibility=Public,garbage=1")
    #expect(options.forwardableRawParameter == "Visibility=Public,garbage=1")
  }

  @Test("known keys do not survive into the forwarded parameter")
  func knownKeysStripped() throws {
    let options = try PluginOptions(
      rawParameter: "entry_points=Foo,Visibility=Public,coding_key_style=snake_case"
    )
    #expect(options.forwardableRawParameter == "Visibility=Public")
  }

  @Test("malformed pair throws")
  func malformed() {
    #expect(throws: PluginOptionError.self) {
      _ = try PluginOptions(rawParameter: "no_value")
    }
  }

  @Test("timestamp_decoder stores delegate type name")
  func timestampDecoder() throws {
    let set = try PluginOptions(rawParameter: "timestamp_decoder=ExampleTimestampDecoder")
    #expect(set.timestampDecoder == "ExampleTimestampDecoder")

    let unset = try PluginOptions(rawParameter: "")
    #expect(unset.timestampDecoder == nil)
  }

  @Test("struct_decoder parses bool, defaults to false")
  func structDecoder() throws {
    let on = try PluginOptions(rawParameter: "struct_decoder=true")
    #expect(on.structDecoder == true)

    let off = try PluginOptions(rawParameter: "struct_decoder=false")
    #expect(off.structDecoder == false)

    let unset = try PluginOptions(rawParameter: "")
    #expect(unset.structDecoder == false)
  }

  @Test("additional_imports parses semicolon-separated module list")
  func additionalImports() throws {
    let options = try PluginOptions(
      rawParameter: "additional_imports=ModuleA;ModuleB"
    )
    #expect(options.additionalImports == ["ModuleA", "ModuleB"])
  }

  @Test("coding_key_style parses snake_case / camel_case, rejects unknown")
  func codingKeyStyle() throws {
    let snake = try PluginOptions(rawParameter: "coding_key_style=snake_case")
    let camel = try PluginOptions(rawParameter: "coding_key_style=camel_case")
    #expect(snake.codingKeyStyle == .snakeCase)
    #expect(camel.codingKeyStyle == .camelCase)

    // Case-insensitive aliases are accepted.
    let snakeAlias = try PluginOptions(rawParameter: "coding_key_style=snakeCase")
    #expect(snakeAlias.codingKeyStyle == .snakeCase)

    // An unrecognised value is a hard error, not a silent default.
    #expect(throws: PluginOptionError.self) {
      _ = try PluginOptions(rawParameter: "coding_key_style=kebab-case")
    }
  }
}
