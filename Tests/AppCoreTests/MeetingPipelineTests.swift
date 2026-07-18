import Testing
import Foundation
import os
import AIKit
import VaultKit
@testable import AppCore

// Provider scripté : renvoie des réponses préparées dans l'ordre.
final class PipelineScriptedProvider: AIProvider {
    private let responses: [String]
    private let index = OSAllocatedUnfairLock(initialState: 0)
    init(_ responses: [String]) { self.responses = responses }
    func complete(messages: [ChatMessage]) async throws -> ChatMessage {
        let i = index.withLock { v -> Int in let c = v; v += 1; return c }
        return ChatMessage(role: .assistant, content: i < responses.count ? responses[i] : "{}")
    }
}

// Échoue au premier appel, réussit ensuite : simule un échec LLM transitoire (pour tester la reprise).
final class FailingOnceProvider: AIProvider {
    struct Boom: Error {}
    private let success: String
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    init(success: String) { self.success = success }
    func complete(messages: [ChatMessage]) async throws -> ChatMessage {
        let n = calls.withLock { v -> Int in v += 1; return v }
        if n == 1 { throw Boom() }
        return ChatMessage(role: .assistant, content: success)
    }
}

@Test func pipelineParsesAnalysisAndWritesVault() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-pipeline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let vault = Vault(root: tmp)

    // Une seule réponse JSON structurée — aucun appel d'outil. Action avec une sous-tâche.
    let provider = PipelineScriptedProvider([
        #"""
        {"summary":"Résumé - Décision X","tags":["budget"],
         "actions":[{"title":"Préparer le budget","owner":"Alice","priority":"high",
           "children":[{"title":"Chiffrer les postes"}]}]}
        """#,
    ])

    let pipeline = MeetingPipeline(provider: provider, vault: vault)
    let meeting = Meeting(title: "Sync", participants: ["Alice", "Bob"], folderPath: "2026/07/15-sync")

    let result = try await pipeline.process(meeting: meeting, transcript: "…transcript…")

    #expect(result.summary?.contains("Décision X") == true)
    // Parent + sous-tâche aplatis avec parentID.
    #expect(result.actions.count == 2)
    let parent = try #require(result.actions.first { $0.title == "Préparer le budget" })
    let child = try #require(result.actions.first { $0.title == "Chiffrer les postes" })
    #expect(parent.owner == "Alice")
    #expect(parent.priority == .high)
    #expect(parent.meetingID == meeting.id)
    #expect(child.parentID == parent.id)

    // Résumé + plan d'action écrits dans le Vault.
    #expect(Set(result.documentsWritten) == ["2026/07/15-sync/summary.md", "2026/07/15-sync/action-plan.md"])
    #expect(vault.exists(relativePath: "2026/07/15-sync/summary.md"))
    let plan = try vault.read(relativePath: "2026/07/15-sync/action-plan.md", type: .actionPlan)
    #expect(plan.markdown.contains("Préparer le budget"))
    #expect(plan.markdown.contains("Chiffrer les postes"))
}

@Test func pipelineToleratesProseAroundJSON() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pepito-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let provider = PipelineScriptedProvider([
        "Voici le JSON :\n```json\n{\"summary\":\"OK\",\"actions\":[]}\n```\nVoilà.",
    ])
    let pipeline = MeetingPipeline(provider: provider, vault: Vault(root: tmp))
    let result = try await pipeline.process(
        meeting: Meeting(title: "X", folderPath: "f"),
        transcript: "t"
    )
    #expect(result.summary == "OK")
    #expect(result.actions.isEmpty)
}
