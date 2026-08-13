#!/usr/bin/env bash
#
# Regenerates every test fixture under
# Tests/protoc-gen-swift-jsonTests/Goldens, plus the byte-identical
# DecodingFixtures mirror. Run after editing a fixture .proto.
#
# What it produces, per <name>.proto in Goldens/Fixtures:
#   - <name>.descriptorset       protoc -descriptor_set_out
#   - <name>.apple.pb.swift      raw Apple protoc-gen-swift output
#   - Expected/<name>.pb.swift   our post-processed output
#   - DecodingFixtures/<name>.pb.swift   byte-identical mirror
#
# Requires `protoc` on PATH. Builds both swift-protobuf's protoc-gen-swift
# and our protoc-gen-swift-json in release mode before running anything.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/Tests/protoc-gen-swift-jsonTests/Goldens/Fixtures"
EXPECTED_DIR="$REPO_ROOT/Tests/protoc-gen-swift-jsonTests/Goldens/Expected"
DECODING_DIR="$REPO_ROOT/Tests/protoc-gen-swift-jsonTests/DecodingFixtures"

cd "$REPO_ROOT"

echo "==> Building plugins (release)…"
swift build -c release --product protoc-gen-swift-json >/dev/null

APPLE_PROTOC_GEN_SWIFT="$REPO_ROOT/.build/checkouts/swift-protobuf/.build/release/protoc-gen-swift"
if [[ ! -x "$APPLE_PROTOC_GEN_SWIFT" ]]; then
  echo "==> Building Apple swift-protobuf's protoc-gen-swift (one-off)…"
  (cd .build/checkouts/swift-protobuf && swift build -c release --product protoc-gen-swift >/dev/null)
fi

JSON_PLUGIN="$REPO_ROOT/.build/release/protoc-gen-swift-json"

mkdir -p "$EXPECTED_DIR" "$DECODING_DIR"

shopt -s nullglob
for proto in "$FIXTURES_DIR"/*.proto; do
  name="$(basename "$proto" .proto)"
  echo "==> Regenerating $name"

  # 1. descriptor set
  protoc \
    --descriptor_set_out="$FIXTURES_DIR/$name.descriptorset" \
    --include_imports \
    --include_source_info \
    --proto_path="$FIXTURES_DIR" \
    "$proto"

  # 2. Apple raw emit (checked in so GoldenTests is a true unit test)
  apple_tmp="$(mktemp -d)"
  protoc \
    --plugin=protoc-gen-swift="$APPLE_PROTOC_GEN_SWIFT" \
    --swift_out="$apple_tmp" \
    --proto_path="$FIXTURES_DIR" \
    "$proto"
  cp "$apple_tmp/$name.pb.swift" "$FIXTURES_DIR/$name.apple.pb.swift"
  rm -rf "$apple_tmp"

  # 3. Post-processed expected output
  PROTOC_GEN_SWIFT="$APPLE_PROTOC_GEN_SWIFT" protoc \
    --plugin=protoc-gen-swift-json="$JSON_PLUGIN" \
    --swift-json_out="$EXPECTED_DIR" \
    --proto_path="$FIXTURES_DIR" \
    "$proto"

  # 4. Mirror it into DecodingFixtures so the test target can compile it.
  cp "$EXPECTED_DIR/$name.pb.swift" "$DECODING_DIR/$name.pb.swift"
done

echo "==> Done. Re-run \`swift test\` to verify."
