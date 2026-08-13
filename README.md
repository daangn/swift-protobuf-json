# swift-protobuf-json

A Swift `protoc` plugin for projects that exchange Protocol Buffers over JSON.

It runs Apple's `protoc-gen-swift`, preserves the generated Swift type declarations,
removes the binary wire-format extensions, and adds Foundation `Decodable`
conformances.

## Requirements

- Swift 6.0 or later
- `protoc`
- Apple's `protoc-gen-swift`

Install the required tools with Homebrew:

```sh
brew install protobuf swift-protobuf
```

## Install

Build the executable and copy it to a directory on your `PATH`:

```sh
swift build -c release --product protoc-gen-swift-json
cp .build/release/protoc-gen-swift-json /path/on/your/PATH/
```

The plugin looks for `protoc-gen-swift` next to its own executable, on `PATH`,
or at the path specified by the `PROTOC_GEN_SWIFT` environment variable.

## Generate Swift code

```sh
protoc \
  --proto_path=./proto \
  --swift-json_out=./Sources/Generated \
  ./proto/example/v1/*.proto
```

The generated filename is `<basename>.pb.swift`, matching Apple's plugin output.

### Imported protos

Every imported `.proto` must be reachable through `--proto_path`. The repository
provides optional scripts for common Google APIs and legacy
`validate/validate.proto` imports:

```sh
scripts/install-common-protos.sh
protoc \
  --proto_path=./proto \
  $(scripts/proto-paths.sh) \
  --swift-json_out=./Sources/Generated \
  ./proto/example/v1/*.proto
```

The legacy PGV schema is installed only so `protoc` can resolve imports. This
plugin does not generate or run validation code. If you use
[Buf](https://buf.build/), let Buf resolve the dependency graph instead.

## Options

Pass options with `--swift-json_opt`:

```sh
protoc \
  --swift-json_out=./Sources/Generated \
  --swift-json_opt='Visibility=Public,entry_points=Example_User' \
  ./proto/example.proto
```

| Option | Default | Description |
|---|---|---|
| `entry_points=<name>;<name>;...` | all types | Emits types reachable from the given top-level Swift type names |
| `coding_key_style=camel_case\|snake_case` | `camel_case` | Uses proto3 JSON lower-camel-case keys or original proto field names |
| `timestamp_decoder=<TypeName>` | none | Delegates `google.protobuf.Timestamp` JSON strings to a custom decoder |
| `additional_imports=<Module>;<Module>;...` | none | Adds imports needed by custom decoder types |
| `struct_decoder=true` | `false` | Decodes `google.protobuf.Struct`, `Value`, and `ListValue` recursively |

Other options are forwarded to Apple's `protoc-gen-swift`, including
`Visibility=Public`.

### Well-known types

When `entry_points` excludes an imported type, the plugin emits a minimal
`Decodable` stub so the generated code still compiles. Use `timestamp_decoder`
or `struct_decoder` when the JSON payload of those well-known types must be
preserved.

The timestamp delegate must expose this function:

```swift
public enum ExampleTimestampDecoder {
  public static func decode(_ value: String) throws -> Date { ... }
}
```

Then pass it to the plugin:

```sh
--swift-json_opt='entry_points=Example_User,timestamp_decoder=ExampleTimestampDecoder,additional_imports=ExampleDateSupport'
```

`struct_decoder=true` requires no delegate:

```sh
--swift-json_opt='entry_points=Example_User,struct_decoder=true'
```

## Decoding behavior

- Missing or `null` proto3 fields use their zero value.
- A field with an incompatible JSON value falls back to its proto3 default
  without failing the entire message.
- Enums accept their proto name, a stringified number, or a JSON number.
- Unknown values use Apple's `UNRECOGNIZED(Int)` case for open enums and the
  default case for closed enums.
- Oneofs try members in declaration order and keep the first value that decodes.

## Limitations

- Generated code supports JSON decoding only. `Encodable` is not generated.
- Binary protobuf serialization and parsing are not generated.
- Reflection, gRPC, Connect, and other transport layers are out of scope.
- Generated types still depend on the `SwiftProtobuf` runtime.
- This plugin requires Apple's `protoc-gen-swift`; it is not a standalone
  replacement for it.

## License

Apache 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

## Acknowledgements

- [apple/swift-protobuf](https://github.com/apple/swift-protobuf) provides the
  plugin SDK, generated type declarations, and runtime used by emitted code.
- [bufbuild/protobuf-es](https://github.com/bufbuild/protobuf-es) inspired the
  JSON-only positioning.
