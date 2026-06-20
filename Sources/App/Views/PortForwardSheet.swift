import SwiftUI

/// Sheet to add a guest port forward: pick (or type) a guest IP, a guest port,
/// and an optional label. The local port is auto-assigned by the SSH tunnel.
struct PortForwardSheet: View {
    let ips: [String]
    let defaultIP: String?
    let onAdd: (_ guestIP: String, _ guestPort: Int, _ label: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIP: String
    @State private var manualIP: String = ""
    @State private var portText: String = ""
    @State private var label: String = ""

    private static let manualTag = "__manual__"

    init(ips: [String], defaultIP: String?,
         onAdd: @escaping (String, Int, String) -> Void) {
        self.ips = ips
        self.defaultIP = defaultIP
        self.onAdd = onAdd
        _selectedIP = State(initialValue: defaultIP ?? ips.first ?? Self.manualTag)
    }

    private var manualMode: Bool { ips.isEmpty || selectedIP == Self.manualTag }
    private var effectiveIP: String {
        (manualMode ? manualIP : selectedIP).trimmingCharacters(in: .whitespaces)
    }
    private var port: Int? { Int(portText.trimmingCharacters(in: .whitespaces)) }
    private var canAdd: Bool {
        !effectiveIP.isEmpty && (port.map { $0 > 0 && $0 <= 65535 } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Forward Guest Port").font(.headline)
            Form {
                if !ips.isEmpty {
                    Picker("Guest IP", selection: $selectedIP) {
                        ForEach(ips, id: \.self) { Text($0).tag($0) }
                        Text("Enter manually…").tag(Self.manualTag)
                    }
                }
                if manualMode {
                    TextField("Guest IP", text: $manualIP, prompt: Text("192.168.122.50"))
                }
                TextField("Guest port", text: $portText, prompt: Text("8080"))
                TextField("Label (optional)", text: $label, prompt: Text("e.g. Home Assistant"))
            }
            .formStyle(.columns)
            HStack {
                Text("Local port is assigned automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let p = port { onAdd(effectiveIP, p, label.trimmingCharacters(in: .whitespaces)) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Tiny prompt for the guest login before opening an SSH session in Terminal.
struct SSHUserPrompt: View {
    let guestIP: String
    let onConnect: (_ user: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var user: String

    init(guestIP: String, defaultUser: String, onConnect: @escaping (String) -> Void) {
        self.guestIP = guestIP
        self.onConnect = onConnect
        _user = State(initialValue: defaultUser)
    }

    private var trimmed: String { user.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SSH to \(guestIP)").font(.headline)
            Text("Opens Terminal, jumping through the libvirt host.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Guest username", text: $user)
                .frame(width: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onConnect(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
