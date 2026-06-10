#!/bin/zsh
# Compares the versions pinned in build-deps.sh against each project's
# upstream release channel. Maintenance helper — prints a table; bump the
# pins in build-deps.sh and run `make distclean deps` to upgrade.
set -uo pipefail

source <(grep -E '^[A-Z0-9_]+_V=' "${0:A:h}/build-deps.sh")

gh_latest()   { curl -s "https://api.github.com/repos/$1/releases/latest" | sed -n 's/.*"tag_name": "\(.*\)".*/\1/p' | sed "s/^${2:-}//" | head -1 }
gnome_latest(){ curl -s "https://download.gnome.org/sources/$1/cache.json" | python3 -c "
import json,sys,re
d=json.load(sys.stdin)
vs=[v for v in d[1]['$1'] if re.fullmatch(r'\d+\.\d+(\.\d+)?',v) and int(v.split('.')[1])%2==0]
print(sorted(vs,key=lambda s:[int(x) for x in s.split('.')])[-1])" }
dir_latest()  { curl -s "$1" | grep -oE "$2" | sed -E "s/$3//g" | sort -V | tail -1 }

row() { printf "%-14s %-10s %s\n" "$1" "$2" "${3:-?}" }

printf "%-14s %-10s %s\n" COMPONENT PINNED LATEST
row ninja      "$NINJA_V"      "$(gh_latest ninja-build/ninja v)"
row meson      "$MESON_V"      "$(gh_latest mesonbuild/meson)"
row pkgconf    "$PKGCONF_V"    "$(dir_latest https://distfiles.ariadne.space/pkgconf/ 'pkgconf-[0-9.]+\.tar\.xz' 'pkgconf-|\.tar\.xz')"
row bison      "$BISON_V"      "$(dir_latest https://ftp.gnu.org/gnu/bison/ 'bison-[0-9.]+\.tar\.xz' 'bison-|\.tar\.xz')"
row pcre2      "$PCRE2_V"      "$(gh_latest PCRE2Project/pcre2 pcre2-)"
row libintl    "$LIBINTL_V"    "$(gh_latest frida/proxy-libintl)"
row glib       "$GLIB_V"       "$(gnome_latest glib)"
row openssl    "$OPENSSL_V"    "$(gh_latest openssl/openssl openssl-)"
row gmp        "$GMP_V"        "$(dir_latest https://gmplib.org/download/gmp/ 'gmp-[0-9.]+\.tar\.xz' 'gmp-|\.tar\.xz')"
row nettle     "$NETTLE_V"     "$(dir_latest https://ftp.gnu.org/gnu/nettle/ 'nettle-[0-9.]+\.tar\.gz' 'nettle-|\.tar\.gz')"
row gnutls     "$GNUTLS_V"     "$(dir_latest "https://www.gnupg.org/ftp/gcrypt/gnutls/v${GNUTLS_V%.*}/" 'gnutls-[0-9.]+\.tar\.xz' 'gnutls-|\.tar\.xz') (branch v${GNUTLS_V%.*})"
row pixman     "$PIXMAN_V"     "$(dir_latest https://www.cairographics.org/releases/ 'pixman-[0-9.]+\.tar\.gz' 'pixman-|\.tar\.gz')"
row jpeg       "$JPEG_V"       "$(dir_latest https://www.ijg.org/files/ 'jpegsrc\.v9[a-z]\.tar\.gz' 'jpegsrc\.v|\.tar\.gz')"
row json-glib  "$JSONGLIB_V"   "$(gnome_latest json-glib)"
row gstreamer  "$GST_V"        "$(curl -s https://gstreamer.freedesktop.org/src/gstreamer/ | grep -oE 'gstreamer-1\.[0-9]+\.[0-9]+\.tar\.xz' | sed 's/gstreamer-//;s/\.tar\.xz//' | sort -V | awk -F. '$2%2==0' | tail -1)"
row spice-proto "$SPICEPROTO_V" "$(dir_latest https://www.spice-space.org/download/releases/ 'spice-protocol-[0-9.]+\.tar\.xz' 'spice-protocol-|\.tar\.xz')"
row spice-gtk  "$SPICEGTK_V"   "$(dir_latest https://www.spice-space.org/download/gtk/ 'spice-gtk-[0-9.]+\.tar\.xz' 'spice-gtk-|\.tar\.xz')"
row libvirt    "$LIBVIRT_V"    "$(dir_latest https://download.libvirt.org/ 'libvirt-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' 'libvirt-|\.tar\.xz')"
