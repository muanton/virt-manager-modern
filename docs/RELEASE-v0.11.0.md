# v0.11.0 — config drift, multi-monitor, sidebar polish

Native macOS app for managing remote QEMU/KVM hosts over libvirt (`qemu+ssh`).

## Highlights

### Config drift actions
- **Revert running to saved** from the Hardware tab banner and config diff sheet
  (live vCPU/memory resize + hot-plug attach/detach; other XML diffs still need a
  power-cycle)
- **Warnings before power actions** when live XML differs from persistent:
  shutdown, reboot, managed save, and force off

### SPICE multi-monitor
- Connect all SPICE display channels (not just channel 0)
- **Monitor picker** in the Console toolbar when the guest exposes more than one
  display

### Sidebar stats
- VM list subtitles use explicit labels: **CPU**, **RAM**, **Disk read/write**,
  **Net in/out** (instead of cryptic `D↓` / `N↓` abbreviations)

### Docs
- `README.md` and `ROADMAP.md` updated for shipped SPICE audio/USB, I/O stats,
  config drift, and multi-monitor

## Build from source

```sh
git clone https://github.com/muanton/virt-manager-modern.git
cd virt-manager-modern
git checkout v0.11.0
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

### v0.11.0

- Config drift: revert live to saved, power-action warnings
- SPICE multi-monitor list/select + console picker
- Sidebar stats with CPU/RAM/Disk/Net labels
- README and ROADMAP refresh

### v0.10.0

- Per-device disk and network I/O on Overview

### v0.9.x

- SPICE USB device picker; sidebar config-drift badge

### v0.8.0

- Network I/O stats, SPICE USB redirection, config drift detection polish

## Source (GPL-2.0)

Tag **`v0.11.0`**: https://github.com/muanton/virt-manager-modern/tree/v0.11.0