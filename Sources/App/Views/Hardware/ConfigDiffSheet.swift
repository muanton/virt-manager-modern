import SwiftUI
import DomainModel

struct ConfigDiffSheet: View {
    @ObservedObject var model: HardwareModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("The running VM does not match the saved configuration. Unsaved live changes are lost on reboot unless you update the saved configuration.")
                        .foregroundStyle(.secondary)

                    if model.configChanges.isEmpty {
                        Text("libvirt reports a difference but no structured changes were detected. See the raw XML below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        GroupBox("Summary") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(model.configChanges) { change in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(change.label).font(.headline)
                                        HStack(alignment: .top, spacing: 12) {
                                            diffColumn("Running", change.liveValue, tint: .orange)
                                            diffColumn("Saved", change.savedValue, tint: .blue)
                                        }
                                    }
                                    if change.id != model.configChanges.last?.id { Divider() }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let live = model.liveXML, let saved = model.persistentXML {
                        GroupBox("Raw XML") {
                            HSplitView {
                                xmlColumn("Running", live)
                                xmlColumn("Saved", saved)
                            }
                            .frame(minHeight: 280)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Configuration diff")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Update saved from running") {
                        Task {
                            await model.syncSavedFromLive()
                            dismiss()
                        }
                    }
                    .disabled(model.applying)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func diffColumn(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(tint)
            Text(value).font(.callout).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func xmlColumn(_ title: String, _ xml: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(xml)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
    }
}