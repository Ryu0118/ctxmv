# Developer tasks for ctxmv (Swift Package).
# Requires swiftformat and swiftlint on PATH (e.g. brew install swiftformat swiftlint).

SWIFTFORMAT := $(shell command -v swiftformat 2>/dev/null)
SWIFTLINT := $(shell command -v swiftlint 2>/dev/null)

.PHONY: format lint format-lint hooks test ci

format:
	@if [ -z "$(SWIFTFORMAT)" ]; then \
		echo "swiftformat not found. Install: brew install swiftformat"; \
		exit 1; \
	fi
	"$(SWIFTFORMAT)" --config .swiftformat .

lint:
	@if [ -z "$(SWIFTLINT)" ]; then \
		echo "swiftlint not found. Install: brew install swiftlint"; \
		exit 1; \
	fi
	"$(SWIFTLINT)" lint --config .swiftlint.yml --strict

format-lint: format lint

hooks:
	./scripts/setup-hooks.sh

test:
	swift test

ci: format lint test
