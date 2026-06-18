#!/bin/zsh
# Developer ID sign + notarize VirtManagerModern.app for distribution.
#
# Prerequisites (after Apple Developer enrollment confirms):
#   1. Developer ID Application certificate in the login keychain
#   2. Notary credentials — either:
#        xcrun notarytool store-credentials AC_NOTARY \
#          --apple-id YOU@EMAIL --team-id TEAMID --password APP-SPECIFIC-PASSWORD
#      or set NOTARY_API_KEY / NOTARY_API_KEY_ID / NOTARY_API_ISSUER_ID
#
# Usage:
#   ./Scripts/sign-and-notarize.sh VirtManagerModern.app          # sign + notarize + staple + zip
#   ./Scripts/sign-and-notarize.sh --sign-only VirtManagerModern.app
#
# Environment overrides:
#   CODESIGN_IDENTITY   — defaults to the first "Developer ID Application" identity
#   ENTITLEMENTS        — defaults to Resources/VirtManagerModern.entitlements
#   NOTARY_PROFILE      — keychain profile name (default: AC_NOTARY)
set -euo pipefail

ROOT="${0:A:h:h}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/Resources/VirtManagerModern.entitlements}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
SIGN_ONLY=false
APP=""

usage() {
    cat <<'EOF'
Usage: sign-and-notarize.sh [--sign-only] VirtManagerModern.app

  --sign-only   Developer ID sign and verify; skip notarization/stapling/zip.

Environment:
  CODESIGN_IDENTITY    Developer ID Application identity (auto-detected if unset)
  ENTITLEMENTS         Path to entitlements plist
  NOTARY_PROFILE       Keychain profile for notarytool (default: AC_NOTARY)
  NOTARY_API_KEY       App Store Connect API key (.p8 path) — alternative to profile
  NOTARY_API_KEY_ID    API key ID
  NOTARY_API_ISSUER_ID API issuer ID
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --sign-only) SIGN_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [[ -n "$APP" ]]; then
                echo "Unexpected argument: $1" >&2; usage >&2; exit 1
            fi
            APP="$1"; shift
            ;;
    esac
done

[[ -n "$APP" ]] || { usage >&2; exit 1 }
[[ -d "$APP" ]] || { echo "App bundle not found: $APP" >&2; exit 1 }
[[ -f "$ENTITLEMENTS" ]] || { echo "Entitlements not found: $ENTITLEMENTS" >&2; exit 1 }

APP_NAME="$(basename "$APP" .app)"
BIN="$APP/Contents/MacOS/$APP_NAME"
FRAMEWORKS="$APP/Contents/Frameworks"
[[ -f "$BIN" ]] || { echo "Executable not found: $BIN" >&2; exit 1 }

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(
        security find-identity -v -p codesigning \
            | awk -F'"' '/Developer ID Application/ { print $2; exit }'
    )"
fi
[[ -n "$CODESIGN_IDENTITY" ]] || {
    echo "No Developer ID Application certificate in the keychain." >&2
    echo "Install one from developer.apple.com once enrollment confirms." >&2
    exit 1
}

echo "Signing with: $CODESIGN_IDENTITY"

sign() {
    local target="$1"
    local with_entitlements="${2:-false}"
    local -a args=(
        --force
        --options runtime
        --timestamp
        --sign "$CODESIGN_IDENTITY"
    )
    if [[ "$with_entitlements" == true ]]; then
        args+=(--entitlements "$ENTITLEMENTS")
    fi
    codesign "${args[@]}" "$target"
}

# Inside-out: dylibs → executable → bundle (no --deep).
if [[ -d "$FRAMEWORKS" ]]; then
    for dylib in "$FRAMEWORKS"/*.dylib(N); do
        echo "  dylib: ${dylib:t}"
        sign "$dylib"
    done
fi

echo "  executable: $APP_NAME"
sign "$BIN" true

echo "  bundle: $APP"
sign "$APP" true

echo "Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true

if $SIGN_ONLY; then
    echo "Signed $APP (notarization skipped)."
    exit 0
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
DIST="$ROOT/dist"
mkdir -p "$DIST"
ZIP="$DIST/${APP_NAME}-${VERSION}.zip"
rm -f "$ZIP"

echo "Zipping for notarization…"
ditto -c -k --keepParent "$APP" "$ZIP"

notary_submit() {
    if [[ -n "${NOTARY_API_KEY:-}" ]]; then
        xcrun notarytool submit "$ZIP" \
            --key "$NOTARY_API_KEY" \
            --key-id "${NOTARY_API_KEY_ID:?NOTARY_API_KEY_ID required with NOTARY_API_KEY}" \
            --issuer "${NOTARY_API_ISSUER_ID:?NOTARY_API_ISSUER_ID required with NOTARY_API_KEY}" \
            --wait
    else
        xcrun notarytool submit "$ZIP" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait
    fi
}

echo "Submitting to Apple notary service…"
notary_submit

echo "Stapling notarization ticket…"
xcrun stapler staple "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Creating distribution zip…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo ""
echo "Release ready:"
echo "  $ZIP"
echo "  $ZIP.sha256"