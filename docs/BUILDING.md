# Building Virt Manager Modern

The whole project — app *and* every C library it uses — builds from source with
nothing but the Xcode Command Line Tools and network access. No Homebrew, no
MacPorts, no pre-installed pkg-config/meson/cmake.

```sh
make            # = make app: deps → swift build → .app bundle
make run        # build + open
make test       # swift test
make clean      # remove app + Swift build artifacts (keeps third_party)
make distclean  # also wipe third_party (full dependency rebuild next time)
```

## Targets

| Target | What it does |
|---|---|
| `deps` | Builds all C dependencies from pinned upstream releases into `third_party/prefix` (idempotent — stamps in `third_party/stamps`). |
| `build` | `swift build -c release` with `PKG_CONFIG_PATH` pointed at the prefix. |
| `app` | Assembles `VirtManagerModern.app`: copies the binary, Info.plist, icon, embeds the dylib closure, re-signs ad hoc. |
| `run` / `run-dev` | Opens the bundle; `run-dev` sets `VMM_TEST_DRIVER=1` to include the built-in `test:///default` connection. |
| `test` | Runs the unit tests. |
| `clean` / `distclean` | See above. |

## The dependency build (`Scripts/build-deps.sh`)

First run (~10 minutes on an M-series Mac):

1. **Bootstraps build tools** into `third_party/tools`: ninja (compiled from
   source), meson (run from its tarball — pure Python), pkgconf, GNU bison
   (macOS ships 2.3; gstreamer needs ≥ 2.4), and the `pyparsing` Python module
   (spice-common's code generator).
2. **Writes `.pc` shims** (`third_party/sdk-pc/`) for libraries macOS already
   provides — libxml2, zlib, libffi — so meson/autotools find the SDK copies
   instead of building them.
3. **Builds the libraries** in dependency order into `third_party/prefix`,
   each from its official release tarball, pinned by version at the top of the
   script:

   pcre2, proxy-libintl, **glib**, **openssl**, gmp → nettle → **gnutls**
   (required unconditionally by libvirt), pixman, jpeg, json-glib,
   **gstreamer** core + plugins-base (hard build dependency of spice-gtk; no
   plugins are shipped), spice-protocol, **spice-client-glib** (built with
   `-Dgtk=disabled` — no GTK anywhere; patched with upstream commit `1511f0ad`
   for the Apple linker), and **libvirt** (client-only: remote + test drivers,
   everything else disabled).

The environment is isolated: `PKG_CONFIG_LIBDIR` points only at the prefix and
the SDK shims, so a Homebrew installation on the build machine can't leak in.

### Bumping a dependency

```sh
Scripts/check-deps-updates.sh   # prints PINNED vs LATEST for every component
# edit the version variable at the top of Scripts/build-deps.sh
make distclean deps             # clean rebuild
make app && swift test
```

## App bundling (`Scripts/embed-dylibs.sh`)

`make app` makes the bundle self-contained:

- Walks the binary's dependency closure (skipping system libraries and the OS
  Swift runtime) and copies every dylib into `Contents/Frameworks`.
- Rewrites all load commands to `@rpath/…` and sets the executable's rpath to
  `@executable_path/../Frameworks`.
- Strips dangerous embedded rpaths (build tree, `/opt/homebrew`, `/usr/local`,
  Xcode toolchain) — but **keeps `/usr/lib/swift`**: Swift-built dylibs need it,
  and removing it crashes Swift type-metadata initialization at runtime.
- Re-signs everything ad hoc (`codesign -s -`) — required on Apple Silicon
  after `install_name_tool` edits.

Result: the `.app` runs on any Apple Silicon Mac on macOS 14+ with no
dependencies installed. (On another Mac, Gatekeeper requires right-click → Open
the first time, since the signature is ad hoc.)

## App icon

`Resources/AppIcon.icns` is generated — `Scripts/make-icon.swift` draws the
1024px master with AppKit, `Scripts/make-icon.sh` renders all sizes and
assembles the icns. Regenerate after editing the drawing code:

```sh
Scripts/make-icon.sh
```
