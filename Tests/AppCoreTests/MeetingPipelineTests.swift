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

@Test func pipelineParsesActionUpdatesForFollowUp() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pepito-followup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let openID = UUID()
    let provider = PipelineScriptedProvider([
        #"{"summary":"OK","actions":[],"action_updates":[{"id":"\#(openID.uuidString)","status":"done"},"# +
        #"{"id":"pas-un-uuid","status":"done"},{"id":"\#(UUID().uuidString)","status":"n-importe-quoi"}]}"#,
    ])
    let pipeline = MeetingPipeline(provider: provider, vault: Vault(root: tmp))

    let result = try await pipeline.process(
        meeting: Meeting(title: "N+1", folderPath: "f"), transcript: "t",
        openActions: "- \(openID.uuidString): Envoyer la proposition")

    // Seul l'update valide (uuid + statut connus) est retenu ; les mal formés sont filtrés.
    #expect(result.actionUpdates.count == 1)
    #expect(result.actionUpdates.first?.id == openID)
    #expect(result.actionUpdates.first?.status == .done)
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

// MARK: - Projets et responsable « moi »

@Test func pipelineAssignsProjectsAndResolvesSelfOwner() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pepito-proj-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let migration = Project(name: "Migration SI")
    let recrutement = Project(name: "Recrutement")
    let provider = PipelineScriptedProvider([
        #"""
        {"summary":"OK","actions":[
          {"title":"Chiffrer les postes","project":"migration si","owner":"moi",
           "children":[{"title":"Demander les devis","project":"Recrutement","owner":"Marc"}]},
          {"title":"Sans projet nommé","project":null,"owner":"Claire"},
          {"title":"Projet inconnu","project":"Projet Fantôme","owner":null}
        ]}
        """#,
    ])
    let pipeline = MeetingPipeline(provider: provider, vault: Vault(root: tmp))

    // La réunion porte « Recrutement » : c'est le repli quand le modèle ne nomme rien de connu.
    let result = try await pipeline.process(
        meeting: Meeting(title: "Comité", projectID: recrutement.id, folderPath: "f"),
        transcript: "t",
        projects: [migration, recrutement],
        userName: "Antoine Pestel")

    let byTitle = Dictionary(uniqueKeysWithValues: result.actions.map { ($0.title, $0) })
    // Le nom renvoyé par le modèle est rapproché sans tenir compte de la casse.
    #expect(byTitle["Chiffrer les postes"]?.projectID == migration.id)
    // Une sous-tâche peut relever d'un autre projet que son parent.
    #expect(byTitle["Demander les devis"]?.projectID == recrutement.id)
    // project null ⇒ projet de la réunion ; projet inconnu ⇒ idem, jamais de projet inventé.
    #expect(byTitle["Sans projet nommé"]?.projectID == recrutement.id)
    #expect(byTitle["Projet inconnu"]?.projectID == recrutement.id)

    // « moi » devient un vrai nom, sinon l'action ne serait pas classée « à moi ».
    #expect(byTitle["Chiffrer les postes"]?.owner == "Antoine Pestel")
    #expect(byTitle["Chiffrer les postes"]?.resolvedInvolvement(me: "Antoine Pestel", team: []) == .own)
    #expect(byTitle["Demander les devis"]?.owner == "Marc")
    #expect(byTitle["Projet inconnu"]?.owner == nil)
}

@Test func projectsBlockOnlyListsOpenProjects() {
    let open = Project(name: "Migration SI")
    let closed = Project(name: "Ancien chantier", status: .closed)
    let block = MeetingPipeline.projectsBlock([open, closed], current: open)
    #expect(block.contains("Migration SI"))
    #expect(block.contains("Ancien chantier") == false)
    // Aucun projet ouvert : rien à dire au modèle, pas de bloc vide dans le prompt.
    #expect(MeetingPipeline.projectsBlock([closed], current: nil).isEmpty)
}

@Test func identityBlockIsEmptyWithoutAName() {
    #expect(MeetingPipeline.identityBlock("  ").isEmpty)
    #expect(MeetingPipeline.identityBlock("Antoine").contains("Antoine"))
    // Sans nom configuré, on ne réécrit pas le responsable.
    #expect(MeetingPipeline.resolveOwner("moi", userName: "") == "moi")
    #expect(MeetingPipeline.resolveOwner("Moi", userName: "Antoine") == "Antoine")
    #expect(MeetingPipeline.resolveOwner("  ", userName: "Antoine") == nil)
}
