# v0.3.2 — first public download

Native macOS app for managing remote QEMU/KVM hosts over libvirt (`qemu+ssh`).
A SwiftUI alternative to the GTK virt-manager — self-contained, no Homebrew at
runtime.

![Main window](https://github.com/muanton/virt-manager-modern/raw/v0.3.2/docs/screenshots/main.png)

## Download

| Asset | Notes |
|---|---|
| `VirtManagerModern-0.3.2.zip` | Notarized app bundle (~13 MB). Unzip, drag to Applications. |
| `VirtManagerModern-0.3.2.zip.sha256` | Checksum — verify before opening. |

```sh
shasum -a 256 -c VirtManagerModern-0.3.2.zip.sha256
```

**Requirements:** macOS 14+ on Apple Silicon. A libvirt/QEMU host reachable over
SSH (key or ssh-agent auth).

**Install:** unzip → move `VirtManagerModern.app` to `/Applications` → open.
Notarized builds open normally. If you built locally with `make app` instead,
right-click → **Open** the first time (ad-hoc signature).

## Highlights

- **Remote libvirt** over `qemu+ssh` with autoconnect and a connection manager
- **VM lifecycle** — start, shutdown, reboot, force off, pause/resume, managed save
- **New VM wizard** with a guest-OS catalog (Ubuntu, Windows 11, …) and per-OS tuning
- **Hardware manager** — schema-driven forms for ~20 device types; add/remove rules
- **SPICE & VNC consoles** — native rendering, automatic SSH tunnels, detach +
  fullscreen, clipboard sharing (toggle in Settings ⌘,)
- **Serial console** for headless VMs
- **Live stats** — CPU % and memory in the sidebar; guest IPs with one-click copy
- **Guest agent info** on Overview — hostname, OS, and filesystem usage (via
  `virDomainGetGuestInfo`)
- **VM screenshots** on Overview (auto-refresh while running)
- **Storage & network managers** — pools, volumes (create/resize/wipe), XML editor
- **Snapshots**, **clone VM**, **ISO upload** from your Mac (libvirt streams)
- **Live hotplug** — attach/detach disks, NICs, USB; resize vCPU/RAM without reboot
- **Host dashboard** — node info, live memory, VM counts, libvirt version
- **Developer ID signing & notarization** tooling (`make release`) for maintainers

Every C dependency (libvirt, spice-client-glib, glib, gnutls, …) is built from
pinned upstream sources and embedded in the `.app` — nothing to install on the Mac.

## Known limitations

- **arm64 / Apple Silicon only** — no Intel build
- **No SPICE audio or USB redirection** yet
- **No multi-monitor** or virtio-gpu GL scanout (`<gl enable='yes'>`)
- **No live migration** between hosts (single-host focus)
- **Not sandboxed** — spawns `/usr/bin/ssh` for tunnels and the libvirt transport

## Build from source

```sh
git clone https://github.com/muanton/virt-manager-modern.git
cd virt-manager-modern
git checkout v0.3.2
make && make run
```

See [BUILDING.md](BUILDING.md) for dependency build details. Local builds are
ad-hoc signed; maintainers can produce a notarized zip with `make release`.

## Source code (GPL-2.0)

This release corresponds to git tag **`v0.3.2`** in this repository. The
project is licensed under the
[GNU General Public License v2.0](../LICENSE). Corresponding source for the
distributed binary is available at:

https://github.com/muanton/virt-manager-modern/tree/v0.3.2

Bundled third-party libraries (libvirt, GLib, spice-client-glib, gstreamer,
gnutls, OpenSSL, …) are built from unmodified upstream tarballs and retain
their respective licenses. [RoyalVNCKit](https://github.com/royalapplications/royalvnc)
(MIT) is used for VNC.

## Changelog

### v0.3.2

- Add GitHub Actions release workflow (tag push → sign → notarize → publish)

### v0.3.1

- Fix guest info parsing on Overview (`virTypedParamsGet*` return value)
- Fix agent status when guest tools are installed but info was not displayed

### v0.3.0

- Add guest agent hostname, OS, and mount info on Overview (`virDomainGetGuestInfo`)

### v0.2.0

- Semver versioning via `VERSION` file (`make bump-patch` / `bump-minor` / `bump-major`)
- Developer ID signing and notarization release tooling (`make sign` / `make release`)
- CI: Swift 6 / Xcode 16, CodeQL, pkg-config fixes for standalone builds

### Since v0.1.0

- Fix detached console black screen (detach, zoom, fullscreen)
- Add preferences, volume resize/wipe, VM screenshots
- Polish host/storage/network UX; managed save
- Add host dashboard, network manager, SPICE clipboard, detached console
- Improve errors, events, search, storage, CI, and integration tests