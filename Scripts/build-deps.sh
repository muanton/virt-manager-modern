#!/bin/zsh
# Builds every third-party library the app needs from pinned upstream stable
# releases into third_party/prefix — no Homebrew required. Only Xcode Command
# Line Tools (clang, python3, perl, curl, git) are assumed.
#
# Idempotent: each component leaves a stamp in third_party/stamps and is
# skipped on re-runs. `rm -rf third_party` for a full rebuild.
set -euo pipefail

ROOT="${0:A:h:h}"
TP="$ROOT/third_party"
SRC="$TP/src"
TOOLS="$TP/tools"
PREFIX="$TP/prefix"
STAMPS="$TP/stamps"
SDKPC="$TP/sdk-pc"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$SRC" "$TOOLS/bin" "$PREFIX" "$STAMPS" "$SDKPC"

# ---- pinned upstream stable releases ----------------------------------------
# Latest stable as of 2026-06-10, verified against each project's release
# channel. Check for updates with Scripts/check-deps-updates.sh; after bumping
# a version, `make distclean deps` for a clean rebuild.
NINJA_V=1.13.2
MESON_V=1.11.1
PKGCONF_V=2.5.1
BISON_V=3.8.2
PCRE2_V=10.47
LIBINTL_V=0.5            # frida/proxy-libintl (tiny libintl shim, not full gettext)
GLIB_V=2.88.1
OPENSSL_V=4.0.1
GMP_V=6.3.0
NETTLE_V=4.0
GNUTLS_V=3.8.13
PIXMAN_V=0.46.4
JPEG_V=9f
JSONGLIB_V=1.10.8
GST_V=1.28.3
SPICEPROTO_V=0.14.5
SPICEGTK_V=0.42
LIBUSB_V=1.0.28
USBREDIR_V=0.13.0
LIBVIRT_V=12.4.0

# ---- isolated build environment (never look at /opt/homebrew or /usr/local) -
export PATH="$TOOLS/bin:$PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG="$TOOLS/bin/pkgconf"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$SDKPC"
unset PKG_CONFIG_PATH
export CC=/usr/bin/cc CXX=/usr/bin/c++
SDK="$(xcrun --show-sdk-path)"
MACOS_MIN=14.0
export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN
export CFLAGS="-I$PREFIX/include" CXXFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
MESON="$TOOLS/meson/meson.py"

log()  { print -P "%F{cyan}==> $1%f"; }
done_() { touch "$STAMPS/$1"; log "$1 ✓"; }
have() { [[ -e "$STAMPS/$1" ]] }

fetch() { # fetch <url> -> extracted dir name printed by caller's knowledge
    local url="$1" f="$SRC/${1:t}"
    [[ -e "$f" ]] || { log "fetch ${1:t}"; curl -fL --retry 3 -o "$f" "$url"; }
    case "$f" in
        *.tar.xz)  tar -xJf "$f" -C "$SRC" ;;
        *.tar.gz|*.tgz) tar -xzf "$f" -C "$SRC" ;;
        *.tar.bz2) tar -xjf "$f" -C "$SRC" ;;
    esac
}

meson_build() { # meson_build <srcdir> [extra meson args…]
    local dir="$1"; shift
    local bdir="$dir/_build"
    rm -rf "$bdir"
    python3 "$MESON" setup "$bdir" "$dir" --prefix="$PREFIX" \
        --buildtype=release --default-library=shared --libdir=lib \
        -Dc_args="-I$PREFIX/include" -Dc_link_args="-L$PREFIX/lib" "$@"
    python3 "$MESON" compile -C "$bdir" -j "$JOBS"
    python3 "$MESON" install -C "$bdir" --quiet
}

# =============================================================================
# Build tools (no compiler toolchain beyond CLT needed)
# =============================================================================

if ! have ninja; then
    fetch "https://github.com/ninja-build/ninja/archive/refs/tags/v$NINJA_V.tar.gz"
    ( cd "$SRC/ninja-$NINJA_V" && python3 configure.py --bootstrap )
    cp "$SRC/ninja-$NINJA_V/ninja" "$TOOLS/bin/ninja"
    done_ ninja
fi

if ! have meson; then
    fetch "https://github.com/mesonbuild/meson/releases/download/$MESON_V/meson-$MESON_V.tar.gz"
    rm -rf "$TOOLS/meson"; cp -R "$SRC/meson-$MESON_V" "$TOOLS/meson"
    done_ meson
fi

if ! have pkgconf; then
    fetch "https://distfiles.ariadne.space/pkgconf/pkgconf-$PKGCONF_V.tar.xz"
    meson_build "$SRC/pkgconf-$PKGCONF_V" -Dtests=disabled
    cp "$PREFIX/bin/pkgconf" "$TOOLS/bin/pkgconf"
    done_ pkgconf
fi

if ! have bison; then
    # gstreamer's parser needs bison ≥ 2.4; macOS ships 2.3.
    fetch "https://ftp.gnu.org/gnu/bison/bison-$BISON_V.tar.xz"
    ( cd "$SRC/bison-$BISON_V" \
      && ./configure --prefix="$TOOLS" >/dev/null \
      && make -j "$JOBS" >/dev/null && make install >/dev/null )
    done_ bison
fi

if ! have pyparsing; then
    # spice-common's protocol code generator imports pyparsing.
    python3 -m pip install --quiet --target "$TOOLS/python" pyparsing
    done_ pyparsing
fi
export PYTHONPATH="$TOOLS/python"

# ---- .pc shims for libraries macOS already provides -------------------------
if ! have sdkpc; then
    cat > "$SDKPC/libxml-2.0.pc" <<EOF
Name: libxml-2.0
Description: macOS SDK libxml2
Version: 2.9.13
Cflags: -I$SDK/usr/include/libxml2
Libs: -lxml2
EOF
    cat > "$SDKPC/libffi.pc" <<EOF
Name: libffi
Description: macOS SDK libffi
Version: 3.4.0
Cflags: -I$SDK/usr/include/ffi
Libs: -lffi
EOF
    cat > "$SDKPC/zlib.pc" <<EOF
Name: zlib
Description: macOS SDK zlib
Version: 1.2.12
Cflags: -I$SDK/usr/include
Libs: -lz
EOF
    done_ sdkpc
fi

# =============================================================================
# Libraries (dependency order)
# =============================================================================

if ! have pcre2; then
    fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_V/pcre2-$PCRE2_V.tar.bz2"
    ( cd "$SRC/pcre2-$PCRE2_V" \
      && ./configure --prefix="$PREFIX" --disable-static --enable-shared >/dev/null \
      && make -j "$JOBS" >/dev/null && make install >/dev/null )
    done_ pcre2
fi

if ! have proxy-libintl; then
    fetch "https://github.com/frida/proxy-libintl/archive/refs/tags/$LIBINTL_V.tar.gz"
    meson_build "$SRC/proxy-libintl-$LIBINTL_V"
    done_ proxy-libintl
fi

if ! have glib; then
    fetch "https://download.gnome.org/sources/glib/${GLIB_V%.*}/glib-$GLIB_V.tar.xz"
    meson_build "$SRC/glib-$GLIB_V" \
        -Dtests=false -Dintrospection=disabled -Ddocumentation=false \
        -Dman-pages=disabled -Ddtrace=disabled
    done_ glib
fi

if ! have openssl; then
    fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_V/openssl-$OPENSSL_V.tar.gz"
    ( cd "$SRC/openssl-$OPENSSL_V" \
      && perl ./Configure darwin64-arm64-cc --prefix="$PREFIX" --libdir=lib \
             no-tests no-docs no-apps shared \
      && make -j "$JOBS" >/dev/null && make install_sw >/dev/null )
    done_ openssl
fi

if ! have gmp; then
    # GNU mirror — gmplib.org frequently times out in CI (matches nettle below).
    fetch "https://ftp.gnu.org/gnu/gmp/gmp-$GMP_V.tar.xz"
    ( cd "$SRC/gmp-$GMP_V" \
      && ./configure --prefix="$PREFIX" --disable-static --enable-shared >/dev/null \
      && make -j "$JOBS" >/dev/null && make install >/dev/null )
    done_ gmp
fi

if ! have nettle; then
    fetch "https://ftp.gnu.org/gnu/nettle/nettle-$NETTLE_V.tar.gz"
    ( cd "$SRC/nettle-$NETTLE_V" \
      && ./configure --prefix="$PREFIX" --disable-static --enable-shared \
             --disable-documentation --libdir="$PREFIX/lib" >/dev/null \
      && make -j "$JOBS" >/dev/null && make install >/dev/null )
    done_ nettle
fi

if ! have gnutls; then
    fetch "https://www.gnupg.org/ftp/gcrypt/gnutls/v${GNUTLS_V%.*}/gnutls-$GNUTLS_V.tar.xz"
    # gnutls 3.8.13's crau.h leaves CRAU_MAYBE_UNUSED *undefined* when the compiler
    # defines __has_c_attribute but reports __maybe_unused__ unavailable in the active
    # C mode (CI's macos-14 clang): the __GNUC__ fallback is then unreachable and the
    # build fails with "expected ')'". Disable the __has_c_attribute branch so the
    # portable __attribute__((__unused__)) fallback is used.
    sed -i '' 's/if defined(__has_c_attribute)/if 0/' \
        "$SRC/gnutls-$GNUTLS_V/lib/crau/crau.h"
    ( cd "$SRC/gnutls-$GNUTLS_V" \
      && ./configure --prefix="$PREFIX" --disable-static --enable-shared \
             --with-included-libtasn1 --with-included-unistring \
             --without-p11-kit --without-idn --without-brotli --without-zstd \
             --without-tpm --without-tpm2 --disable-doc --disable-tests \
             --disable-cxx --disable-tools --disable-libdane --disable-guile \
             NETTLE_CFLAGS="-I$PREFIX/include" NETTLE_LIBS="-L$PREFIX/lib -lnettle" \
             HOGWEED_CFLAGS="-I$PREFIX/include" HOGWEED_LIBS="-L$PREFIX/lib -lhogweed" \
             GMP_CFLAGS="-I$PREFIX/include" GMP_LIBS="-L$PREFIX/lib -lgmp" >/dev/null \
      && make -j "$JOBS" >/dev/null && make install >/dev/null )
    done_ gnutls
fi

if ! have pixman; then
    fetch "https://www.cairographics.org/releases/pixman-$PIXMAN_V.tar.gz"
    meson_build "$SRC/pixman-$PIXMAN_V" -Dtests=disabled -Ddemos=disabled
    done_ pixman
fi

if ! have jpeg; then
    fetch "https://www.ijg.org/files/jpegsrc.v$JPEG_V.tar.gz"
    ( cd "$SRC/jpeg-$JPEG_V" \
      && ./configure --prefix="$PREFIX" --disable-static --enable-shared >/dev/null \
      && make -j "$JOBS" >/dev/null && make install >/dev/null )
    done_ jpeg
fi

if ! have json-glib; then
    fetch "https://download.gnome.org/sources/json-glib/${JSONGLIB_V%.*}/json-glib-$JSONGLIB_V.tar.xz"
    meson_build "$SRC/json-glib-$JSONGLIB_V" \
        -Dintrospection=disabled -Ddocumentation=disabled -Dtests=false -Dman=false
    done_ json-glib
fi

if ! have gstreamer; then
    fetch "https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-$GST_V.tar.xz"
    meson_build "$SRC/gstreamer-$GST_V" \
        -Dexamples=disabled -Dtests=disabled -Dbenchmarks=disabled \
        -Dtools=disabled -Dintrospection=disabled -Ddoc=disabled \
        -Dbash-completion=disabled
    done_ gstreamer
fi

if ! have gst-plugins-base; then
    fetch "https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-$GST_V.tar.xz"
    meson_build "$SRC/gst-plugins-base-$GST_V" \
        -Dauto_features=disabled -Dexamples=disabled -Dtests=disabled \
        -Dtools=disabled -Dintrospection=disabled -Ddoc=disabled \
        -Dorc=disabled
    done_ gst-plugins-base
fi

if ! have spice-protocol; then
    fetch "https://www.spice-space.org/download/releases/spice-protocol-$SPICEPROTO_V.tar.xz"
    meson_build "$SRC/spice-protocol-$SPICEPROTO_V"
    done_ spice-protocol
fi

if ! have libusb; then
    fetch "https://github.com/libusb/libusb/releases/download/v$LIBUSB_V/libusb-$LIBUSB_V.tar.bz2"
    ( cd "$SRC/libusb-$LIBUSB_V" \
      && ./configure --prefix="$PREFIX" --disable-static --enable-shared >/dev/null \
      && make -j "$JOBS" >/dev/null && make install >/dev/null )
    done_ libusb
fi

if ! have usbredir; then
    # spice-gtk was previously built without usbredir — rebuild it once deps exist.
    rm -f "$STAMPS/spice-gtk"
    fetch "https://gitlab.freedesktop.org/spice/usbredir/-/archive/usbredir-$USBREDIR_V/usbredir-$USBREDIR_V.tar.bz2"
    usbdir=( $SRC/usbredir-usbredir-$USBREDIR_V*(N) )
    [[ ${#usbdir[@]} -eq 1 ]] || { log "usbredir extract dir not found"; exit 1; }
    meson_build "$usbdir[1]" -Dtests=disabled -Dfuzzing=disabled
    done_ usbredir
fi

if ! have spice-gtk; then
    fetch "https://www.spice-space.org/download/gtk/spice-gtk-$SPICEGTK_V.tar.xz"
    # Upstream fix (post-0.42) for libtool-style '-export-symbols' the Apple
    # linker rejects — same backport Homebrew applies.
    curl -fsL --retry 3 -o "$SRC/spice-gtk-symfix.diff" \
        "https://gitlab.freedesktop.org/spice/spice-gtk/-/commit/1511f0ad5ea67b4657540c631e3a8c959bb8d578.diff"
    ( cd "$SRC/spice-gtk-$SPICEGTK_V" && patch -p1 -N < "$SRC/spice-gtk-symfix.diff" ) || true
    meson_build "$SRC/spice-gtk-$SPICEGTK_V" \
        -Dgtk=disabled -Dwebdav=disabled -Dusbredir=enabled -Dlz4=disabled \
        -Dsasl=disabled -Dopus=disabled -Dsmartcard=disabled -Dpolkit=disabled \
        -Dintrospection=disabled -Dvapi=disabled -Dgtk_doc=disabled
    done_ spice-gtk
fi

if ! have libvirt; then
    fetch "https://download.libvirt.org/libvirt-$LIBVIRT_V.tar.xz"
    meson_build "$SRC/libvirt-$LIBVIRT_V" \
        -Ddriver_remote=enabled -Ddriver_qemu=disabled -Ddriver_test=enabled \
        -Ddriver_esx=disabled -Ddriver_ch=disabled -Ddriver_lxc=disabled \
        -Ddriver_libxl=disabled -Ddriver_openvz=disabled -Ddriver_vbox=disabled \
        -Ddriver_vmware=disabled -Ddriver_hyperv=disabled -Ddriver_bhyve=disabled \
        -Ddriver_vz=disabled -Ddriver_secrets=disabled -Ddriver_network=disabled \
        -Ddriver_interface=disabled -Ddriver_libvirtd=disabled \
        -Dcurl=disabled -Dlibssh=disabled -Dlibssh2=disabled -Dsasl=disabled \
        -Djson_c=disabled -Dreadline=disabled -Dlibpcap=disabled \
        -Ddocs=disabled -Dtests=disabled -Dnls=disabled
    done_ libvirt
fi

log "All dependencies built into ${PREFIX/#$ROOT\//}"
