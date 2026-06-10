import SwiftUI

/// Drives the add/edit connection sheet. `existing == nil` means "add".
struct ConnectionEditorContext: Identifiable {
    let id = UUID()
    var existing: ConnectionConfig?
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: DomainSelection?
    @State private var editor: ConnectionEditorContext?
    @State private var newVMSession: ConnectionSession?
    @State private var deleteTarget: DeleteVMContext?
    @State private var openConsoleOnce = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selection,
                onAdd: { editor = ConnectionEditorContext(existing: nil) },
                onEdit: { editor = ConnectionEditorContext(existing: $0) },
                onNewVM: { newVMSession = $0 },
                onDeleteVM: { session, domain in
                    deleteTarget = DeleteVMContext(session: session, domain: domain)
                })
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 400)
        } detail: {
            if let selection, let session = appState.session(id: selection.sessionID) {
                DomainDetailView(session: session, uuid: selection.uuid,
                                 openConsoleOnce: $openConsoleOnce,
                                 onDelete: { domain in
                                     deleteTarget = DeleteVMContext(session: session, domain: domain)
                                 })
                    .id(selection)
            } else {
                ContentUnavailableView(
                    "No VM Selected",
                    systemImage: "desktopcomputer",
                    description: Text("Select a virtual machine from the sidebar."))
            }
        }
        .sheet(item: $editor) { ctx in
            ConnectionEditorSheet(existing: ctx.existing) { config in
                if ctx.existing != nil {
                    appState.updateConnection(config)
                } else {
                    appState.addConnection(config)
                }
            }
        }
        .sheet(item: $newVMSession) { session in
            NewVMSheet(session: session) { uuid, openConsole in
                openConsoleOnce = openConsole
                selection = DomainSelection(sessionID: session.id, uuid: uuid)
            }
        }
        .sheet(item: $deleteTarget) { ctx in
            DeleteVMSheet(session: ctx.session, domain: ctx.domain) {
                if selection?.uuid == ctx.domain.uuid { selection = nil }
            }
        }
    }
}
