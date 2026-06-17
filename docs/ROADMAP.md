# Roadmap — libvirt capability coverage

How the app's feature set maps onto what libvirt offers for **remote** management
(libvirt 12.4, qemu+ssh transport). ✅ done · 🔨 planned (phase) · ⬜ not planned.

| Area | libvirt capability | Status |
|---|---|---|
| Connections (qemu+ssh, test driver) | `virConnectOpen` | ✅ |
| VM list + live state | `virConnectListAllDomains`, `virDomainGetState` | ✅ (event-driven list) |
| VM search / filter | client-side filter | ✅ |
| Lifecycle (start/shutdown/reboot/destroy/pause) | `virDomain*` | ✅ |
| Managed save (hibernate to disk) | `virDomainManagedSave*` | ✅ |
| Create VM (wizard, per-OS tuning) | `virDomainDefineXML`, domain capabilities | ✅ |
| Hardware editing, add/remove with rules (staged) | `virDomainDefineXML` | ✅ |
| CD-ROM media change (live) | `virDomainUpdateDeviceFlags` | ✅ |
| Delete VM + storage cleanup | `virDomainUndefineFlags`, `virStorageVolDelete` | ✅ |
| Autostart, boot order, firmware info | `virDomainSet/GetAutostart` | ✅ |
| Graphical console (SPICE + VNC over SSH tunnel) | `<graphics>` + external clients | ✅ |
| Console detach + fullscreen window | AppKit window reparenting | ✅ |
| SPICE clipboard (UTF-8 text) | spice-gtk main channel | ✅ |
| Live performance stats (CPU %, memory) | `virConnectGetAllDomainStats` | ✅ (5 s poll) |
| Guest IP addresses | `virDomainInterfaceAddresses` (agent/lease) | ✅ |
| QEMU guest agent status | `virDomainGetGuestInfo` | ✅ |
| Snapshots (create/revert/delete) | `virDomainSnapshot*` | ✅ |
| Clone VM | XML transform + `virStorageVolCreateXMLFrom` | ✅ |
| ISO upload from the client | `virStorageVolUpload` + streams | ✅ |
| Serial console (headless VMs) | `virDomainOpenConsole` + streams | ✅ |
| Live hotplug (disk/NIC/USB attach-detach) | `virDomainAttach/DetachDeviceFlags` | ✅ |
| Live CPU/memory resize | `virDomainSetVcpusFlags/SetMemoryFlags` | ✅ |
| Event-driven domain refresh | `virConnectDomainEventRegister` | ✅ |
| Storage pool manager (start/stop/rescan, vol create/delete) | `virStoragePool*` | ✅ |
| Storage pool event refresh | `virConnectStoragePoolEventRegisterAny` | ✅ |
| Virtual network manager (define/start/stop, XML editor) | `virNetwork*` | ✅ |
| Host dashboard (node info, VM counts, libvirt version) | `virNodeGetInfo`, `virConnectGetLibVersion` | ✅ |
| Host memory live stats | `virNodeGetMemoryStats` | ✅ |
| Keyboard shortcuts (lifecycle) | — | ✅ |
| CI (swift test + app build) | — | ✅ |
| Volume resize / wipe | `virStorageVolResize`, `virStorageVolWipe` | ⬜ later |
| VM screenshot | `virDomainScreenshot` | ⬜ — live console covers it |
| SPICE audio / USB redirection | spice-gtk channels | ⬜ later |
| Multi-monitor / virtio-gpu GL scanout | spice-gtk | ⬜ later |
| Migration between hosts | `virDomainMigrate*` | ⬜ — single-host focus |
| Checkpoints / incremental backup | `virDomainCheckpoint*` | ⬜ niche |
| Secrets management (ceph/iscsi auth) | `virSecret*` | ⬜ niche |
| Developer ID signing + notarization | — | ⬜ distribution |