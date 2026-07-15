DMG_PATH ?= release/Orbit-local-AppleSilicon.dmg
VOLUME_NAME ?= Orbit

build-rs:
	@./scripts/build-rust.sh

build-app: build-rs
	@./scripts/build-app.sh

build-dmg: build-app
	@APP_PATH="$$(cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -showBuildSettings | grep -m1 "BUILT_PRODUCTS_DIR" | awk '{print $$3}')/Orbit.app"; \
	./scripts/build-dmg.sh "$$APP_PATH" "$(DMG_PATH)" "$(VOLUME_NAME)"
