import Testing
import Foundation
import AIKit
import VaultKit
@testable import AppCore

private actor BudgetProvider: AIProvider {
    var requests: [[ChatMessage]] = []
    let echo: Bool
    init(echo: Bool = false) { self.echo = echo }
    func complete(messages: [ChatMessage]) async throws -> ChatMessage {
        requests.append(messages)
        let text: String
        if messages[0].content.contains("Condense les données") {
            text = echo ? messages[1].content : "Alice doit livrer le budget vendredi."
        } else {
            text = #"{"summary":"Alice doit livrer le budget vendredi.","actions":[]}"#
        }
        return ChatMessage(role: .assistant, content: text)
    }
}

@Test(arguments: [false, true])
func pipelineBoundsEveryRequestIncludingCustomTranscriptPlaceholder(long: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pepito-budget-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = BudgetProvider()
    let transcript = String(repeating: "Alice doit livrer le budget vendredi.\n", count: long ? 4000 : 1)
    let meeting = Meeting(title: "Budget", folderPath: "meeting", summaryInstructions: "Mets les échéances en avant")
    _ = try await MeetingPipeline(provider: provider, vault: Vault(root: root)).process(
        meeting: meeting, transcript: transcript, agenticPrompt: "Analyse : {{transcript}}",
        inputTokenBudget: 4000)
    let requests = await provider.requests
    #expect(long ? requests.count > 1 : requests.count == 1)
    #expect(requests.allSatisfy { $0.reduce(0) { $0 + TokenEstimator.estimateTokens($1.content) + 16 } <= 4000 })
    #expect(requests.last?[0].content.contains("Mets les échéances en avant") == true)
    #expect(requests.last?[1].content.contains("Alice doit livrer le budget vendredi.") == true)
    if !long { #expect(requests.last?[1].content == transcript) }
}

@Test func pipelineStopsNonReducingOrOversizedPromptsWithoutWritingDocuments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pepito-budget-fail-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = BudgetProvider(echo: true)
    let pipeline = MeetingPipeline(provider: provider, vault: Vault(root: root))
    let meeting = Meeting(title: "Test", folderPath: "meeting")
    await #expect(throws: AIError.self) {
        try await pipeline.process(meeting: meeting, transcript: String(repeating: "a", count: 50000), inputTokenBudget: 4000)
    }
    let count = await provider.requests.count
    await #expect(throws: AIError.self) {
        try await pipeline.process(meeting: meeting, transcript: "Court", agenticPrompt: String(repeating: "a", count: 50000), inputTokenBudget: 4000)
    }
    #expect(await provider.requests.count == count)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting").path))
    #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).aiInputTokenBudget == 24000)
}
