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

## Pull requests

- Keep `swift test` green; add a test when you change `DomainModel` behavior.
- One topic per PR. Screenshots for UI changes are appreciated.

## License

By contributing you agree your contributions are licensed under GPL-2.0
(see [LICENSE](LICENSE)).
