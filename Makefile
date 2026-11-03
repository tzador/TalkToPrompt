.DEFAULT_GOAL := build

CONFIGURATION ?= Debug
BUILD_DIR := build
APP_PATH := $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/TalkToPrompt.app

.PHONY: build run clean

build:
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -derivedDataPath "$(BUILD_DIR)" build

run: build
	open "$(APP_PATH)"

clean:
	xcodebuild -project TalkToPrompt.xcodeproj -scheme TalkToPrompt -configuration "$(CONFIGURATION)" -derivedDataPath "$(BUILD_DIR)" clean
