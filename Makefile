.DEFAULT_GOAL := build

CONFIGURATION ?= Debug
BUILD_DIR := build
APP_PATH = $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/TalkToPrompt.app

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
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -derivedDataPath "$(BUILD_DIR)" build

run: build
	open "$(APP_PATH)"

install: CONFIGURATION = Release
install: build
	ditto "$(APP_PATH)" "/Applications/TalkToPrompt.app"

zip:
	@mkdir -p "$(BUILD_DIR)"
	@if [ -e "$(BUILD_DIR)/TalkToPrompt.zip" ]; then rm "$(BUILD_DIR)/TalkToPrompt.zip"; fi
	@git ls-files -z | xargs -0 zip -q -y -MM "$(BUILD_DIR)/TalkToPrompt.zip" --
	@echo "Created $(BUILD_DIR)/TalkToPrompt.zip"

test:
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -destination 'platform=macOS' -derivedDataPath "$(BUILD_DIR)" test

clean:
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -derivedDataPath "$(BUILD_DIR)" clean
