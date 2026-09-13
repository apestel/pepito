import SwiftUI
import AppCore

/// Point d'entrée de l'app macOS : menu bar (contrôle rapide), fenêtre principale (timeline +
/// suivi) et interface d'administration.
@main
struct PepitoApp: App {
    @State private var app = MeetingCoordinator()

    var body: some Scene {
        MenuBarExtra("Pépito", systemImage: app.isRecording ? "record.circle.fill" : "waveform.circle") {
            MenuBarContent(app: app).storageAlert(app)
        }
        .menuBarExtraStyle(.window)

        Window("Pépito", id: "main") {
            MainView(app: app).storageAlert(app)
        }

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
