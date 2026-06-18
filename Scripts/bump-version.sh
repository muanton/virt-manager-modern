#!/bin/zsh
# Bump the project semver in VERSION and sync Info.plist.
#
# Usage: Scripts/bump-version.sh patch|minor|major
#
# Policy (see CONTRIBUTING.md):
#   patch — bug fixes, docs, CI/build, refactors, small UX polish
#   minor — new user-facing features or notable capability additions
#   major — breaking changes or large architectural shifts
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION_FILE="$ROOT/VERSION"

usage() {
    echo "Usage: bump-version.sh patch|minor|major" >&2
    exit 1
}

[[ $# -eq 1 ]] || usage
[[ -f "$VERSION_FILE" ]] || { echo "Missing $VERSION_FILE" >&2; exit 1 }

read -r major minor patch < <(tr -d '[:space:]' < "$VERSION_FILE" | awk -F. '{print $1, $2, $3}')
[[ -n "$major" && -n "$minor" && -n "$patch" ]] || {
    echo "Invalid VERSION format in $VERSION_FILE" >&2
    exit 1
}

case "$1" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
    *) usage ;;
esac

NEW="$major.$minor.$patch"
print -n "$NEW" > "$VERSION_FILE"
"$ROOT/Scripts/sync-version.sh"
echo "Bumped to $NEW"