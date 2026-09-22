SHELL := /bin/zsh
ROOT := $(CURDIR)
SWIFT := env CLANG_MODULE_CACHE_PATH="$(ROOT)/.build/module-cache" SWIFT_MODULE_CACHE_PATH="$(ROOT)/.build/module-cache" swift
FLAGS := --disable-sandbox --cache-path "$(ROOT)/.build/cache" --config-path "$(ROOT)/.build/config" --security-path "$(ROOT)/.build/security" --scratch-path "$(ROOT)/.build"

.PHONY: bootstrap dev test lint build dist devices verify-audio
bootstrap:
	@mkdir -p .build/module-cache
	@swift --version

build: bootstrap
	$(SWIFT) build $(FLAGS) -c release
	python3 scripts/package.py
	codesign --force --sign - --identifier local.frontspark.mute-voice "build/Mute Voice.app"
	codesign --verify --strict "build/Mute Voice.app"

dev: build
	open "build/Mute Voice.app"

# Standalone distribution file: the signed app plus an /Applications shortcut.
dist: build
	@VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "build/Mute Voice.app/Contents/Info.plist"); \
	DMG="Mute-Voice-$$VERSION.dmg"; \
	rm -rf .build/dmg-stage "$$DMG"; \
	mkdir -p .build/dmg-stage; \
	cp -R "build/Mute Voice.app" .build/dmg-stage/; \
	ln -s /Applications .build/dmg-stage/Applications; \
	hdiutil create -volname "Mute Voice" -srcfolder .build/dmg-stage -ov -format UDZO "$$DMG"; \
	rm -rf .build/dmg-stage; \
	echo "Created $$DMG"

test: bootstrap
	$(SWIFT) test $(FLAGS)

lint:
	$(SWIFT) format lint --recursive --strict Sources Tests scripts/verify_audio.swift Package.swift
	PYTHONPYCACHEPREFIX="$(ROOT)/.build/python-cache" python3 -m py_compile scripts/package.py Tests/mock_api.py

devices: build
	"build/Mute Voice.app/Contents/MacOS/MuteVoice" --devices

# Opt-in: emits synthetic tones to BlackHole and measures only that virtual device.
verify-audio: bootstrap
	env CLANG_MODULE_CACHE_PATH="$(ROOT)/.build/module-cache" swiftc -parse-as-library Sources/Configuration.swift Sources/AudioOutput.swift scripts/verify_audio.swift -o .build/verify-audio
	.build/verify-audio .build/audio-verification.json
