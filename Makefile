APP_NAME = VirtManagerModern
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
DEPS_PREFIX = third_party/prefix
export PKG_CONFIG_PATH = $(CURDIR)/$(DEPS_PREFIX)/lib/pkgconfig

.PHONY: all deps build app run run-dev test clean distclean

all: app

# Build all C dependencies from pinned upstream releases (no Homebrew needed,
# only Xcode Command Line Tools). Idempotent — cached via third_party/stamps.
deps:
	./Scripts/build-deps.sh

build: deps
	swift build -c release --product $(APP_NAME)

# Assemble a double-clickable .app bundle around the release binary.
app: build
	@echo "Assembling $(APP_BUNDLE)…"
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources" "$(CONTENTS)/Frameworks"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Bundle any dynamic libraries SwiftPM produced (e.g. RoyalVNCKit).
	@for dylib in $(BUILD_DIR)/*.dylib; do \
		[ -e "$$dylib" ] && cp "$$dylib" "$(CONTENTS)/Frameworks/" || true; \
	done
	@# Let the executable find the bundled dylibs.
	@install_name_tool -add_rpath "@executable_path/../Frameworks" \
		"$(CONTENTS)/MacOS/$(APP_NAME)" 2>/dev/null || true
	@# Standalone bundle: embed the Homebrew dylib closure, de-brew load paths.
	@./Scripts/embed-dylibs.sh "$(APP_BUNDLE)"
	@# Re-sign (ad hoc) — install_name_tool invalidated the signatures.
	@codesign --force --deep --sign - "$(APP_BUNDLE)" 2>/dev/null || true
	@echo "Built $(APP_BUNDLE)"

run: app
	open "$(APP_BUNDLE)"

# Development run: includes the built-in test:///default libvirt connection.
run-dev: app
	open --env VMM_TEST_DRIVER=1 "$(APP_BUNDLE)"

test:
	swift test

clean:
	rm -rf "$(APP_BUNDLE)"
	swift package clean

# Also wipe the from-source dependency builds.
distclean: clean
	rm -rf third_party
