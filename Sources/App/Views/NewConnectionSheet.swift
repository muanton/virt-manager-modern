import SwiftUI

/// Add or edit a libvirt connection — modelled on virt-manager's
/// "Add Connection" dialog (hypervisor, remote method, user/host, autoconnect),
/// with an escape hatch for entering a raw URI.
struct ConnectionEditorSheet: View {
    /// The connection being edited, or `nil` to create a new one.
    var existing: ConnectionConfig?
    var onSave: (ConnectionConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hypervisor: Hypervisor = .qemuSystem
    @State private var isRemote = true
    @State private var transport: Transport = .ssh
    @State private var user = ""
    @State private var host = ""
    @State private var portText = ""
    @State private var autoconnect = false
    @State private var useCustomURI = false
    @State private var customURI = ""

    private var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "Edit Connection" : "New Connection")
                .font(.title2).bold()
                .padding([.top, .horizontal])

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(defaultName))
                    Toggle("Enter a raw libvirt URI instead", isOn: $useCustomURI)
                }

                if useCustomURI {
                    Section("URI") {
                        TextField("URI", text: $customURI,
                                  prompt: Text("qemu+ssh://user@host/system"))
                    }
                } else {
                    Section("Hypervisor") {
                        Picker("Hypervisor", selection: $hypervisor) {
                            ForEach(Hypervisor.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if hypervisor.supportsRemote {
                            Toggle("Connect to remote host", isOn: $isRemote)
                        }
                    }

                    if hypervisor.supportsRemote && isRemote {
                        Section("Remote Host") {
                            Picker("Method", selection: $transport) {
                                ForEach(Transport.allCases) { Text($0.label).tag($0) }
                            }
                            TextField("Username", text: $user, prompt: Text("root"))
                            TextField("Hostname", text: $host, prompt: Text("server.example.com"))
                            TextField("Port", text: $portText, prompt: Text("default"))
                        }
                    }
                }

                Section {
                    Toggle("Connect automatically on launch", isOn: $autoconnect)
                    LabeledContent("Resulting URI", value: builtConfig.uri)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") {
                    onSave(builtConfig)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear(perform: loadExisting)
    }

    // MARK: - Derived

    private var defaultName: String {
        if useCustomURI { return customURI.isEmpty ? "Connection" : customURI }
        if hypervisor.supportsRemote && isRemote { return host.isEmpty ? "Remote" : host }
        return hypervisor.rawValue
    }

    private var isValid: Bool {
        if useCustomURI { return !customURI.isEmpty }
        if hypervisor.supportsRemote && isRemote { return !host.isEmpty }
        return true
    }

    private var builtConfig: ConnectionConfig {
        let id = existing?.id ?? UUID()
        let finalName = name.isEmpty ? defaultName : name

        if useCustomURI {
            return ConnectionConfig(id: id, name: finalName,
                                    customURI: customURI, autoconnect: autoconnect)
        }
        let remote = hypervisor.supportsRemote && isRemote
        return ConnectionConfig(
            id: id,
            name: finalName,
            driver: hypervisor.driver,
            transport: remote ? transport.rawValue : nil,
            user: remote && !user.isEmpty ? user : nil,
            host: remote && !host.isEmpty ? host : nil,
            port: remote ? Int(portText) : nil,
            path: hypervisor.path,
            customURI: hypervisor == .test ? "test:///default" : nil,
            autoconnect: autoconnect)
    }

    // MARK: - Populate fields when editing

    private func loadExisting() {
        guard let c = existing else { return }
        name = c.name
        autoconnect = c.autoconnect

        // The test driver carries a customURI but is best shown as its hypervisor.
        if let uri = c.customURI, uri != "test:///default" {
            useCustomURI = true
            customURI = uri
            return
        }

        hypervisor = Self.hypervisor(driver: c.driver, path: c.path)
        isRemote = c.transport != nil
        transport = Transport(rawValue: c.transport ?? "ssh") ?? .ssh
        user = c.user ?? ""
        host = c.host ?? ""
        portText = c.port.map(String.init) ?? ""
    }

    private static func hypervisor(driver: String, path: String) -> Hypervisor {
        switch (driver, path) {
        case ("qemu", "session"): return .qemuSession
        case ("qemu", _):         return .qemuSystem
        case ("xen", _):          return .xen
        case ("lxc", _):          return .lxc
        case ("bhyve", _):        return .bhyve
        case ("test", _):         return .test
        default:                  return .qemuSystem
        }
    }
}
