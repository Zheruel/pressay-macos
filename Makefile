.PHONY: build test icon app dmg run clean

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.build/ModuleCache
export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH

build:
	swift build

test:
	xcrun swift test --disable-sandbox

icon:
	./scripts/generate-icon.sh

app:
	./scripts/build-app.sh

dmg:
	./scripts/package-dmg.sh

run: app
	open .build/Pressay.app

clean:
	swift package clean
