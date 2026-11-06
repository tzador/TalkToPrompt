.DEFAULT_GOAL := build

CONFIGURATION ?= Debug
BUILD_DIR := build
APP_PATH = $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/TalkToPrompt.app
INSTALLED_APP_PATH = /Applications/TalkToPrompt.app
# A certificate-backed identity keeps macOS permission grants valid across builds.
# Override SIGNING_IDENTITY for another certificate, or '-' for ad hoc signing.
SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ {print $$2; exit}')
SIGNING_FLAGS = CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$(if $(SIGNING_IDENTITY),$(SIGNING_IDENTITY),-)"

.PHONY: check build run install zip test clean

check:
	@if ! command -v xcrun >/dev/null 2>&1 || \
		! command -v xcodebuild >/dev/null 2>&1 || \
		! xcrun --find xcodebuild >/dev/null 2>&1 || \
		! xcodebuild -version >/dev/null 2>&1; then \
		printf '%s\n' \
			'Error: Xcode command line tools are missing or not configured.' \
			'' \
			'To install the standalone command line tools, run:' \
			'  xcode-select --install' \
			'' \
			'This app also requires full Xcode 26 or later; standalone tools are not sufficient.' \
			'Install Xcode from the Mac App Store, open it, and complete first-time setup.' \
			'Then select its developer tools:' \
			'  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer' \
			'' \
			'Run make check again after setup.'; \
		exit 1; \
	fi
	@echo "Xcode command line tools are available."

build: check
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -derivedDataPath "$(BUILD_DIR)" $(SIGNING_FLAGS) build

run: build
	@pkill -x TalkToPrompt 2>/dev/null || true
	ditto "$(APP_PATH)" "$(INSTALLED_APP_PATH)"
	open "$(INSTALLED_APP_PATH)"

install: CONFIGURATION = Release
install: build
	ditto "$(APP_PATH)" "$(INSTALLED_APP_PATH)"

zip:
	@mkdir -p "$(BUILD_DIR)"
	@if [ -e "$(BUILD_DIR)/TalkToPrompt.zip" ]; then rm "$(BUILD_DIR)/TalkToPrompt.zip"; fi
	@git ls-files -z | xargs -0 zip -q -y -MM "$(BUILD_DIR)/TalkToPrompt.zip" --
	@echo "Created $(BUILD_DIR)/TalkToPrompt.zip"

test:
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -destination 'platform=macOS' -derivedDataPath "$(BUILD_DIR)" $(SIGNING_FLAGS) test

clean:
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -derivedDataPath "$(BUILD_DIR)" clean
