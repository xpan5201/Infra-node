SHELL := /bin/bash
ROOT := $(CURDIR)
DIST := $(ROOT)/dist
VERSION := $(shell cat VERSION)

.PHONY: all syntax smoke integration check package clean

all: check

syntax:
	@find . -path './.git' -prune -o -path './dist' -prune -o -type f -name '*.sh' -print0 | xargs -0 -r -n1 bash -n
	@bash -n bin/infra-node
	@bash -n config/defaults.env

smoke:
	@INFRA_TEST_MODE=1 bash tests/smoke.sh

integration:
	@INFRA_TEST_MODE=1 bash tests/integration-install.sh

check: syntax smoke integration
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -x bootstrap.sh proxy-vps-foundation.sh bin/infra-node lib/*.sh lib/modules/*.sh tests/smoke.sh tests/integration-install.sh || true

package: check
	@rm -rf "$(DIST)/Infra-node-v$(VERSION)-fixed" "$(DIST)/Infra-node-v$(VERSION)-fixed.zip"
	@mkdir -p "$(DIST)/Infra-node-v$(VERSION)-fixed"
	@tar --exclude='./.git' --exclude='./dist' -cf - . | tar -C "$(DIST)/Infra-node-v$(VERSION)-fixed" -xf -
	@cd "$(DIST)" && zip -qr "Infra-node-v$(VERSION)-fixed.zip" "Infra-node-v$(VERSION)-fixed"
	@printf '%s\n' "$(DIST)/Infra-node-v$(VERSION)-fixed.zip"

clean:
	@rm -rf "$(DIST)"
