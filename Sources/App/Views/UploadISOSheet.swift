import SwiftUI
import UniformTypeIdentifiers

/// Uploads a local ISO into a host storage pool over the libvirt stream API —
/// no scp needed. Used from the New VM wizard and Add Hardware → CD-ROM.
struct UploadISOSheet: View {
    @ObservedObject var session: ConnectionSession
    /// Called with the uploaded volume's path on the host.
    var onUploaded: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var fileURL: URL?
    @State private var pool = "default"
    @State private var working = false
    @State private var progress = 0.0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Upload ISO to \(session.config.name)")
                .font(.title2).bold().padding([.top, .horizontal])

            Form {
                LabeledContent("File") {
                    HStack {
                        Text(fileURL?.lastPathComponent ?? "none selected")
                            .foregroundStyle(fileURL == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { choose() }.disabled(working)
                    }
                }
                Picker("Pool", selection: $pool) {
                    ForEach(session.storagePools, id: \.self) { Text($0) }
                }
                .disabled(working)
                if let size = fileSize {
                    LabeledContent("Size", value: ByteCountFormatter.string(
                        fromByteCount: size, countStyle: .file))
                }
                if working {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))% — uploading over SSH, this can take a while…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(working ? "Uploading…" : "Upload") { upload() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || fileURL == nil)
            }
            .padding()
        }
        .frame(width: 460)
        .task {
            await session.loadHostResources()
            if !session.storagePools.contains(pool), let first = session.storagePools.first {
                pool = first
            }
        }
    }

    private var fileSize: Int64? {
        guard let fileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { fileURL = panel.url }
    }

    private func upload() {
        guard let fileURL else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let path = try await session.uploadISO(
                    pool: pool, name: fileURL.lastPathComponent, localURL: fileURL,
                    progress: { progress = $0 })
                onUploaded(path)
                dismiss()
            } catch let err {
                error = err.localizedDescription
            }
        }
    }
}
