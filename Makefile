# swift-protobuf-json — top-level developer targets.

.PHONY: build test release install regen-goldens clean help

PREFIX ?= /usr/local

help: ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Debug build of protoc-gen-swift-json.
	swift build --product protoc-gen-swift-json

release: ## Release build of protoc-gen-swift-json.
	swift build -c release --product protoc-gen-swift-json

test: ## Run the full test suite.
	swift test

install: release ## Install the release binary to $(PREFIX)/bin (defaults to /usr/local/bin).
	@mkdir -p "$(PREFIX)/bin"
	install -m 0755 .build/release/protoc-gen-swift-json "$(PREFIX)/bin/protoc-gen-swift-json"
	@echo "Installed to $(PREFIX)/bin/protoc-gen-swift-json"

regen-goldens: ## Regenerate every test fixture from its .proto.
	scripts/regen-goldens.sh

install-deps: ## Clone googleapis + protoc-gen-validate into .proto-deps/.
	scripts/install-common-protos.sh

clean: ## Remove build artifacts.
	swift package clean
	rm -rf .build
