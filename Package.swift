// swift-tools-version: 6.2
import PackageDescription

// Pépito — assistant de réunion natif macOS (voir CLAUDE.md / PLAN.md).
// Monorepo SwiftPM : un module (target) par Kit, avec règles de dépendance strictes
// (AppUI/App → AppCore → Kits). Chaque module est extractible en package indépendant plus tard.
let package = Package(
    name: "Pepito",
    platforms: [.macOS(.v26)], // SpeechAnalyzer/SpeechTranscriber requièrent macOS 26 (Tahoe)
    products: [
        .executable(name: "Pepito", targets: ["Pepito"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "AIKit", targets: ["AIKit"]),
        .library(name: "VaultKit", targets: ["VaultKit"]),
        .library(name: "ActionKit", targets: ["ActionKit"]),
        .library(name: "MailKit", targets: ["MailKit"]),
    ],
    dependencies: [],
    targets: [
        // App shell (SwiftUI, menu bar + fenêtre principale). Ne dépend que d'AppCore.
        .executableTarget(
            name: "Pepito",
            dependencies: ["AppCore"]
        ),
        // Coordination + modèles de domaine. Point d'assemblage des Kits.
        .target(
            name: "AppCore",
            dependencies: ["CaptureKit", "TranscriptionKit", "AIKit", "VaultKit", "ActionKit", "MailKit", "AgentKit", "SandboxKit"],
            linkerSettings: [.linkedLibrary("sqlite3")] // module SQLite3 fourni par le SDK macOS
        ),
        // Kits : ne dépendent PAS de l'UI ni d'AppCore.
        .target(name: "CaptureKit"),
        .target(name: "TranscriptionKit"),
        .target(name: "AIKit"),
        .target(name: "AgentKit"),
        .executableTarget(name: "PepitoAgentProbe", dependencies: ["AppCore", "SandboxKit"]),
        .target(name: "SandboxKit"),
        .target(name: "VaultKit"),
        .target(name: "ActionKit"),
        .target(name: "MailKit"),

        // Tests (swift-testing).
        .testTarget(name: "PepitoTests", dependencies: ["Pepito"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        .testTarget(name: "TranscriptionKitTests", dependencies: ["TranscriptionKit"]),
        .testTarget(name: "AIKitTests", dependencies: ["AIKit"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "SandboxKitTests", dependencies: ["SandboxKit"]),
        .testTarget(name: "VaultKitTests", dependencies: ["VaultKit"]),
        .testTarget(name: "ActionKitTests", dependencies: ["ActionKit"]),
        .testTarget(name: "MailKitTests", dependencies: ["MailKit"]),
    ]
)
