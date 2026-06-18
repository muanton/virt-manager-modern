import SwiftUI
import SpiceKit

/// Lists host USB devices and toggles SPICE redirection into the guest.
struct SpiceUsbPickerSheet: View {
    @ObservedObject var spice: SpiceConsoleSession
    let vmHasUsbChannel: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("USB Redirection").font(.headline)
                Spacer()
                Button("Refresh") { spice.refreshUsbDevices() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            if !vmHasUsbChannel {
                Label("This VM has no USB redirection device. Add USB Redirection in Hardware, then restart the VM.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if let msg = spice.usbMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            if spice.usbDevices.isEmpty {
                ContentUnavailableView(
                    "No USB devices",
                    systemImage: "cable.connector",
                    description: Text("Plug a USB device into this Mac, then click Refresh."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(spice.usbDevices) { device in
                    SpiceUsbDeviceRow(device: device, spice: spice)
                }
            }

            Text("Redirected devices are passed through to the guest. Some devices (hubs, keyboards used by macOS) cannot be redirected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        }
        .frame(width: 480, height: 360)
        .onAppear { spice.refreshUsbDevices() }
    }
}

private struct SpiceUsbDeviceRow: View {
    let device: SpiceUsbDevice
    @ObservedObject var spice: SpiceConsoleSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: device.connected ? "checkmark.circle.fill" : "cable.connector")
                .foregroundStyle(device.connected ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.description)
                    .lineLimit(2)
                if let reason = device.blockReason, !device.canRedirect {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if device.canRedirect {
                Toggle("Redirect", isOn: Binding(
                    get: { device.connected },
                    set: { redirect in
                        if redirect {
                            spice.connectUsbDevice(id: device.id)
                        } else {
                            spice.disconnectUsbDevice(id: device.id)
                        }
                    }))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(.vertical, 2)
    }
}