# Contributing

Thanks for your interest! The project is small and pragmatic — so is this guide.

## Building

You need macOS 14+ on Apple Silicon, the Xcode Command Line Tools
(`xcode-select --install`), and network access. No Homebrew, no other package
manager:

```sh
make            # first run builds ~19 C dependencies from source (~10 min), then the app
make run        # build + launch
make run-dev    # same, plus the built-in test:///default libvirt connection —
                # lets you exercise the whole UI without a real server
swift test      # unit tests (domain XML parsing/editing, add/remove rules)
```

See [docs/BUILDING.md](docs/BUILDING.md) for how the dependency build and app
bundling work, and how to bump a pinned library version.

## Development tips

- The `test:///default` driver (via `make run-dev`) supports most operations —
  listing, lifecycle, hardware editing — without touching a real hypervisor.
- For console work you need a real libvirt host reachable over `qemu+ssh`.
- `VMM_SPICE_DEBUG=1` prints SPICE shim checkpoints to stderr.
- `swift run vmm-probe [uri]` smoke-tests the libvirt link without the UI.

## Code style

Match the surrounding code. Comments explain *constraints the code can't show*,
not what the next line does. UI strings are sentence case; errors should surface
libvirt's actual message (see `LibvirtError`).

## Versioning

The app version lives in **`VERSION`** (semver `MAJOR.MINOR.PATCH`). Every
merged change should bump it before commit:

| Bump | When |
|---|---|
| **patch** (`make bump-patch`) | Bug fixes, docs, CI/build, refactors, small UX polish |
| **minor** (`make bump-minor`) | New user-facing features or notable capability additions |
| **major** (`make bump-major`) | Breaking changes or large architectural shifts |

`make bump-*` updates `VERSION` and syncs `Resources/Info.plist`. `make app`
also runs `sync-version` so the bundle always matches `VERSION`. Tag releases
as `v$(cat VERSION)` (e.g. `v0.2.0`).

## Pull requests

- Keep `swift test` green; add a test when you change `DomainModel` behavior.
- **Bump `VERSION`** (see above) — include `VERSION` and `Resources/Info.plist`
  in the same commit as your change.
- One topic per PR. Screenshots for UI changes are appreciated.

## License

By contributing you agree your contributions are licensed under GPL-2.0
(see [LICENSE](LICENSE)).
