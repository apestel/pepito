import SwiftUI
import AppCore

/// Point d'entrée de l'app macOS : menu bar (contrôle rapide), fenêtre principale (timeline +
/// suivi) et interface d'administration.
@main
struct PepitoApp: App {
    @State private var app = MeetingCoordinator()

    var body: some Scene {
        MenuBarExtra("Pépito", systemImage: app.isRecording ? "record.circle.fill" : "waveform.circle") {
            MenuBarContent(app: app)
        }
        .menuBarExtraStyle(.window)

        Window("Pépito", id: "main") {
            MainView(app: app)
        }

        Window("Réglages", id: "settings") {
            AdminView(app: app)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // Fenêtre de nommage : ouverte à l'arrêt d'un enregistrement (nom + tags + traitement).
        Window("Nommer la réunion", id: "naming") {
            NamingView(app: app)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
