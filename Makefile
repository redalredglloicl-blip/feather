NAME := Feather
SCHEME := Feather
PLATFORMS := iphoneos maccatalyst

TMP := $(TMPDIR)/$(NAME)
CERT_JSON_URL := https://backloop.dev/pack.json

.PHONY: all clean deps $(PLATFORMS)

all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

deps:
	rm -rf deps || true
	mkdir -p deps

	curl -fsSL "$(CERT_JSON_URL)" -o cert.json
	jq -r '.cert' cert.json > deps/server.crt
	jq -r '.key1, .key2' cert.json > deps/server.pem
	jq -r '.info.domains.commonName' cert.json > deps/commonName.txt


$(PLATFORMS): deps
	rm -rf _build

	# Zenith app icons live in the repo as base64 text (the GitHub API
	# cannot carry raw binary through this tooling) — decode them back
	# to real PNGs before the build reads the asset catalog.
	base64 -D < Feather/Resources/zenith-icon-b64/zenith.png.b64 > Feather/Resources/Assets.xcassets/AppIcon.appiconset/zenith.png
	base64 -D < Feather/Resources/zenith-icon-b64/zenith_dark.png.b64 > Feather/Resources/Assets.xcassets/AppIcon.appiconset/zenith_dark.png
	base64 -D < Feather/Resources/zenith-icon-b64/zenith_tint.png.b64 > Feather/Resources/Assets.xcassets/AppIcon.appiconset/zenith_tint.png

	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	xcodebuild \
		-project Feather.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "$$DEST" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/Feather.app
	chmod -R 0755 _build/Payload/Feather.app
	codesign --force --sign - --timestamp=none _build/Payload/Feather.app
	cp deps/* _build/Payload/Feather.app/ || true

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/Zenith.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload/Feather.app "packages/Feather_Catalyst.zip"; \
	fi
