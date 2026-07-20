APP_NAME    := JisyoEditor
BUNDLE      := build/$(APP_NAME).app
RELEASE_BIN := .build/release/$(APP_NAME)
CONTENTS    := $(BUNDLE)/Contents
INSTALL_DIR := $(HOME)/Applications

.PHONY: build app install test run clean

## Compile the release binary.
build:
	swift build -c release

## Assemble build/JisyoEditor.app around the release binary, then ad-hoc sign it.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS"
	@mkdir -p "$(CONTENTS)/Resources"
	cp "$(RELEASE_BIN)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'	<key>CFBundleIdentifier</key>' \
		'	<string>org.codefirst.aquaskk.jisyoeditor</string>' \
		'	<key>CFBundleName</key>' \
		'	<string>JisyoEditor</string>' \
		'	<key>CFBundleDisplayName</key>' \
		'	<string>JisyoEditor</string>' \
		'	<key>CFBundleExecutable</key>' \
		'	<string>JisyoEditor</string>' \
		'	<key>CFBundlePackageType</key>' \
		'	<string>APPL</string>' \
		'	<key>CFBundleShortVersionString</key>' \
		'	<string>0.1.0</string>' \
		'	<key>CFBundleVersion</key>' \
		'	<string>1</string>' \
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

## Copy the built app into ~/Applications.
install: app
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
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
