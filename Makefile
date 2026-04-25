.PHONY: dev debug build clean release

release:
	@./scripts/release.sh $(VERSION)

dev:
	npx tauri dev

debug:
	npx tauri build --debug

build:
	npx tauri build

build-arm:
	npx tauri build --target aarch64-apple-darwin --debug

clean:
	rm -rf dist src-tauri/target
