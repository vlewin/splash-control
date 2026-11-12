.PHONY: help build app check test lint verify run screenshot

help: ## show targets
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

# One toolchain for build, test and app: Homebrew when installed, otherwise the
# Command Line Tools'. Everything below runs on whichever this resolves to, so a
# green `make verify` exercises the same compiler that assembles dist/Splash.app.
SWIFT_TOOLCHAIN ?= $(if $(wildcard /opt/homebrew/opt/swift/bin/swift),/opt/homebrew/opt/swift)
export PATH := $(if $(SWIFT_TOOLCHAIN),$(SWIFT_TOOLCHAIN)/bin:)$(PATH)

# The Testing macro plugin sits in different places per toolchain: CLT buries
# libTestingMacros.dylib under lib/swift/host/plugins/testing, a directory the
# macro loader does not scan; Homebrew installs it where the loader looks. Pick
# the flag from the chosen compiler instead of hardwiring xcrun.
SWIFT_BIN := $(if $(SWIFT_TOOLCHAIN),$(SWIFT_TOOLCHAIN)/bin/swift,$(shell xcrun --find swift))
SWIFT_PREFIX := $(patsubst %bin/swift,%,$(SWIFT_BIN))
TESTING_PLUGINS := $(SWIFT_PREFIX)lib/swift/host/plugins/testing
TESTING_PLUGIN_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

# Default to installed release SDK when CLT SDK is mismatched with Swift compiler
SDKROOT ?= $(shell [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ] && echo /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk || xcrun --show-sdk-path)
export SDKROOT

build: ## compile inner loop
	swift build

app: ## assemble dist/Splash.app
	bash Scripts/make-app.sh

check: ## script suites (core + agent-status)
	bash Scripts/check_core.sh && bash Scripts/check_agent_status.sh

test: ## swift-testing suite
	swift test $(TESTING_PLUGIN_FLAGS)

lint: ## formatter gate, zero warnings (strict)
	xcrun swift-format lint --strict --recursive Sources

verify: ## all hard gates: check + test + lint, every one green
	make check && make test && make lint

run: app ## quit, rebuild, relaunch from dist, show process path
	osascript -e 'quit app "Splash"' 2>/dev/null; sleep 1
	open dist/Splash.app && sleep 2 && ps -Ao pid,command | grep "[S]plashControl"

VIEW ?= live
screenshot: ## capture tab (VIEW=settings, default: live)
	./Scripts/screenshot.sh /tmp/shot-$(VIEW).png $(VIEW)
