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
    @State private var createInPool: PoolRef?
    @State private var resizeVolume: StorageVolume?
    @State private var confirmWipe: StorageVolume?
    @State private var showingUpload = false
    @State private var transferProgress: Double?
    @State private var transferLabel: String?

    private struct PoolRef: Identifiable {
        let name: String
        var id: String { name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Storage on \(session.config.name)").font(.title2).bold()
                Spacer()
                Button { Task { await reload() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(working)
                Button { showingUpload = true } label: {
                    Label("Upload ISO…", systemImage: "square.and.arrow.up")
                }
                .disabled(working)
            }
            .padding()

            if let transferProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: transferProgress)
                    Text(transferLabel ?? "Transferring…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

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
        .sheet(isPresented: $showingUpload) {
            UploadISOSheet(session: session) { _ in
                Task { await reload() }
            }
        }
        .sheet(item: $createInPool) { ref in
            CreateVolumeSheet(session: session, pool: ref.name) {
                Task { await reload() }
            }
        }
        .sheet(item: $resizeVolume) { vol in
            ResizeVolumeSheet(session: session, volume: vol) {
                Task { await reload() }
            }
        }
        .confirmationDialog(
            "Delete volume “\(confirmDelete?.name ?? "")”?",
            isPresented: Binding(get: { confirmDelete != nil },
                                 set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible, presenting: confirmDelete) { vol in
            Button("Delete", role: .destructive) { deleteVolume(vol) }
        } message: { _ in
            Text("The volume file is removed from the host. VMs referencing it may break.")
        }
        .confirmationDialog(
            "Wipe volume “\(confirmWipe?.name ?? "")”?",
            isPresented: Binding(get: { confirmWipe != nil },
                                 set: { if !$0 { confirmWipe = nil } }),
            titleVisibility: .visible, presenting: confirmWipe) { vol in
            Button("Wipe", role: .destructive) { wipeVolume(vol) }
        } message: { _ in
            Text("Overwrites the volume with zeros. This cannot be undone.")
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
            if pool.active {
                Button {
                    createInPool = PoolRef(name: pool.name)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Create a new volume in this pool")
                .disabled(working)
            }
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
            Button { downloadVolume(vol) } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .help("Download to this Mac")
            .disabled(working)
            Button { resizeVolume = vol } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Resize volume")
            .disabled(working)
            Button { confirmWipe = vol } label: {
                Image(systemName: "eraser")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("Wipe volume (secure erase)")
            .disabled(working)
            Button(role: .destructive) { confirmDelete = vol } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Delete volume")
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

    private func wipeVolume(_ vol: StorageVolume) {
        working = true
        Task {
            defer { working = false }
            do {
                try await session.wipeVolume(path: vol.path)
                error = nil
            } catch let err {
                error = err.localizedDescription
            }
        }
    }

    private func downloadVolume(_ vol: StorageVolume) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = vol.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        transferLabel = "Downloading \(vol.name)…"
        transferProgress = 0
        Task {
            defer {
                working = false
                transferProgress = nil
                transferLabel = nil
            }
            do {
                try await session.downloadVolume(path: vol.path, localURL: url) { p in
                    transferProgress = p
                }
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