import SwiftUI
import DomainModel
import LibvirtKit

/// What the delete sheet is acting on. Identifiable for `.sheet(item:)`.
struct DeleteVMContext: Identifiable {
    let session: ConnectionSession
    let domain: DomainSummary
    var id: String { domain.uuid }
}

/// virt-manager-style VM deletion: shows the VM's storage with per-file
/// checkboxes (writable disks pre-checked, CD-ROM media not), forces a running
/// VM off first, and undefines with full metadata cleanup.
struct DeleteVMSheet: View {
    @ObservedObject var session: ConnectionSession
    let domain: DomainSummary
    /// Called after successful deletion (so the parent can clear selection).
    var onDeleted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private struct StorageRow: Identifiable {
        let path: String
        let isCDROM: Bool
        let volume: StorageVolume?   // nil → not in any pool, can't delete
        var id: String { path }
    }

    @State private var rows: [StorageRow] = []
    @State private var checked: Set<String> = []
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Delete “\(domain.name)”?").font(.title2).bold()
                Text("This permanently removes the VM definition from \(session.config.name).")
                    .foregroundStyle(.secondary)
            }
            .padding([.top, .horizontal])

            Form {
                if domain.isActive {
                    Section {
                        Label("The VM is running — it will be forced off first.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section("Also delete storage") {
                    if !loaded {
                        ProgressView().controlSize(.small)
                    } else if rows.isEmpty {
                        Text("This VM has no file-backed storage.").foregroundStyle(.secondary)
                    } else {
                        ForEach(rows) { row in storageRow(row) }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(role: .destructive) { deleteNow() } label: {
                    Text(working ? "Deleting…" : deleteButtonTitle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || !loaded)
            }
            .padding()
        }
        .frame(width: 520)
        .task { await load() }
    }

    private func storageRow(_ row: StorageRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if row.volume != nil {
                Toggle("", isOn: Binding(
                    get: { checked.contains(row.path) },
                    set: { on in if on { checked.insert(row.path) } else { checked.remove(row.path) } }))
                    .labelsHidden()
            } else {
                Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.path).font(.callout).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if row.isCDROM { Text("CD-ROM media").font(.caption).foregroundStyle(.secondary) }
                    if let vol = row.volume {
                        Text("\(vol.pool) · \(ByteCountFormatter.string(fromByteCount: Int64(vol.capacityBytes), countStyle: .binary))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Not managed by libvirt — the file will be left in place.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var deleteButtonTitle: String {
        checked.isEmpty ? "Delete VM"
        : "Delete VM and \(checked.count) file\(checked.count == 1 ? "" : "s")"
    }

    private func load() async {
        await session.loadHostResources()
        guard let xml = await session.domainXML(uuid: domain.uuid),
              let cfg = try? DomainConfig(xml: xml) else {
            error = session.lastError ?? "Couldn't read the VM's configuration."
            loaded = true
            return
        }
        let volumesByPath = Dictionary(uniqueKeysWithValues: session.volumes.map { ($0.path, $0) })
        rows = cfg.disks.compactMap { d in
            guard let src = d.source, src.hasPrefix("/") else { return nil }
            return StorageRow(path: src, isCDROM: d.device == "cdrom",
                              volume: volumesByPath[src])
        }
        // Writable pool-managed disks are pre-checked; ISOs and unmanaged paths not.
        checked = Set(rows.filter { !$0.isCDROM && $0.volume != nil }.map(\.path))
        loaded = true
    }

    private func deleteNow() {
        working = true
        Task {
            defer { working = false }
            if await session.deleteVM(uuid: domain.uuid, deleteStoragePaths: Array(checked)) {
                onDeleted()
                dismiss()
            } else {
                error = session.lastError ?? "Deletion failed."
            }
        }
    }
}
