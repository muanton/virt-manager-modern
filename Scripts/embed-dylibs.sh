#!/bin/zsh
# Makes the .app standalone: copies the transitive closure of non-system
# dylibs the binary depends on into Contents/Frameworks and rewrites every
# load command to @rpath. Works for our third_party/prefix builds (and any
# stray Homebrew paths). System libraries (/usr/lib, /System) are left alone.
set -euo pipefail

APP="$1"
ROOT="${0:A:h:h}"
BIN="$APP/Contents/MacOS/$(basename "$APP" .app)"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

# Where @rpath/… references may live, in search order.
HINTS=("$ROOT/third_party/prefix/lib" "$ROOT/.build/release" "$FRAMEWORKS")

# Non-system deps of a Mach-O file, as literally referenced.
# (otool line 1 is the file header; for dylibs line 2 is its own install name —
# harmless here, it resolves to the file itself.)
deps_of() {
    # libswift*: the OS-provided Swift runtime (dyld resolves it from
    # /usr/lib/swift) — never bundle it.
    otool -L "$1" | awk 'NR>1 {print $1}' \
        | grep -Ev '^(/usr/lib|/System)|^@rpath/libswift' || true
}

resolve() { # reference -> real file path ('' if not found)
    local ref="$1"
    if [[ "$ref" == /* ]]; then
        [[ -e "$ref" ]] && realpath "$ref" || print ""
    else
        local name="${ref#@rpath/}"
        for h in "${HINTS[@]}"; do
            [[ -e "$h/$name" ]] && { realpath "$h/$name"; return }
        done
        print ""
    fi
}

# ---- 1. Collect + copy the closure -----------------------------------------
typeset -A copied
queue=("${(@f)$(deps_of "$BIN")}")
while (( ${#queue[@]} > 0 )); do
    ref="${queue[1]}"; shift queue
    [[ -z "$ref" ]] && continue
    name="${${ref#@rpath/}:t}"
    [[ -n "${copied[$name]:-}" ]] && continue
    real="$(resolve "$ref")"
    if [[ -z "$real" ]]; then
        print -u2 "embed-dylibs: cannot resolve dependency '$ref'"
        exit 1
    fi
    copied[$name]=1
    [[ "$real" != "$FRAMEWORKS/$name" ]] && cp -f "$real" "$FRAMEWORKS/$name"
    chmod u+w "$FRAMEWORKS/$name"
    for dep in "${(@f)$(deps_of "$real")}"; do
        [[ -n "$dep" && -z "${copied[${${dep#@rpath/}:t}]:-}" ]] && queue+=("$dep")
    done
done

# ---- 2. Rewrite load commands to @rpath, drop build-tree rpaths --------------
rewrite() {
    local f="$1"
    for dep in "${(@f)$(deps_of "$f")}"; do
        [[ -n "$dep" && "$dep" == /* ]] && \
            install_name_tool -change "$dep" "@rpath/${dep:t}" "$f" 2>/dev/null
    done
    # Leftover build-tree/Homebrew rpaths would load a SECOND copy from
    # outside the bundle (e.g. two glibs in one process) — strip those, but
    # KEEP system rpaths like /usr/lib/swift: Swift-built dylibs need it to
    # resolve the OS Swift runtime (removing it crashes type metadata init).
    for rp in "${(@f)$(otool -l "$f" | awk '/LC_RPATH/{r=1} r && /path /{print $2; r=0}' \
            | grep -E "^($ROOT|/opt/homebrew|/usr/local|/Applications/Xcode)" || true)}"; do
        [[ -n "$rp" ]] && install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
    done
}

rewrite "$BIN"
for f in "$FRAMEWORKS"/*.dylib; do
    install_name_tool -id "@rpath/${f:t}" "$f" 2>/dev/null
    rewrite "$f"
done

echo "Embedded ${#copied[@]} dylibs into ${FRAMEWORKS:t2}"
