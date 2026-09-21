import SwiftUI
import AppCore

/// Point d'entrée de l'app macOS : menu bar (contrôle rapide), fenêtre principale (timeline +
/// suivi) et interface d'administration.
@main
struct PepitoApp: App {
    @State private var app: MeetingCoordinator

    init() {
        // QA dans une base dédiée : aucune lecture des données ou du token de l'installation.
        if let path = ProcessInfo.processInfo.environment["PEPITO_PREVIEW_ROOT"] {
            let root = URL(fileURLWithPath:path)
            let coordinator = MeetingCoordinator(settingsStore:SettingsStore(fileURL:root.appending(path:"settings.json")),database:Database(path:root.appending(path:"pepito.db")),tokenStore:InMemoryTokenStore(),recordingsRoot:root.appending(path:"recordings"))
            coordinator.beginMission()
            _app = State(initialValue:coordinator)
        } else { _app = State(initialValue:MeetingCoordinator()) }
    }

    var body: some Scene {
        MenuBarExtra("Pépito", systemImage: app.isRecording ? "record.circle.fill" : "waveform.circle") {
            MenuBarContent(app: app).storageAlert(app)
        }
        .menuBarExtraStyle(.menu)

        Window("Pépito", id: "main") {
            MainView(app: app).storageAlert(app)
                .onAppear { if ProcessInfo.processInfo.environment["PEPITO_PREVIEW_ROOT"] != nil { NSApp.activate(ignoringOtherApps:true) } }
        }

        .defaultLaunchBehavior(ProcessInfo.processInfo.environment["PEPITO_PREVIEW_ROOT"] == nil ? .automatic : .presented)

        Window("Réglages", id: "settings") {
            AdminView(app: app).storageAlert(app)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // Fenêtre de nommage : ouverte à l'arrêt d'un enregistrement (nom + tags + traitement).
        Window("Nommer la réunion", id: "naming") {
            NamingView(app: app).storageAlert(app)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

private extension View {
    @MainActor
    func storageAlert(_ app: MeetingCoordinator) -> some View {
        alert("Erreur de stockage", isPresented: Binding(
            get: { app.storageError != nil },
            set: { if !$0 { app.storageError = nil } }
        )) {
            Button("OK", role: .cancel) { app.storageError = nil }
        } message: {
            Text(app.storageError ?? "")
        }
    }
}
