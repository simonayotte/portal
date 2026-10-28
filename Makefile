export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
APP := build/Portal.app

.PHONY: build app clean

build:
	swift build

app:
	swift build -c release
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS
	cp .build/release/Portal $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	codesign --force --sign - $(APP)

clean:
	rm -rf .build build
