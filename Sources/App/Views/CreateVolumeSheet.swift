import SwiftUI
import LibvirtKit

struct CreateVolumeSheet: View {
    @ObservedObject var session: ConnectionSession
    let pool: String
    var onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var sizeGiB: Double = 20
    @State private var format = "qcow2"
    @State private var working = false
    @State private var error: String?

    private let formats = ["qcow2", "raw"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Volume in \(pool)").font(.title2).bold()

            Form {
                TextField("Name", text: $name)
                HStack {
                    Text("Size")
                    Spacer()
                    TextField("", value: $sizeGiB, format: .number.precision(.fractionLength(0...1)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("GiB").foregroundStyle(.secondary)
                }
                Picker("Format", selection: $format) {
                    ForEach(formats, id: \.self) { Text($0).tag($0) }
                }
            }
            .formStyle(.grouped)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(working ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || sizeGiB <= 0)
            }
        }
        .padding()
        .frame(width: 380)
        .onAppear {
            if name.isEmpty { name = "disk-\(Int(Date().timeIntervalSince1970) % 100_000)" }
        }
    }

    private func create() {
        working = true
        Task {
            defer { working = false }
            do {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                let bytes = UInt64(sizeGiB * 1024 * 1024 * 1024)
                _ = try await session.createVolume(pool: pool, name: trimmed,
                                                   capacityBytes: bytes, format: format)
                onCreated()
                dismiss()
            } catch let err {
                error = err.localizedDescription
            }
        }
    }
}