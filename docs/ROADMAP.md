# Roadmap — libvirt capability coverage

How the app's feature set maps onto what libvirt offers for **remote** management
(libvirt 12.4, qemu+ssh transport). ✅ done · 🔨 planned (phase) · ⬜ not planned.

| Area | libvirt capability | Status |
|---|---|---|
| Connections (qemu+ssh, test driver) | `virConnectOpen` | ✅ |
| VM list + live state | `virConnectListAllDomains`, `virDomainGetState` | ✅ (3 s poll) |
| Lifecycle (start/shutdown/reboot/destroy/pause/save) | `virDomain*` | ✅ |
| Create VM (wizard, per-OS tuning) | `virDomainDefineXML`, domain capabilities | ✅ |
| Hardware editing, add/remove with rules (staged) | `virDomainDefineXML` | ✅ |
| CD-ROM media change (live) | `virDomainUpdateDeviceFlags` | ✅ |
| Delete VM + storage cleanup | `virDomainUndefineFlags`, `virStorageVolDelete` | ✅ |
| Autostart, boot order, firmware info | `virDomainSet/GetAutostart` | ✅ |
| Graphical console (SPICE + VNC over SSH tunnel) | `<graphics>` + external clients | ✅ |
| **Live performance stats** (CPU %, memory) | `virConnectGetAllDomainStats` | 🔨 Phase 1 |
| **Guest IP addresses** | `virDomainInterfaceAddresses` (agent/lease) | 🔨 Phase 1 |
| **Snapshots** (create/revert/delete) | `virDomainSnapshot*` | 🔨 Phase 2 |
| **Clone VM** | XML transform + `virStorageVolCreateXMLFrom` | 🔨 Phase 3 |
| **ISO upload from the client** | `virStorageVolUpload` + streams | 🔨 Phase 4 |
| **Serial console** (headless VMs) | `virDomainOpenConsole` + streams | 🔨 Phase 5 |
| **Live hotplug** (disk/NIC/USB attach-detach) | `virDomainAttach/DetachDeviceFlags` | 🔨 Phase 6 |
| **Live CPU/memory resize** | `virDomainSetVcpusFlags/SetMemoryFlags` | 🔨 Phase 6 |
| Event-driven refresh (replace polling) | `virConnectDomainEventRegisterAny` | ⬜ later — polling works |
| Storage pool manager (pool lifecycle, usage, vol resize/wipe) | `virStoragePool*` | ⬜ later |
| Virtual network manager (define/start networks) | `virNetwork*` | ⬜ later — read-only picker today |
| VM screenshot | `virDomainScreenshot` | ⬜ — live console covers it |
| Migration between hosts | `virDomainMigrate*` | ⬜ — single-host focus |
| Checkpoints / incremental backup | `virDomainCheckpoint*` | ⬜ niche |
| Secrets management (ceph/iscsi auth) | `virSecret*` | ⬜ niche |
| Host dashboard (node CPU/mem totals) | `virNodeGetInfo`, `virNodeGetMemoryStats` | ⬜ later |
