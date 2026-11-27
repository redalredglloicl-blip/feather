NAME := Zenith
SCHEME := Zenith
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
	base64 -D < Feather/Resources/zenith-icon-b64/zenith.png.b64 > Feather/Resources/Assets.xcassets/zenith.imageset/zenith.png
	base64 -D < Feather/Resources/zenith-icon-b64/zenith-transparent.png.b64 > Feather/Resources/Assets.xcassets/zenith-transparent.imageset/zenith-transparent.png
	base64 -D < Feather/Resources/zenith-icon-b64/zenith_dark.png.b64 > Feather/Resources/Assets.xcassets/AppIcon.appiconset/zenith_dark.png
	base64 -D < Feather/Resources/zenith-icon-b64/zenith_tint.png.b64 > Feather/Resources/Assets.xcassets/AppIcon.appiconset/zenith_tint.png
	base64 -D < Feather/Resources/icon-b64/archive.png.b64 > Feather/Resources/Assets.xcassets/icon-archive.imageset/archive.png
	base64 -D < Feather/Resources/icon-b64/category.png.b64 > Feather/Resources/Assets.xcassets/icon-category.imageset/category.png
	base64 -D < Feather/Resources/icon-b64/certificates.png.b64 > Feather/Resources/Assets.xcassets/icon-certificates.imageset/certificates.png
	base64 -D < Feather/Resources/icon-b64/certificates@2x.png.b64 > Feather/Resources/Assets.xcassets/icon-certificates.imageset/certificates@2x.png
	base64 -D < Feather/Resources/icon-b64/certificates@3x.png.b64 > Feather/Resources/Assets.xcassets/icon-certificates.imageset/certificates@3x.png
	base64 -D < Feather/Resources/icon-b64/delete.png.b64 > Feather/Resources/Assets.xcassets/icon-delete.imageset/delete.png
	base64 -D < Feather/Resources/icon-b64/download.png.b64 > Feather/Resources/Assets.xcassets/icon-download.imageset/download.png
	base64 -D < Feather/Resources/icon-b64/download@2x.png.b64 > Feather/Resources/Assets.xcassets/icon-download.imageset/download@2x.png
	base64 -D < Feather/Resources/icon-b64/download@3x.png.b64 > Feather/Resources/Assets.xcassets/icon-download.imageset/download@3x.png
	base64 -D < Feather/Resources/icon-b64/export.png.b64 > Feather/Resources/Assets.xcassets/icon-export.imageset/export.png
	base64 -D < Feather/Resources/icon-b64/favorite.png.b64 > Feather/Resources/Assets.xcassets/icon-favorite.imageset/favorite.png
	base64 -D < Feather/Resources/icon-b64/import.png.b64 > Feather/Resources/Assets.xcassets/icon-import.imageset/import.png
	base64 -D < Feather/Resources/icon-b64/info.png.b64 > Feather/Resources/Assets.xcassets/icon-info.imageset/info.png
	base64 -D < Feather/Resources/icon-b64/install.png.b64 > Feather/Resources/Assets.xcassets/icon-install.imageset/install.png
	base64 -D < Feather/Resources/icon-b64/library.png.b64 > Feather/Resources/Assets.xcassets/icon-library.imageset/library.png
	base64 -D < Feather/Resources/icon-b64/library@2x.png.b64 > Feather/Resources/Assets.xcassets/icon-library.imageset/library@2x.png
	base64 -D < Feather/Resources/icon-b64/library@3x.png.b64 > Feather/Resources/Assets.xcassets/icon-library.imageset/library@3x.png
	base64 -D < Feather/Resources/icon-b64/protection.png.b64 > Feather/Resources/Assets.xcassets/icon-protection.imageset/protection.png
	base64 -D < Feather/Resources/icon-b64/renew.png.b64 > Feather/Resources/Assets.xcassets/icon-renew.imageset/renew.png
	base64 -D < Feather/Resources/icon-b64/resign.png.b64 > Feather/Resources/Assets.xcassets/icon-resign.imageset/resign.png
	base64 -D < Feather/Resources/icon-b64/search.png.b64 > Feather/Resources/Assets.xcassets/icon-search.imageset/search.png
	base64 -D < Feather/Resources/icon-b64/settings.png.b64 > Feather/Resources/Assets.xcassets/icon-settings.imageset/settings.png
	base64 -D < Feather/Resources/icon-b64/settings@2x.png.b64 > Feather/Resources/Assets.xcassets/icon-settings.imageset/settings@2x.png
	base64 -D < Feather/Resources/icon-b64/settings@3x.png.b64 > Feather/Resources/Assets.xcassets/icon-settings.imageset/settings@3x.png
	base64 -D < Feather/Resources/icon-b64/sign.png.b64 > Feather/Resources/Assets.xcassets/icon-sign.imageset/sign.png
	base64 -D < Feather/Resources/icon-b64/sort.png.b64 > Feather/Resources/Assets.xcassets/icon-sort.imageset/sort.png
	base64 -D < Feather/Resources/zenith-icon-b64/zenith_extension.png.b64 > Feather/Resources/zenith_extension.png
	base64 -D < Feather/Resources/icon-b64/glyph.png.b64 > Feather/Resources/Assets.xcassets/Glyph.imageset/zenith.png
	base64 -D < Feather/Resources/icon-b64/appicon-zenith.png.b64 > Feather/Resources/AppIcon.icon/Assets/zenith.png
	base64 -D < Feather/Resources/icon-b64/appicon-zenith-5.png.b64 > Feather/Resources/AppIcon.icon/Assets/zenith-5.png

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
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO \
		DYLIB_CURRENT_VERSION=1 DYLIB_COMPATIBILITY_VERSION=1

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/Zenith.app
	chmod -R 0755 _build/Payload/Zenith.app
	codesign --force --sign - --timestamp=none _build/Payload/Zenith.app
	cp deps/* _build/Payload/Zenith.app/ || true

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/Zenith.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload/Zenith.app "packages/Zenith_Catalyst.zip"; \
	fi
