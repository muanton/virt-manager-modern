import SwiftUI
import LibvirtKit

struct ResizeVolumeSheet: View {
    @ObservedObject var session: ConnectionSession
    let volume: StorageVolume
    var onResized: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var sizeGiB: Double
    @State private var working = false
    @State private var error: String?

    init(session: ConnectionSession, volume: StorageVolume, onResized: @escaping () -> Void) {
        self.session = session
        self.volume = volume
        self.onResized = onResized
        _sizeGiB = State(initialValue: Double(volume.capacityBytes) / 1_073_741_824.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize \(volume.name)").font(.title2).bold()
            Text("Current size: \(Format.bytes(volume.capacityBytes))")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("New size")
                Spacer()
                TextField("", value: $sizeGiB, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("GiB").foregroundStyle(.secondary)
            }

            Text("Growing a volume does not extend partitions inside the guest — resize the filesystem separately.")
                .font(.caption).foregroundStyle(.secondary)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(working ? "Resizing…" : "Resize") { resize() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || sizeGiB <= 0)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func resize() {
        working = true
        Task {
            defer { working = false }
            do {
                let bytes = UInt64(sizeGiB * 1024 * 1024 * 1024)
                try await session.resizeVolume(path: volume.path, capacityBytes: bytes)
                onResized()
                dismiss()
            } catch let err {
                error = err.localizedDescription
            }
        }
    }
}