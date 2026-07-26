import Testing
import Foundation
import VaultKit
import MailKit
@testable import AppCore

private func mail(id: String, subject: String, sender: String = "a@b.c") -> MailMessage {
    MailMessage(
        id: id, url: "message://%3C\(id)%3E", subject: subject, sender: sender, to: "moi@x.fr",
        cc: "", date: .init(timeIntervalSince1970: 1_000), mailbox: "Boîte",
        isRead: false, flagged: false, attachments: 0, body: "corps")
}

private let fetched = MailFetchResult(
    generatedAt: .init(timeIntervalSince1970: 1_000), days: 7, messageCount: 3,
    threads: [
        MailThread(subject: "Renouvellement Splunk", messages: [mail(id: "m1@x", subject: "Renouvellement Splunk")]),
        MailThread(subject: "Facture 042", messages: [mail(id: "m2@x", subject: "Facture 042")]),
        MailThread(subject: "Newsletter", messages: [mail(id: "m3@x", subject: "Newsletter")]),
    ])

private let triageJSON = #"""
{"period":"semaine du 20 au 26 juillet 2026","date":"2026-07-26","items":[
  {"id":1,"bucket":"immediate","importance":"Haute","action":"Répondre","deadline":"2026-07-28",
   "why":"Relance avec deadline ferme.","summary":"Rémi relance sur le renouvellement.",
   "todo":"Répondre dispo lundi/mardi — Splunk"},
  {"id":2,"bucket":"week","importance":"Normale","action":"Lire","summary":"Facture reçue."},
  {"id":3,"bucket":"info","importance":"Faible","action":"Archiver","summary":"Newsletter."}]}
"""#

@Test func mailPipelineWritesReportAndBuildsActions() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pepito-mail-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let vault = Vault(root: tmp)
    let pipeline = MailPipeline(provider: PipelineScriptedProvider([triageJSON]), vault: vault)

    let today = try #require(MeetingPipeline.parseDate("2026-07-26"))
    let result = try await pipeline.process(result: fetched, today: today)

    // Revue écrite dans le Vault, sous mails/revue-<date>.md.
    #expect(result.reportPath == "mails/revue-2026-07-26.md")
    let report = try vault.read(relativePath: result.reportPath, type: .summary)
    #expect(report.markdown.contains("🔴 Action immédiate"))
    #expect(report.markdown.contains("Renouvellement Splunk"))

    // Seules les actions Répondre/Décider/Suivre deviennent des plans d'action.
    #expect(result.actions.count == 1)
    let action = try #require(result.actions.first)
    #expect(action.title == "Répondre dispo lundi/mardi — Splunk")
    #expect(action.priority == .high)
    #expect(action.meetingID == nil)                       // action de mail : pas de réunion d'origine
    #expect(action.sourceURL == "message://%3Cm1@x%3E")
    #expect(action.dueDate == MeetingPipeline.parseDate("2026-07-28"))
    #expect(result.ignoredIDs.isEmpty)

    // Historique : toutes les conversations sont figées, et #1 pointe l'action créée.
    #expect(result.entries.count == fetched.threads.count)
    #expect(result.entries.first?.reviewDate == "2026-07-26")
    #expect(result.entries.first?.actionID == action.id)
    #expect(result.entries.first?.bucket == .immediate)
    #expect(result.entries.last?.bucket == .info)              // #3 classée « info », donc pas archivée
}

@Test func mailActionIDsAreStableAcrossRuns() {
    // Retrier la même période ne doit pas dupliquer les actions : l'id dérive du Message-ID.
    let thread = MailThread(subject: "Facture 042", messages: [mail(id: "m2@x", subject: "Facture 042")])
    #expect(MailPipeline.actionID(for: thread) == MailPipeline.actionID(for: thread))
    #expect(MailPipeline.actionID(for: thread) != MailPipeline.actionID(for: fetched.threads[0]))

    // Message-ID absent : repli sur le sujet, toujours déterministe.
    let noID = MailThread(subject: "Sans id", messages: [mail(id: "", subject: "Sans id")])
    #expect(MailPipeline.actionID(for: noID) == MailPipeline.actionID(for: noID))
}
