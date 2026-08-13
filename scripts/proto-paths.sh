#!/usr/bin/env bash
#
# Echoes the --proto_path flags for every dep under .proto-deps/. Use in
# protoc invocations after running scripts/install-common-protos.sh:
#
#   protoc $(scripts/proto-paths.sh) --proto_path=./your/protos ...

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DEPS_ROOT="${PROTO_DEPS_ROOT:-$REPO_ROOT/.proto-deps}"

if [[ ! -d "$PROTO_DEPS_ROOT" ]]; then
  echo "scripts/proto-paths.sh: $PROTO_DEPS_ROOT not found. Run scripts/install-common-protos.sh first." >&2
  exit 1
fi

printf -- "--proto_path=%s\n" \
  "$PROTO_DEPS_ROOT/googleapis" \
  "$PROTO_DEPS_ROOT/protoc-gen-validate"
