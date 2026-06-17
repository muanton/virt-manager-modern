import SwiftUI
import LibvirtKit

struct StoragePoolsSheet: View {
    @ObservedObject var session: ConnectionSession
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var expandedPools: Set<String> = []
    @State private var confirmDelete: StorageVolume?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Storage on \(session.config.name)").font(.title2).bold()
                Spacer()
                Button { Task { await reload() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(working)
            }
            .padding()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .padding(.horizontal)
            }

            if !loaded {
                Spacer()
                ProgressView().controlSize(.large).frame(maxWidth: .infinity)
                Spacer()
            } else if session.pools.isEmpty {
                ContentUnavailableView("No Storage Pools", systemImage: "externaldrive",
                    description: Text("No libvirt storage pools were found on this host."))
            } else {
                List {
                    ForEach(session.pools) { pool in
                        Section {
                            if expandedPools.contains(pool.name) {
                                let vols = session.volumes.filter { $0.pool == pool.name }
                                if vols.isEmpty {
                                    Text("No volumes").foregroundStyle(.secondary)
                                } else {
                                    ForEach(vols) { vol in
                                        volumeRow(vol)
                                    }
                                }
                            }
                        } header: {
                            poolHeader(pool)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 480)
        .task { await reload() }
        .confirmationDialog(
            "Delete volume “\(confirmDelete?.name ?? "")”?",
            isPresented: Binding(get: { confirmDelete != nil },
                                 set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible, presenting: confirmDelete) { vol in
            Button("Delete", role: .destructive) { deleteVolume(vol) }
        } message: { _ in
            Text("The volume file is removed from the host. VMs referencing it may break.")
        }
    }

    private func poolHeader(_ pool: StoragePoolInfo) -> some View {
        HStack(spacing: 10) {
            Button {
                if expandedPools.contains(pool.name) {
                    expandedPools.remove(pool.name)
                } else {
                    expandedPools.insert(pool.name)
                }
            } label: {
                Image(systemName: expandedPools.contains(pool.name) ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pool.name).font(.headline)
                    Text(pool.active ? "active" : "inactive")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(pool.active ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15)))
                }
                if pool.capacityBytes > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(pool.allocationBytes),
                                     total: Double(max(pool.capacityBytes, 1)))
                            .frame(width: 120)
                        Text("\(Format.bytes(pool.allocationBytes)) of \(Format.bytes(pool.capacityBytes))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Spacer()
            if pool.active {
                Button("Stop") { setActive(pool.name, false) }
                    .disabled(working)
            } else {
                Button("Start") { setActive(pool.name, true) }
                    .disabled(working)
            }
            Button("Rescan") { refresh(pool.name) }
                .disabled(working)
        }
    }

    private func volumeRow(_ vol: StorageVolume) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(vol.name)
                Text(vol.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Format.bytes(vol.capacityBytes))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button(role: .destructive) { confirmDelete = vol } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }

    private func reload() async {
        working = true
        defer { working = false }
        do {
            try await session.loadStoragePools()
            if expandedPools.isEmpty {
                expandedPools = Set(session.pools.map(\.name))
            }
            error = nil
        } catch let err {
            error = err.localizedDescription
        }
        loaded = true
    }

    private func setActive(_ name: String, _ active: Bool) {
        working = true
        Task {
            defer { working = false }
            do {
                try await session.setPoolActive(name: name, active: active)
                error = nil
            } catch let err {
                error = err.localizedDescription
            }
        }
    }

    private func refresh(_ name: String) {
        working = true
        Task {
            defer { working = false }
            do {
                try await session.refreshPool(name: name)
                error = nil
            } catch let err {
                error = err.localizedDescription
            }
        }
    }

    private func deleteVolume(_ vol: StorageVolume) {
        working = true
        Task {
            defer { working = false }
            do {
                try await session.deleteVolume(path: vol.path)
                error = nil
            } catch let err {
                error = err.localizedDescription
            }
        }
    }
}