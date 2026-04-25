.PHONY: dev debug build clean release

release:
	@./scripts/release.sh $(VERSION)

dev:
	npx tauri dev

check:
	@cd src-tauri && cargo check
	@npx tsc --noEmit

debug: check
	@npx tauri build --debug

build: check
	npx tauri build

build-arm:
	npx tauri build --target aarch64-apple-darwin --debug

clean:
	rm -rf dist src-tauri/target
