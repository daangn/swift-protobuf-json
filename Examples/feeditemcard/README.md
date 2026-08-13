# Example — feed_item_card

A walkthrough that turns a small `.proto` into a `.pb.swift` and then
decodes a sample JSON payload with `JSONDecoder`. The proto models a
generic feed-item card and exercises a scalar, an enum, and
a repeated nested message in one file.

## Files

- [`feed_item_card.proto`](./feed_item_card.proto) — the source proto
- `Generated/feed_item_card.pb.swift` — produced by running the plugin
  (this directory is `.gitignore`d in the project root)

## Generate the Swift code

You need `protoc` and Apple's `protoc-gen-swift` on `PATH`, plus this
project's `protoc-gen-swift-json`.

From the repository root:

```sh
make release   # builds protoc-gen-swift-json into .build/release

cd Examples/feeditemcard
mkdir -p Generated

protoc \
  --plugin=protoc-gen-swift-json=../../.build/release/protoc-gen-swift-json \
  --swift-json_out=./Generated \
  --proto_path=. \
  ./feed_item_card.proto
```

The generated file imports `SwiftProtobuf` (for `UnknownStorage`,
`SwiftProtobuf.Enum`, etc., from Apple's struct shell) and ends with
`// MARK: - JSON Decodable` followed by `extension Example_Feed_V1_…: Decodable`
blocks added by this plugin.

## Use it

Drop the generated file into any Swift target that also links
`SwiftProtobuf`, then:

```swift
import Foundation

let json = #"""
{
  "id": "card-001",
  "kind": "CARD_KIND_ARTICLE",
  "title": "Hello",
  "sections": [
    { "header": "Intro", "bodyLines": ["one", "two"] }
  ]
}
"""#

let card = try JSONDecoder().decode(
  Example_Feed_V1_FeedItemCard.self,
  from: Data(json.utf8)
)

print(card.id)              // "card-001"
print(card.kind)            // CardKind.article
print(card.sections[0].bodyLines)  // ["one", "two"]
```

A few things to notice:

- `CARD_KIND_ARTICLE` decoded into the strongly-typed `.article`
  case. `"1"` or `1` on the wire would also work.
- The proto3 lowerCamelCase rule means JSON uses `bodyLines`, not
  `body_lines`. The plugin emits a matching `CodingKeys` entry.
- A `null` or missing `sections` would have collapsed to `[]` — no
  throw, no crash. Same for any field that decodes with the wrong
  JSON type.
