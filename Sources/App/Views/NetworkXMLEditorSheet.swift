import SwiftUI
import LibvirtKit

struct NetworkEditorContext: Identifiable {
    let id = UUID()
    /// `nil` when defining a new network from scratch.
    var existingName: String?
    var xml: String
    var startAfterApply: Bool
}

struct NetworkXMLEditorSheet: View {
    @ObservedObject var session: ConnectionSession
    @State var context: NetworkEditorContext
    var onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(context.existingName.map { "Edit Network — \($0)" } ?? "New Network")
                    .font(.title2).bold()
                Spacer()
                Toggle("Start after apply", isOn: $context.startAfterApply)
                    .toggleStyle(.checkbox)
            }
            .padding()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption).padding(.horizontal)
            }

            TextEditor(text: $context.xml)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(working ? "Applying…" : "Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || context.xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .padding(.horizontal)
        .frame(width: 620, height: 480)
    }

    private func apply() {
        working = true
        Task {
            defer { working = false }
            do {
                let net = try await session.defineNetwork(xml: context.xml)
                if context.startAfterApply {
                    try await session.setNetworkActive(name: net.name, active: true)
                }
                onApplied()
                dismiss()
            } catch let err {
                error = err.localizedDescription
            }
        }
    }
}