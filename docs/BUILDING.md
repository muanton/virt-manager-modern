# Building Virt Manager Modern

The whole project — app *and* every C library it uses — builds from source with
nothing but the Xcode Command Line Tools and network access. No Homebrew, no
MacPorts, no pre-installed pkg-config/meson/cmake.

```sh
make            # = make app: deps → swift build → .app bundle
make run        # build + open
make test       # swift test
make bump-patch # bump VERSION + sync Info.plist (see CONTRIBUTING.md)
make sign       # Developer ID sign (requires Apple cert in Keychain)
make release    # sign → notarize → staple → dist/*.zip
make clean      # remove app + Swift build artifacts (keeps third_party)
make distclean  # also wipe third_party (full dependency rebuild next time)
```

## Targets

| Target | What it does |
|---|---|
| `sync-version` | Writes `VERSION` into `Resources/Info.plist` (also runs as part of `app`). |
| `bump-patch` / `bump-minor` / `bump-major` | Bump semver in `VERSION` and sync Info.plist. |
| `deps` | Builds all C dependencies from pinned upstream releases into `third_party/prefix` (idempotent — stamps in `third_party/stamps`). |
| `build` | `swift build -c release` with `PKG_CONFIG_PATH` pointed at the prefix. |
| `app` | Assembles `VirtManagerModern.app`: copies the binary, Info.plist, icon, embeds the dylib closure, re-signs ad hoc. |
| `sign` | Developer ID sign + verify via `Scripts/sign-and-notarize.sh --sign-only` (no notarization). |
| `release` | Full distribution build: sign → notarize → staple → `dist/VirtManagerModern-<version>.zip` + `.sha256`. |
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

## Distribution signing (`Scripts/sign-and-notarize.sh`)

`make sign` and `make release` wrap the signing script. Bundle ID:
`com.muanton.virtmanagermodern`. Entitlements:
`Resources/VirtManagerModern.entitlements` (hardened runtime via
`codesign --options runtime`; add keys only if notarization rejects).

**Prerequisites** (after Apple Developer enrollment):

1. **Developer ID Application** certificate in the login keychain (not “Mac App
   Distribution” — that is for the App Store).
2. Bundle ID registered in the developer portal.
3. Notary credentials — keychain profile (recommended) or App Store Connect API
   key:

```sh
xcrun notarytool store-credentials AC_NOTARY \
  --apple-id YOU@EMAIL --team-id TEAMID --password APP-SPECIFIC-PASSWORD

make sign       # test signing before submitting to Apple
make release    # produces dist/VirtManagerModern-<version>.zip
```

The script signs inside-out (each embedded dylib → executable → bundle), submits
the zip to Apple's notary service, staples the ticket, and writes a SHA256
checksum alongside the zip. Environment overrides: `CODESIGN_IDENTITY`,
`ENTITLEMENTS`, `NOTARY_PROFILE`, or `NOTARY_API_KEY` / `NOTARY_API_KEY_ID` /
`NOTARY_API_ISSUER_ID`. See `Scripts/sign-and-notarize.sh --help`.

Release notes template: [RELEASE-v0.4.0.md](RELEASE-v0.4.0.md). Bump policy:
[CONTRIBUTING.md](../CONTRIBUTING.md#versioning).

### GitHub Actions release

`.github/workflows/release.yml` runs on tag push (`v*`) or manual **workflow_dispatch**.
It builds, tests, signs, notarizes, and publishes the zip + SHA256 to GitHub Releases.
The git tag must match `VERSION` (e.g. tag `v0.3.1` when `VERSION` is `0.3.1`).

Configure these repository secrets (**Settings → Secrets and variables → Actions**):

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12` export |
| `P12_PASSWORD` | Password used when exporting the `.p12` |
| `NOTARY_API_ISSUER_ID` | App Store Connect API issuer ID |
| `NOTARY_API_KEY_ID` | API key ID |
| `NOTARY_API_PRIVATE_KEY` | Full contents of the `.p8` API key file |
| `KEYCHAIN_PASSWORD` | *(optional)* temp keychain password; random if omitted |

Export the certificate:

```sh
# Keychain Access → Developer ID Application → Export → .p12
base64 -i Certificates.p12 | pbcopy   # paste into BUILD_CERTIFICATE_BASE64
```

Publish:

```sh
# After VERSION bump + docs/RELEASE-v<version>.md exist on main:
git tag v0.3.1 && git push origin v0.3.1
# Or: Actions → Release → Run workflow → tag v0.3.1
```

## App icon

`Resources/AppIcon.icns` is generated — `Scripts/make-icon.swift` draws the
1024px master with AppKit, `Scripts/make-icon.sh` renders all sizes and
assembles the icns. Regenerate after editing the drawing code:

```sh
Scripts/make-icon.sh
```
