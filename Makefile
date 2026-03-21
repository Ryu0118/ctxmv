SWIFTFORMAT := .nest/bin/swiftformat
SWIFTLINT := .nest/bin/swiftlint

.PHONY: install-commands format lint format-lint hooks test check

install-commands:
	./scripts/nest.sh bootstrap nestfile.yaml

format:
	@test -f "$(SWIFTFORMAT)" || (echo "Run: make install-commands" && exit 1)
	"$(SWIFTFORMAT)" --config .swiftformat .

lint:
	@test -f "$(SWIFTLINT)" || (echo "Run: make install-commands" && exit 1)
	"$(SWIFTLINT)" lint --config .swiftlint.yml --strict

format-lint: format lint

hooks:
	./scripts/setup-hooks.sh

test:
	swift test

check: format lint test
