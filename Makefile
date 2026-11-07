.PHONY: build test app run install clean

# Build the speech runtime, workers and installers (target/release/bundle).
app:
	python3 scripts/build-desktop.py

build:
	cargo build --workspace

test:
	cargo test --workspace --locked

run:
	python3 scripts/build-desktop.py --no-bundle
	npm --prefix apps/desktop ci
	PRESSAY_RUNTIME_DIR="$(CURDIR)/apps/desktop/src-tauri/runtime" \
	PRESSAY_WORKER_PATH="$(CURDIR)/apps/desktop/src-tauri/binaries/pressay-asr-worker" \
	npm --prefix apps/desktop run dev

# Mac: build, then replace /Applications/Pressay.app.
install: app
	pkill -x pressay-desktop || true
	rm -rf /Applications/Pressay.app
	ditto target/release/bundle/macos/Pressay.app /Applications/Pressay.app
	open /Applications/Pressay.app

clean:
	cargo clean
