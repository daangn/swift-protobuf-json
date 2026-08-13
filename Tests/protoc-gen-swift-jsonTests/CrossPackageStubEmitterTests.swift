import Foundation
import Testing

@testable import protoc_gen_swift_json

@Suite("CrossPackageStubEmitter")
struct CrossPackageStubEmitterTests {

  @Test("empty input returns nil")
  func emptyInput() {
    #expect(CrossPackageStubEmitter.emit(types: []) == nil)
  }

  @Test("imported stub falls back to zero-value decoder by default")
  func defaultImportedStub() throws {
    let output = try #require(
      CrossPackageStubEmitter.emit(
        types: [
          .init(
            swiftFullName: "SwiftProtobuf.Google_Protobuf_Timestamp",
            isEnum: false,
            isImported: true
          )
        ]
      )
    )
    #expect(output.contains("extension SwiftProtobuf.Google_Protobuf_Timestamp: @retroactive Decodable"))
    #expect(output.contains("init(from decoder: any Swift.Decoder) throws { self.init() }"))
    // The default path must NOT call any external delegate.
    #expect(!output.contains(".decode("))
  }

  @Test("timestamp_decoder substitutes delegate and emits real decoder body")
  func timestampDecoderOption() throws {
    let output = try #require(
      CrossPackageStubEmitter.emit(
        types: [
          .init(
            swiftFullName: "SwiftProtobuf.Google_Protobuf_Timestamp",
            isEnum: false,
            isImported: true
          )
        ],
        options: .init(
          timestampDecoder: "ExampleTimestampDecoder",
          additionalImports: ["ExampleDateSupport"]
        )
      )
    )
    #expect(output.contains("import ExampleDateSupport"))
    #expect(output.contains("extension SwiftProtobuf.Google_Protobuf_Timestamp: @retroactive Decodable"))
    #expect(output.contains("try ExampleTimestampDecoder.decode(raw)"))
    #expect(output.contains("self.seconds = seconds"))
    #expect(output.contains("self.nanos = nanos"))
  }

  // MARK: - Date → seconds/nanos decomposition (mirror of emitted code)

  /// The emitted timestamp decoder splits a `Date` into proto's
  /// `seconds` / `nanos` fields. The split happens inside generated
  /// code, so this test mirrors the exact arithmetic. Only anchors near
  /// the epoch are used here — `Date` stores time as `Double` and loses
  /// sub-millisecond precision for far-future timestamps, which would
  /// produce a misleading failure unrelated to the emit.
  @Test(
    "decomposition: matches the inline arithmetic in the emitted stub",
    arguments: [
      // (TimeInterval since 1970, expected seconds, expected nanos)
      (TimeInterval(0), Int64(0), Int32(0)),
      (TimeInterval(0.5), Int64(0), Int32(500_000_000)),
      (TimeInterval(1.123), Int64(1), Int32(123_000_000)),
    ] as [(TimeInterval, Int64, Int32)]
  )
  func decomposition(_ interval: TimeInterval, expectedSeconds: Int64, expectedNanos: Int32) {
    let wholeSeconds = interval.rounded(.down)
    let seconds = Int64(wholeSeconds)
    let nanos = Int32(((interval - wholeSeconds) * 1_000_000_000).rounded())

    #expect(seconds == expectedSeconds)
    #expect(nanos == expectedNanos)
  }

  @Test("timestamp_decoder does not affect other imported well-known types")
  func leavesOtherWellKnownTypesUntouched() throws {
    let output = try #require(
      CrossPackageStubEmitter.emit(
        types: [
          .init(
            swiftFullName: "SwiftProtobuf.Google_Protobuf_Struct",
            isEnum: false,
            isImported: true
          )
        ],
        options: .init(timestampDecoder: "ExampleTimestampDecoder", additionalImports: [])
      )
    )
    #expect(output.contains("extension SwiftProtobuf.Google_Protobuf_Struct: @retroactive Decodable"))
    #expect(output.contains("init(from decoder: any Swift.Decoder) throws { self.init() }"))
  }

  // MARK: - struct_decoder

  @Test("struct_decoder emits real recursive Struct/Value/ListValue decoders")
  func structDecoderOption() throws {
    let output = try #require(
      CrossPackageStubEmitter.emit(
        types: [
          .init(
            swiftFullName: "SwiftProtobuf.Google_Protobuf_Struct",
            isEnum: false,
            isImported: true
          )
        ],
        options: .init(timestampDecoder: nil, additionalImports: [], structDecoder: true)
      )
    )
    // All three well-known JSON types get a real conformance…
    #expect(output.contains("extension SwiftProtobuf.Google_Protobuf_Struct: @retroactive Decodable"))
    #expect(output.contains("extension SwiftProtobuf.Google_Protobuf_Value: @retroactive Decodable"))
    #expect(output.contains("extension SwiftProtobuf.Google_Protobuf_ListValue: @retroactive Decodable"))
    #expect(output.contains("struct _JSONObjectKey: Swift.CodingKey"))
    // …populating real storage rather than dropping to the zero value.
    #expect(output.contains("self.fields = fields"))
    #expect(!output.contains("init(from decoder: any Swift.Decoder) throws { self.init() }"))
  }

  @Test("struct_decoder off keeps the Struct zero-stub")
  func structDecoderDefaultsToZeroStub() throws {
    let output = try #require(
      CrossPackageStubEmitter.emit(
        types: [
          .init(
            swiftFullName: "SwiftProtobuf.Google_Protobuf_Struct",
            isEnum: false,
            isImported: true
          )
        ]
      )
    )
    #expect(output.contains("init(from decoder: any Swift.Decoder) throws { self.init() }"))
    #expect(!output.contains("Google_Protobuf_Value: @retroactive Decodable"))
  }
}
