.DEFAULT_GOAL := build

CONFIGURATION ?= Debug
BUILD_DIR := build
APP_PATH := $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/TalkToPrompt.app

.PHONY: build run test clean

build:
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -derivedDataPath "$(BUILD_DIR)" build

run: build
	open "$(APP_PATH)"

test:
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -destination 'platform=macOS' -derivedDataPath "$(BUILD_DIR)" test

clean:
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -derivedDataPath "$(BUILD_DIR)" clean
