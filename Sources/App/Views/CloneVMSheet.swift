import SwiftUI
import DomainModel
import LibvirtKit

struct CloneVMContext: Identifiable {
    let session: ConnectionSession
    let domain: DomainSummary
    var id: String { domain.uuid }
}

/// Clones a shut-off VM: new name/UUID, regenerated MACs and NVRAM, and a
/// per-disk choice of Clone (full copy in the same pool) / Share / Skip.
struct CloneVMSheet: View {
    @ObservedObject var session: ConnectionSession
    let domain: DomainSummary
    var onCloned: (String) -> Void = { _ in }   // new VM uuid

    @Environment(\.dismiss) private var dismiss

    enum DiskAction: String, CaseIterable, Identifiable {
        case clone = "Clone", share = "Share", skip = "Skip"
        var id: String { rawValue }
    }
    private struct DiskRow: Identifiable {
        let path: String
        let isCDROM: Bool
        var id: String { path }
    }

    @State private var newName = ""
    @State private var rows: [DiskRow] = []
    @State private var actions: [String: DiskAction] = [:]
    @State private var loaded = false
    @State private var working = false
    @State private var progress = ""
    @State private var error: String?
    @State private var config: DomainConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clone “\(domain.name)”").font(.title2).bold()
                Text("Creates an independent copy with a new UUID and MAC addresses.")
                    .foregroundStyle(.secondary)
            }
            .padding([.top, .horizontal])

            Form {
                Section {
                    LabeledContent("New name") {
                        TextField("", text: $newName).frame(maxWidth: 260)
                    }
                    if nameTaken {
                        Label("A VM with this name already exists", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Storage") {
                    if !loaded {
                        ProgressView().controlSize(.small)
                    } else if rows.isEmpty {
                        Text("This VM has no file-backed disks.").foregroundStyle(.secondary)
                    } else {
                        ForEach(rows) { row in
                            LabeledContent {
                                Picker("", selection: Binding(
                                    get: { actions[row.path] ?? .share },
                                    set: { actions[row.path] = $0 })) {
                                    ForEach(DiskAction.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden().pickerStyle(.segmented).fixedSize()
                            } label: {
                                Text(row.path).font(.callout)
                                    .lineLimit(1).truncationMode(.middle)
                                if row.isCDROM {
                                    Text("CD-ROM media").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Clone copies the disk in its pool · Share reuses the same file (careful with writable disks) · Skip detaches it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if working, !progress.isEmpty {
                    Section { Label(progress, systemImage: "hourglass").foregroundStyle(.secondary) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Cloning…" : "Clone") { clone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !loaded || newName.isEmpty || nameTaken)
            }
            .padding()
        }
        .frame(width: 560)
        .task { await load() }
    }

    private var nameTaken: Bool {
        session.domains.contains { $0.name == newName }
    }

    private func load() async {
        newName = uniqueName(base: "\(domain.name)-clone")
        guard let xml = await session.domainXML(uuid: domain.uuid),
              let cfg = try? DomainConfig(xml: xml) else {
            error = session.lastError ?? "Couldn't read the VM's configuration."
            loaded = true
            return
        }
        config = cfg
        rows = cfg.disks.compactMap { d in
            guard let src = d.source, src.hasPrefix("/") else { return nil }
            return DiskRow(path: src, isCDROM: d.device == "cdrom")
        }
        for r in rows {
            actions[r.path] = r.isCDROM ? .share : .clone
        }
        loaded = true
    }

    private func uniqueName(base: String) -> String {
        var name = base
        var i = 2
        while session.domains.contains(where: { $0.name == name }) {
            name = "\(base)-\(i)"; i += 1
        }
        return name
    }

    private func clone() {
        guard let config else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            var pathMap: [String: String] = [:]
            for row in rows {
                switch actions[row.path] ?? .share {
                case .share:
                    continue
                case .skip:
                    pathMap[row.path] = ""   // handled below by removing the source
                case .clone:
                    progress = "Copying \((row.path as NSString).lastPathComponent)…"
                    let volName = cloneVolumeName(row.path)
                    guard let newPath = await session.cloneVolume(path: row.path, newName: volName) else {
                        error = session.lastError ?? "Failed to clone \(row.path)"
                        return
                    }
                    pathMap[row.path] = newPath
                }
            }
            progress = "Defining \(newName)…"
            let xml = config.xmlForClone(newName: newName, diskPathMap: pathMap)
            if let uuid = await session.defineAndReturnUUID(xml) {
                onCloned(uuid)
                dismiss()
            } else {
                error = session.lastError ?? "Failed to define the clone."
            }
        }
    }

    private func cloneVolumeName(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        let stem = (file as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem)-\(newName)" : "\(stem)-\(newName).\(ext)"
    }
}
