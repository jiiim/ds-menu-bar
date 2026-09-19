.PHONY: all build bundle clean run test icon release release-bundle signed-release-bundle local-dmg dmg checksum notarize verify-release install

APP_NAME := DS Menu Bar
APP_IDENTIFIER := com.jiiim.ds-menu-bar
APP_ARCH := arm64
MINIMUM_SYSTEM_VERSION := 26.0
APP := .build/debug/DS Menu Bar.app
RELEASE_APP := .build/release/DS Menu Bar.app
VERSION ?= $(shell plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
BUILD_NUMBER ?= $(shell plutil -extract CFBundleVersion raw Resources/Info.plist)
DIST_DIR ?= dist
DMG := $(DIST_DIR)/DS-Menu-Bar-v$(VERSION)-$(APP_ARCH).dmg
DMG_SHA256 := $(DMG).sha256
SIGN_IDENTITY ?=
NOTARY_PROFILE ?=

all: bundle

build:
	swift build --arch $(APP_ARCH)

test:
	swift test

# ProcessManager drives a live child process across three queues, so the
# sanitizer is the only thing that actually proves the main-queue confinement
# the type asserts. Slow; not part of `test`.
test-tsan:
	swift test --sanitize=thread

bundle: build
	./scripts/create-app-bundle.sh debug "$(APP)" "$(VERSION)" "$(BUILD_NUMBER)" "$(APP_IDENTIFIER)" "$(MINIMUM_SYSTEM_VERSION)" ""

run: bundle
	open -g "$(APP)"

# Regenerate Resources/AppIcon.icns from the generator script.
icon:
	swift scripts/generate-icon.swift

release:
	swift build -c release --arch $(APP_ARCH)

release-bundle: release
	./scripts/create-app-bundle.sh release "$(RELEASE_APP)" "$(VERSION)" "$(BUILD_NUMBER)" "$(APP_IDENTIFIER)" "$(MINIMUM_SYSTEM_VERSION)" ""

# Re-sign the release app for distribution with the hardened runtime and a
# trusted timestamp. SIGN_IDENTITY must be a Developer ID Application identity.
signed-release-bundle: release
	@test -n "$(SIGN_IDENTITY)" || (echo 'SIGN_IDENTITY is required (for example: Developer ID Application: Example Corp (TEAMID))' >&2; exit 1)
	./scripts/create-app-bundle.sh release "$(RELEASE_APP)" "$(VERSION)" "$(BUILD_NUMBER)" "$(APP_IDENTIFIER)" "$(MINIMUM_SYSTEM_VERSION)" "$(SIGN_IDENTITY)"

# Produces the same drag-to-Applications layout without requiring a certificate.
# The app uses an ad-hoc signature and is intended only for packaging checks.
local-dmg: release-bundle
	rm -f "$(DMG_SHA256)"
	./scripts/create-dmg.sh "$(RELEASE_APP)" "$(DMG)" "$(APP_NAME)"
	$(MAKE) checksum VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" DIST_DIR="$(DIST_DIR)"

# Produces a Developer ID-signed app inside a signed disk image.
dmg: signed-release-bundle
	rm -f "$(DMG_SHA256)"
	./scripts/create-dmg.sh "$(RELEASE_APP)" "$(DMG)" "$(APP_NAME)" "$(SIGN_IDENTITY)"

checksum:
	@test -f "$(DMG)" || (echo 'DMG not found: $(DMG)' >&2; exit 1)
	@hash=$$(shasum -a 256 "$(DMG)" | awk '{print $$1}'); printf '%s  %s\n' "$$hash" "$(notdir $(DMG))" > "$(DMG_SHA256)"

# NOTARY_PROFILE names credentials previously saved with notarytool
# store-credentials. Notarization is required for normal Gatekeeper acceptance.
notarize: dmg
	@test -n "$(NOTARY_PROFILE)" || (echo 'NOTARY_PROFILE is required' >&2; exit 1)
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"
	$(MAKE) checksum VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" DIST_DIR="$(DIST_DIR)"

# Checks the shipped artifact only. The app is verified inside the mounted
# image, so this target needs no .build tree and can verify a downloaded
# release as well as a local one.
verify-release:
	hdiutil verify "$(DMG)"
	codesign --verify --strict --verbose=2 "$(DMG)"
	spctl --assess --type open --context context:primary-signature --verbose=4 "$(DMG)"
	xcrun stapler validate "$(DMG)"
	./scripts/verify-dmg-app.sh "$(DMG)" "$(APP_NAME).app" "$(APP_IDENTIFIER)" "$(VERSION)" "$(BUILD_NUMBER)"
	@test -f "$(DMG_SHA256)" || (echo 'checksum not found: $(DMG_SHA256)' >&2; exit 1)
	@expected=$$(awk '{print $$1}' "$(DMG_SHA256)"); actual=$$(shasum -a 256 "$(DMG)" | awk '{print $$1}'); test "$$expected" = "$$actual"

# Build a release bundle and install it to /Applications, quitting a
# running instance first (stable install path keeps launch-services
# state consistent, matches athenaeum's build-app.sh).
install: release-bundle
	osascript -e 'tell application id "$(APP_IDENTIFIER)" to quit' 2>/dev/null || true
	sleep 1
	rm -rf "/Applications/DS Menu Bar.app"
	cp -R "$(RELEASE_APP)" /Applications/
	open -g "/Applications/DS Menu Bar.app"

clean:
	rm -rf .build
