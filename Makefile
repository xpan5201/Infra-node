SHELL := /bin/bash
ROOT := $(CURDIR)
DIST := $(ROOT)/dist
VERSION := $(shell cat VERSION)
PKG_NAME := Infra-node-v$(VERSION)
SHELLCHECK_FILES := bootstrap.sh proxy-vps-foundation.sh bin/infra-node \
                    lib/*.sh lib/modules/*.sh tests/*.sh tests/lib/*.sh

.PHONY: all syntax smoke integration shellcheck check package clean

all: check

syntax:
	@find . -path './.git' -prune -o -path './dist' -prune -o -type f -name '*.sh' -print0 | xargs -0 -r -n1 bash -n
	@bash -n bin/infra-node
	@bash -n config/defaults.env

smoke:
	@INFRA_TEST_MODE=1 bash tests/smoke.sh

integration:
	@INFRA_TEST_MODE=1 bash tests/integration-install.sh

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x $(SHELLCHECK_FILES); \
	else \
	  printf 'shellcheck 未安装，跳过（CI 会执行）。\n'; \
	fi

check: syntax smoke integration shellcheck

package: check
	@command -v zip >/dev/null 2>&1 || { printf 'zip 未安装；请先 apt-get install -y zip\n' >&2; exit 1; }
	@rm -rf "$(DIST)/$(PKG_NAME)" "$(DIST)/$(PKG_NAME).zip"
	@mkdir -p "$(DIST)/$(PKG_NAME)"
	@tar --exclude='./.git' --exclude='./dist' --exclude='./docs' -cf - . | tar -C "$(DIST)/$(PKG_NAME)" -xf -
	@cd "$(DIST)" && zip -qr "$(PKG_NAME).zip" "$(PKG_NAME)"
	@printf '%s\n' "$(DIST)/$(PKG_NAME).zip"

clean:
	@rm -rf "$(DIST)"
