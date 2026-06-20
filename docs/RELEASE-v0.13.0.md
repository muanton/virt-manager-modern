# v0.13.0 — tabbed host view, guest port forwarding

Native macOS app for managing remote QEMU/KVM hosts over libvirt (`qemu+ssh`).

## Highlights

### Tabbed host detail
- The connection is now a **selectable sidebar item** showing live host stats
  (memory in use, running/defined VM counts), with VMs nested beneath it
- Selecting it opens a tabbed host detail — **Info / Storage / Networks** — the
  same way VMs open their own tabs (replaces the old Host Info / Manage Storage /
  Manage Networks modal sheets)

### Guest port forwarding + quick-connect
- Forward any guest TCP port to `localhost` over the existing SSH tunnel —
  reachable even when the guest sits on a private libvirt network
- One-click **SSH to guest** (Terminal via ProxyJump through the host) and
  **Open in browser** from the guest IPs on the Overview tab
- Forwards are torn down automatically on VM stop, disconnect, and app quit

### Docs & screenshots
- README gallery and ROADMAP updated; new screenshots for the host detail and
  port forwarding

## Build from source

```sh
git clone https://github.com/muanton/virt-manager-modern.git
cd virt-manager-modern
git checkout v0.13.0
make && make run
```

See [BUILDING.md](BUILDING.md). Local builds are ad-hoc signed; maintainers can
produce a notarized zip with `make release`.

## Known limitations

- **virtio-gpu GL scanout** (`<gl enable='yes'>`) is not rendered in-app
- **Config drift revert** covers hot-pluggable changes only
- **arm64 / Apple Silicon only**
- **No live migration** between hosts

## Changelog

### v0.13.0

- Tabbed host detail (Info / Storage / Networks) replacing the host modals
- Selectable sidebar host row with live memory and VM counts
- Guest port forwarding with SSH / open-in-browser quick-connect
- README, ROADMAP, and screenshots refreshed

### v0.12.0

- Historical CPU/memory/IO graphs on the Overview tab (Swift Charts)
- Removed SPICE USB redirection (unsupported on macOS); virtio-gpu GL fallback

### v0.11.0

- Config drift revert + power-action warnings; SPICE multi-monitor; sidebar stats

## Source (GPL-2.0)

Tag **`v0.13.0`**: https://github.com/muanton/virt-manager-modern/tree/v0.13.0
