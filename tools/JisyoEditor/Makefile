APP_NAME     := Kohojun
DISPLAY_NAME := 候補順
BUNDLE       := build/$(APP_NAME).app
RELEASE_BIN  := .build/release/JisyoEditor
CONTENTS     := $(BUNDLE)/Contents
INSTALL_DIR  := $(HOME)/Applications

.PHONY: build app icon install test run clean

## Compile the release binary.
build:
	swift build -c release

## Regenerate Resources/Kohojun.icns from the drawing script.
icon:
	rm -rf build/$(APP_NAME).iconset
	mkdir -p build Resources
	swift scripts/makeicon.swift build/$(APP_NAME).iconset mono
	iconutil -c icns build/$(APP_NAME).iconset -o Resources/$(APP_NAME).icns

## Assemble build/Kohojun.app around the release binary, then ad-hoc sign it.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS"
	@mkdir -p "$(CONTENTS)/Resources"
	cp "$(RELEASE_BIN)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	cp "Resources/$(APP_NAME).icns" "$(CONTENTS)/Resources/"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'	<key>CFBundleIdentifier</key>' \
		'	<string>org.codefirst.aquaskk.kohojun</string>' \
		'	<key>CFBundleName</key>' \
		'	<string>$(DISPLAY_NAME)</string>' \
		'	<key>CFBundleDisplayName</key>' \
		'	<string>$(DISPLAY_NAME)</string>' \
		'	<key>CFBundleExecutable</key>' \
		'	<string>$(APP_NAME)</string>' \
		'	<key>CFBundleIconFile</key>' \
		'	<string>$(APP_NAME)</string>' \
		'	<key>CFBundlePackageType</key>' \
		'	<string>APPL</string>' \
		'	<key>CFBundleShortVersionString</key>' \
		'	<string>0.2.0</string>' \
		'	<key>CFBundleVersion</key>' \
		'	<string>2</string>' \
		'	<key>LSMinimumSystemVersion</key>' \
		'	<string>13.0</string>' \
		'	<key>NSHighResolutionCapable</key>' \
		'	<true/>' \
		'	<key>NSPrincipalClass</key>' \
		'	<string>NSApplication</string>' \
		'</dict>' \
		'</plist>' > "$(CONTENTS)/Info.plist"
	codesign --force --sign - "$(BUNDLE)"
	@echo "Assembled and signed $(BUNDLE)"

## Copy the built app into ~/Applications (removing the pre-rename install too).
install: app
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app" "$(INSTALL_DIR)/JisyoEditor.app"
	cp -R "$(BUNDLE)" "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

## Run the unit tests.
test:
	swift test

## Run the app directly (debug).
run:
	swift run

## Remove build products.
clean:
	rm -rf build .build
