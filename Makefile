build-rs:
	@./scripts/build-rust.sh

build-app: build-rs
	@./scripts/build-app.sh
