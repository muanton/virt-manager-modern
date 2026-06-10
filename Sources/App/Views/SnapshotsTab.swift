import SwiftUI
import LibvirtKit

/// Snapshot management: tree-ordered list, create / revert / delete.
/// Snapshots are full system snapshots (disks + memory when the VM runs);
/// they require qcow2 storage — libvirt's error is surfaced verbatim if not.
struct SnapshotsTab: View {
    @ObservedObject var session: ConnectionSession
    let domain: DomainSummary

    @State private var snapshots: [Snapshot] = []
    @State private var loaded = false
    @State private var selection: String?
    @State private var creating = false
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var working = false
    @State private var confirmRevert: Snapshot?
    @State private var confirmDelete: Snapshot?

    var body: some View {
        VStack(spacing: 0) {
            if !loaded {
                Spacer(); ProgressView().controlSize(.large); Spacer()
            } else if snapshots.isEmpty {
                ContentUnavailableView(
                    "No Snapshots", systemImage: "camera",
                    description: Text("Snapshots capture the VM's disks — and its memory while running — so you can roll back."))
            } else {
                List(treeOrdered, id: \.snapshot.name, selection: $selection) { entry in
                    row(entry.snapshot, depth: entry.depth)
                        .tag(entry.snapshot.name)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button { newName = defaultName(); newDescription = ""; creating = true } label: {
                    Label("Take Snapshot…", systemImage: "camera")
                }
                .disabled(working)
                Spacer()
                Button("Revert…") { confirmRevert = selected }
                    .disabled(selected == nil || working)
                    .help("Roll the VM back to this snapshot's state")
                Button("Delete…") { confirmDelete = selected }
                    .disabled(selected == nil || working)
            }
            .padding(10)
        }
        .task(id: domain.uuid) { await reload() }
        .sheet(isPresented: $creating) { createSheet }
        .confirmationDialog("Revert to “\(confirmRevert?.name ?? "")”?",
            isPresented: Binding(get: { confirmRevert != nil },
                                 set: { if !$0 { confirmRevert = nil } }),
            titleVisibility: .visible, presenting: confirmRevert) { snap in
            Button("Revert", role: .destructive) { revert(snap) }
        } message: { snap in
            Text("The VM returns to its state from \(dateLabel(snap)) (\(snap.state)). The current unsaved state is lost.")
        }
        .confirmationDialog("Delete snapshot “\(confirmDelete?.name ?? "")”?",
            isPresented: Binding(get: { confirmDelete != nil },
                                 set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible, presenting: confirmDelete) { snap in
            Button("Delete", role: .destructive) { delete(snap) }
        } message: { _ in
            Text("The snapshot's saved state is discarded. The VM itself is not affected.")
        }
    }

    // MARK: - Rows / tree

    private struct TreeEntry { let snapshot: Snapshot; let depth: Int }

    /// Parent-before-child ordering with depth for indentation.
    private var treeOrdered: [TreeEntry] {
        let byParent = Dictionary(grouping: snapshots, by: { $0.parent ?? "" })
        var out: [TreeEntry] = []
        func walk(_ parent: String, depth: Int) {
            for s in (byParent[parent] ?? []).sorted(by: { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }) {
                out.append(TreeEntry(snapshot: s, depth: depth))
                walk(s.name, depth: depth + 1)
            }
        }
        walk("", depth: 0)
        // Orphans (parent not in the list) — append flat so nothing is hidden.
        let seen = Set(out.map(\.snapshot.name))
        for s in snapshots where !seen.contains(s.name) {
            out.append(TreeEntry(snapshot: s, depth: 0))
        }
        return out
    }

    private func row(_ snap: Snapshot, depth: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: snap.state == "running" ? "camera.badge.clock" : "camera")
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(depth) * 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(snap.name)
                    if snap.isCurrent {
                        Text("current")
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                Text("\(dateLabel(snap)) · VM was \(snap.state)\(snap.description.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var selected: Snapshot? { snapshots.first { $0.name == selection } }

    private func dateLabel(_ s: Snapshot) -> String {
        s.created?.formatted(date: .abbreviated, time: .shortened) ?? "unknown time"
    }

    private func defaultName() -> String {
        "snapshot-" + Date().formatted(.iso8601.year().month().day().timeSeparator(.omitted)
            .time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
    }

    // MARK: - Create sheet

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Take Snapshot").font(.title2).bold().padding([.top, .horizontal])
            Form {
                TextField("Name", text: $newName)
                TextField("Description", text: $newDescription, axis: .vertical).lineLimit(2...4)
                if domain.isActive {
                    Label("The VM is running — its memory is included, so the snapshot resumes exactly here.",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { creating = false }.keyboardShortcut(.cancelAction)
                Button(working ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || newName.isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
    }

    // MARK: - Actions

    private func reload() async {
        if let snaps = await session.snapshots(uuid: domain.uuid) {
            snapshots = snaps
        }
        loaded = true
    }

    private func create() {
        working = true
        Task {
            defer { working = false }
            if await session.createSnapshot(uuid: domain.uuid, name: newName,
                                            description: newDescription) {
                creating = false
                await reload()
            }
        }
    }

    private func revert(_ snap: Snapshot) {
        working = true
        Task {
            defer { working = false }
            _ = await session.revertToSnapshot(uuid: domain.uuid, name: snap.name)
            await reload()
        }
    }

    private func delete(_ snap: Snapshot) {
        working = true
        Task {
            defer { working = false }
            _ = await session.deleteSnapshot(uuid: domain.uuid, name: snap.name)
            await reload()
        }
    }
}
