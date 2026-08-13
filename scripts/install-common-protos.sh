#!/usr/bin/env bash
#
# Clones two common external proto repositories that projects may transitively
# depend on into a known location. The protoc-gen-validate checkout preserves
# import resolution for legacy `validate/validate.proto` schemas; it does not
# enable validation generation or runtime behavior. Use `scripts/proto-paths.sh`
# afterwards to expand the repositories into the `--proto_path` flags you'll
# feed to protoc.
#
# Designed to be safe to re-run: existing clones are fetched + reset to
# origin/main rather than re-cloned. Tag a specific commit by exporting
# GOOGLEAPIS_REF / VALIDATE_REF before invoking.
#
# Default install root is `.proto-deps/` next to this repo. Override with
# PROTO_DEPS_ROOT.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DEPS_ROOT="${PROTO_DEPS_ROOT:-$REPO_ROOT/.proto-deps}"

GOOGLEAPIS_REF="${GOOGLEAPIS_REF:-master}"
VALIDATE_REF="${VALIDATE_REF:-main}"

mkdir -p "$PROTO_DEPS_ROOT"

clone_or_update() {
  local name="$1" url="$2" ref="$3"
  local dest="$PROTO_DEPS_ROOT/$name"
  if [[ -d "$dest/.git" ]]; then
    echo "==> $name: fetching $ref"
    git -C "$dest" fetch --depth 1 origin "$ref"
    git -C "$dest" reset --hard FETCH_HEAD
  else
    echo "==> $name: cloning $url@$ref"
    git clone --depth 1 --branch "$ref" "$url" "$dest"
  fi
}

clone_or_update googleapis https://github.com/googleapis/googleapis.git "$GOOGLEAPIS_REF"
clone_or_update protoc-gen-validate https://github.com/bufbuild/protoc-gen-validate.git "$VALIDATE_REF"

echo
echo "Installed proto deps under $PROTO_DEPS_ROOT/"
echo "Feed them to protoc via:"
echo "  --proto_path=$PROTO_DEPS_ROOT/googleapis \\"
echo "  --proto_path=$PROTO_DEPS_ROOT/protoc-gen-validate"
