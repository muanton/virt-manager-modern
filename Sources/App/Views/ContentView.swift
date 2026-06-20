import SwiftUI

/// Drives the add/edit connection sheet. `existing == nil` means "add".
struct ConnectionEditorContext: Identifiable {
    let id = UUID()
    var existing: ConnectionConfig?
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: SidebarSelection?
    @State private var editor: ConnectionEditorContext?
    @State private var newVMSession: ConnectionSession?
    @State private var deleteTarget: DeleteVMContext?
    @State private var cloneTarget: CloneVMContext?
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
                },
                onCloneVM: { session, domain in
                    cloneTarget = CloneVMContext(session: session, domain: domain)
                })
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 400)
        } detail: {
            switch selection {
            case .vm(let sessionID, let uuid):
                if let session = appState.session(id: sessionID) {
                    DomainDetailView(session: session, uuid: uuid,
                                     openConsoleOnce: $openConsoleOnce,
                                     onDelete: { domain in
                                         deleteTarget = DeleteVMContext(session: session, domain: domain)
                                     },
                                     onClone: { domain in
                                         cloneTarget = CloneVMContext(session: session, domain: domain)
                                     })
                        .id(selection)
                } else { unavailable }
            case .host(let sessionID):
                if let session = appState.session(id: sessionID) {
                    HostDetailView(session: session).id(selection)
                } else { unavailable }
            case nil:
                unavailable
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
                selection = .vm(sessionID: session.id, uuid: uuid)
            }
        }
        .sheet(item: $cloneTarget) { ctx in
            CloneVMSheet(session: ctx.session, domain: ctx.domain) { uuid in
                selection = .vm(sessionID: ctx.session.id, uuid: uuid)
            }
        }
        .sheet(item: $deleteTarget) { ctx in
            DeleteVMSheet(session: ctx.session, domain: ctx.domain) {
                if selection?.vmUUID == ctx.domain.uuid { selection = nil }
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Nothing Selected",
            systemImage: "server.rack",
            description: Text("Select a host or a virtual machine from the sidebar."))
    }
}
