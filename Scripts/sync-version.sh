#!/bin/zsh
# Write VERSION into Resources/Info.plist (marketing + build strings).
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION_FILE="$ROOT/VERSION"
PLIST="$ROOT/Resources/Info.plist"

[[ -f "$VERSION_FILE" ]] || { echo "Missing $VERSION_FILE" >&2; exit 1 }
[[ -f "$PLIST" ]] || { echo "Missing $PLIST" >&2; exit 1 }

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "VERSION must be semver MAJOR.MINOR.PATCH, got: $VERSION" >&2
    exit 1
}

plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"
echo "Synced $VERSION → Resources/Info.plist"