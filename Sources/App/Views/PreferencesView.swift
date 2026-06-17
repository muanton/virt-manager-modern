import SwiftUI

struct PreferencesView: View {
    @ObservedObject var prefs: AppPreferences

    private let tabNames = ["Overview", "Console", "Hardware", "Snapshots"]

    var body: some View {
        Form {
            Section("Console") {
                Toggle("SPICE clipboard sharing", isOn: $prefs.spiceClipboardEnabled)
                Toggle("VNC clipboard redirection", isOn: $prefs.vncClipboardEnabled)
            }
            Section("Navigation") {
                Picker("Default tab when opening a VM", selection: $prefs.defaultDetailTab) {
                    ForEach(Array(tabNames.enumerated()), id: \.offset) { i, name in
                        Text(name).tag(i)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}