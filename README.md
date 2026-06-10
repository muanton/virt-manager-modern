# Virt Manager Modern

A **native macOS app for managing remote QEMU/KVM servers over libvirt** — a
Mac-native alternative to the GTK [virt-manager](https://virt-manager.org).
Connect over `qemu+ssh`, browse your VMs with live state, create and delete
machines, edit their hardware with real forms (no XML), and open SPICE or VNC
consoles rendered natively in the window.

![Main window](docs/screenshots/main.png)

| Console (SPICE, SSH-tunnelled) | Hardware manager | New VM wizard |
|---|---|---|
| ![Console](docs/screenshots/console.png) | ![Hardware](docs/screenshots/hardware.png) | ![New VM](docs/screenshots/new-vm.png) |

## Features

- **Connections** to remote libvirt over `qemu+ssh://` (SSH keys / ssh-agent),
  managed in a virt-manager-style add/edit dialog with autoconnect.
- **VM list** in a native sidebar with live status, plus full lifecycle:
  start, graceful shutdown, reboot, force off, pause/resume, managed save.
- **New VM wizard** with a guest-OS catalog (the role libosinfo plays in legacy
  virt-manager): picking e.g. *Ubuntu 24.04* or *Windows 11* pre-fills
  recommended CPU/RAM/disk and tunes devices — virtio vs SATA/e1000e, Hyper-V
  enlightenments + localtime clock for Windows, TPM 2.0 + forced UEFI for
  Windows 11.
- **Hardware manager**: schema-driven forms for ~20 device types (disks,
  NICs, graphics, controllers, host USB/PCI passthrough, TPM, …) with host-
  populated pickers (virtual networks, storage volumes, node devices).
  **Add Hardware** knows what's addable (singleton devices, SPICE-dependent
  devices); **Remove** knows what's removable (controllers in use are blocked,
  removing the boot disk warns). Edits stage into a working copy and apply via
  `defineXML`.
- **Delete VM** flow with per-file storage cleanup checkboxes, force-off for
  running VMs, and full metadata cleanup (UEFI NVRAM, managed save, snapshots).
- **SPICE and VNC consoles**, both tunnelled automatically over SSH and
  rendered natively (no GTK). The Console tab picks the right protocol from the
  VM's `<graphics>` device — and falls back to a real **serial console**
  (terminal emulator over `virDomainOpenConsole`) for headless VMs. CD-ROM
  media can be ejected live; power actions auto-eject installers so they
  don't boot again.
- **Live stats & guest IPs**: CPU% and memory per running VM in the sidebar
  and Overview; guest IP addresses (guest agent or DHCP leases) with one-click
  copy.
- **Snapshots**: create (incl. memory while running), revert, delete — shown
  as a tree with the current marker.
- **Clone VM** with per-disk Clone/Share/Skip, and **ISO upload** from the Mac
  straight into a host storage pool (libvirt streams — no scp).
- **Live hotplug**: attach disks/NICs/USB devices to running VMs, detach them
  live, and resize vCPUs/memory without a restart.

## Requirements

- **macOS 14+ on Apple Silicon**
- **Xcode Command Line Tools** (`xcode-select --install`) and network access —
  *nothing else*: no Homebrew, no pre-installed libraries
- A libvirt/QEMU host reachable over SSH (key/agent auth) — or none at all if
  you just want to poke the UI (`make run-dev` includes libvirt's built-in
  `test:///default` driver)

## Build & run

```sh
git clone <this repo> && cd virt-manager-modern
make            # first run builds all C dependencies from source (~10 min), then the app
make run        # open VirtManagerModern.app
make run-dev    # same + built-in test driver (no server needed)
swift test      # unit tests
```

Every C dependency (libvirt, glib, spice-client-glib, OpenSSL, gnutls,
gstreamer, …) is compiled from **pinned upstream release tarballs** into
`third_party/` and embedded into the `.app`, which therefore runs on any
Apple Silicon Mac without dependencies. See [docs/BUILDING.md](docs/BUILDING.md)
for the details (and for bumping dependency versions).

## Architecture

| Module | Responsibility |
|---|---|
| `CLibvirt` / `CSpice` | System-library modules mapping the self-built libvirt / spice-client-glib headers via pkg-config. |
| `LibvirtKit` | Swift wrappers over libvirt: connections, domain state, lifecycle, XML, storage, node devices. Blocking calls serialized off-main, exposed as `async`. |
| `DomainModel` | Parses/edits libvirt domain XML into typed values: device schemas, add/remove rules, guest-OS catalog, New VM template. |
| `ConsoleKit` | SSH port-forward tunnel + VNC session ([RoyalVNCKit]), exposing a live framebuffer `NSView`. |
| `SpiceShim` / `SpiceKit` | Small C shim hiding spice-gtk's GLib machinery (one shared GLib loop thread for all sessions) + Swift wrapper and AppKit renderer. |
| `App` | SwiftUI: sidebar, lifecycle toolbar, Overview/Console/Hardware tabs, wizards and sheets. |

## Status & limitations

- VNC and SPICE consoles (scaled-to-fit, full keyboard/mouse). No audio, USB
  redirection, clipboard sharing, multi-monitor, or RDP yet.
- VMs using virtio-gpu **GL scanout** (`<gl enable='yes'>`) aren't rendered.
- The app bundle is **ad-hoc signed**: on another Mac, right-click → Open the
  first time. Proper distribution would need Developer ID + notarization.
- arm64 only (the dependency build targets Apple Silicon).
- Not sandboxed (spawns `ssh` for tunnels and the `qemu+ssh` transport).

## License

This project is licensed under the **GNU General Public License v2.0** — see
[LICENSE](LICENSE). There are no per-file headers; the root license governs.

The bundled third-party libraries are built from unmodified upstream sources
and dynamically linked; each keeps its own license (LGPL: libvirt, GLib,
spice-client-glib, gstreamer, gnutls, proxy-libintl, json-glib; Apache-2.0:
OpenSSL; BSD: pcre2, spice-protocol; MIT: pixman; IJG: libjpeg; LGPL/GPL
dual: gmp, nettle). [RoyalVNCKit] is MIT-licensed.

[RoyalVNCKit]: https://github.com/royalapplications/royalvnc
