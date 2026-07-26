import Testing
import Foundation
@testable import MailKit

// Tests portés des self-tests du pipeline d'origine (mail-fetch.swift / mail-render.py).
// Aucun n'accède à Mail.app : tout est pur (normalisation, décodage MIME, digest, rendu).

@Test func moduleIdentity() {
    #expect(MailKit.moduleName == "MailKit")
}

// MARK: - Normalisation des sujets

@Test func normalizeSubjectStripsReplyPrefixes() {
    #expect(MailFetcher.normalizeSubject("Re: Re: Devis") == "Devis")
    #expect(MailFetcher.normalizeSubject("TR: RE : Projet IA") == "Projet IA")
    #expect(MailFetcher.normalizeSubject("Fwd: Planning") == "Planning")
    #expect(MailFetcher.normalizeSubject("Facture") == "Facture")
    #expect(MailFetcher.normalizeSubject("  Rép : question  ") == "question")
    #expect(MailFetcher.normalizeSubject("Retour client") == "Retour client")   // « Re » n'est pas un préfixe ici
}

// MARK: - Décodage MIME

@Test func decodesMultipartAlternativePreferringPlainText() {
    let raw = "Content-Type: multipart/alternative; boundary=\"XY\"\r\n\r\n"
        + "--XY\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nBonjour =C3=A9t=C3=A9\r\n"
        + "--XY\r\nContent-Type: text/html\r\n\r\n<p>ignore</p>\r\n--XY--\r\n"
    #expect(MailFetcher.decodeMIME(raw) == "Bonjour été")
}

@Test func decodesHTMLEntitiesAndTags() {
    let raw = "Content-Type: text/html\r\nContent-Transfer-Encoding: 7bit\r\n\r\n<b>Salut</b>&nbsp;&amp; <i>merci</i>"
    #expect(MailFetcher.decodeMIME(raw) == "Salut & merci")
}

@Test func decodesBase64AndStripsHead() {
    let b64 = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\nQ2FmZQ==\r\n"
    #expect(MailFetcher.decodeMIME(b64) == "Cafe")
    let head = "Content-Type: text/html\r\n\r\n<html><head><title>Newsletter</title></head><body>Vrai texte</body></html>"
    #expect(MailFetcher.decodeMIME(head) == "Vrai texte")
}

@Test func decodesTruncatedBase64Body() {
    // `source` est tronquée par sourceCap : on doit récupérer le début, pas perdre tout le corps.
    let full = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        + Data("Bonjour, ceci est un message tronqué en plein milieu été".utf8).base64EncodedString()
    #expect(MailFetcher.decodeMIME(String(full.prefix(full.count - 7))).hasPrefix("Bonjour, ceci est un"))
}

@Test func decodesNestedMultipartWithEmptyPlainPart() {
    // Outlook envoie un text/plain vide à côté du vrai HTML : le corps ne doit pas disparaître.
    let raw = "Content-Type: multipart/mixed; boundary=\"M\"\r\n\r\n--M\r\n"
        + "Content-Type: multipart/alternative; boundary=\"A\"\r\n\r\n--A\r\n"
        + "Content-Type: text/plain\r\n\r\n\r\n--A\r\n"
        + "Content-Type: text/html; charset=\"utf-8\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        + Data("<p>Quarantaine</p>".utf8).base64EncodedString() + "\r\n--A--\r\n--M--\r\n"
    #expect(MailFetcher.decodeMIME(raw) == "Quarantaine")
}

// MARK: - Regroupement

@Test func groupsThreadsByNormalizedSubjectMostRecentFirst() {
    let old = message(id: "1", subject: "Devis", date: .init(timeIntervalSince1970: 100))
    let reply = message(id: "2", subject: "Re: Devis", date: .init(timeIntervalSince1970: 200))
    let other = message(id: "3", subject: "Facture", date: .init(timeIntervalSince1970: 300))
    let threads = MailFetcher.group([old, reply, other])

    #expect(threads.map(\.subject) == ["Facture", "Devis"])       // conversation la plus récente en tête
    #expect(threads[1].messages.map(\.id) == ["1", "2"])          // messages du plus ancien au plus récent
    #expect(threads[1].last.id == "2")
}

// MARK: - Digest

@Test func digestNumbersThreadsInOrder() {
    let result = MailFetchResult(
        generatedAt: .init(timeIntervalSince1970: 0), days: 7, messageCount: 2,
        threads: MailFetcher.group([
            message(id: "1", subject: "Devis", date: .init(timeIntervalSince1970: 300), flagged: true),
            message(id: "2", subject: "Facture", date: .init(timeIntervalSince1970: 100), body: "un  corps\ncoupé"),
        ]))
    let digest = MailDigest.text(result)

    #expect(digest.contains("# 2 messages, 2 conversations"))
    #expect(digest.contains("#1 ⚑"))                       // flag propagé, index dans l'ordre des threads
    #expect(digest.contains("   sujet: Devis"))
    #expect(digest.contains("#2  "))
    #expect(digest.contains("« un corps coupé »"))          // espaces normalisés dans l'aperçu
    #expect(digest.contains("dest 1"))                      // un seul destinataire
}

@Test func digestTruncatesPreview() {
    let long = String(repeating: "a", count: 500)
    let result = MailFetchResult(
        generatedAt: .init(timeIntervalSince1970: 0), days: 1, messageCount: 1,
        threads: MailFetcher.group([message(id: "1", subject: "Long", date: .now, body: long)]))
    #expect(MailDigest.text(result).contains("« \(String(repeating: "a", count: 300)) »"))
}

// MARK: - Rendu de la revue

@Test func reportSortsByDeadlineAndGroupsArchive() {
    let rendered = MailReport.render(result: sampleResult, triage: MailTriage(items: [
        .init(id: 2, bucket: .immediate, importance: "Haute", action: "Répondre", deadline: "2026-08-01"),
        .init(id: 1, bucket: .immediate, importance: "Critique", action: "Décider", deadline: "2026-07-28"),
        .init(id: 9, bucket: .week),                              // hors limites → ignoré
        .init(id: 3, bucket: .week, action: "Lire"),
    ]), today: .init(timeIntervalSince1970: 0))
    let md = rendered.markdown

    #expect(md.range(of: "Devis")!.lowerBound < md.range(of: "Facture")!.lowerBound)  // tri par échéance
    #expect(md.contains("Rémi Dupont") && md.contains("no@z.io"))   // nom affiché, sinon adresse
    #expect(md.contains("⚑"))                                       // flag propagé
    #expect(md.contains("## ⚪ Peut être archivé (1)"))              // seul #4 non classé
    #expect(rendered.ignoredIDs == [9])
}

@Test func reportTodoKeepsOnlyActionableItemsSortedByDeadline() {
    let rendered = MailReport.render(result: sampleResult, triage: MailTriage(items: [
        .init(id: 2, bucket: .immediate, importance: "Haute", action: "Répondre", deadline: "2026-08-01"),
        .init(id: 1, bucket: .immediate, importance: "Critique", action: "Décider", deadline: "2026-07-28"),
        .init(id: 3, bucket: .week, action: "Lire"),
    ]), today: .init(timeIntervalSince1970: 0))
    let todo = rendered.markdown.components(separatedBy: "## ✅").last ?? ""

    #expect(todo.range(of: "Décider : Devis")!.lowerBound < todo.range(of: "Répondre : Facture")!.lowerBound)
    #expect(!todo.contains("Lire"))                                 // « Lire » n'entre pas dans la todo
    #expect(todo.contains("(échéance 2026-07-28)"))
}

@Test func unknownBucketFallsBackToWeekInsteadOfVanishing() {
    // Un bucket inconnu ne doit faire disparaître l'item ni du rapport ni de l'archive.
    let json = #"{"items":[{"id":3,"bucket":"n_importe_quoi","action":"Lire","summary":"s"}]}"#
    let triage = try! JSONDecoder().decode(MailTriage.self, from: Data(json.utf8))
    #expect(triage.items[0].bucket == .week)

    let md = MailReport.render(result: sampleResult, triage: triage).markdown
    #expect(md.contains("Newsletter"))
    #expect(!md.contains("n_importe_quoi"))
}

@Test func triageDecodingToleratesMissingFields() {
    let json = #"{"period":"semaine","items":[{"id":1,"bucket":"info"},{"bucket":"info"}]}"#
    let triage = try! JSONDecoder().decode(MailTriage.self, from: Data(json.utf8))
    #expect(triage.date.isEmpty && triage.items.count == 2)
    #expect(triage.items[0].summary.isEmpty)
    #expect(triage.items[1].id == -1)                               // id manquant → item ignoré au rendu
    #expect(MailReport.render(result: sampleResult, triage: triage).ignoredIDs == [-1])
}

// MARK: - Revue figée (historique)

@Test func reviewEntriesCoverJudgedAndArchivedThreads() {
    let actionID = UUID()
    let entries = MailReview.entries(
        result: sampleResult,
        triage: MailTriage(items: [
            .init(id: 1, bucket: .immediate, importance: "Critique", action: "Décider",
                  deadline: "2026-07-28", why: "pourquoi", summary: "résumé", todo: "Décider vite"),
            .init(id: 42, bucket: .week),                       // hors limites → ignoré
        ]),
        date: "2026-07-26",
        actionIDs: [1: actionID])

    #expect(entries.count == sampleResult.threads.count)        // toutes les conversations, classées ou non
    #expect(entries.map(\.index) == [1, 2, 3, 4])               // index du digest préservés

    let judged = entries[0]
    #expect(judged.bucket == .immediate)
    #expect(judged.sender == "Rémi Dupont")                     // nom résolu, pas l'adresse brute
    #expect(judged.deadline == "2026-07-28")
    #expect(judged.actionID == actionID)
    #expect(judged.id == "2026-07-26#1")

    let archived = entries[1]
    #expect(archived.bucket == nil)                             // non classée → archivable
    #expect(archived.actionID == nil)
    #expect(archived.flagged)                                   // métadonnées conservées quand même
    #expect(archived.messageCount == 2)
}

@Test func archiveGroupsCountBySenderMostFrequentFirst() {
    // Trois relances du même expéditeur + une conversation isolée ; seule #1 est classée.
    let result = MailFetchResult(
        generatedAt: .now, days: 7, messageCount: 4,
        threads: (1...4).map { i in
            MailThread(subject: "Sujet \(i)", messages: [
                message(id: "\(i)", subject: "Sujet \(i)", date: .now,
                        sender: i == 1 ? "Client <c@x.fr>" : "\"Datadog\" <no@datadoghq.com>")])
        })
    let groups = MailReview.archiveGroups(MailReview.entries(
        result: result, triage: MailTriage(items: [.init(id: 1, bucket: .immediate)]), date: "2026-07-26"))

    #expect(groups.map(\.sender) == ["Datadog"])                // regroupé par nom affiché
    #expect(groups.map(\.count) == [3])                         // la classée (#1) n'est pas archivée
}

@Test func settledEntriesJoinTheArchive() {
    // #1 classée « immédiate » mais traitée (l'UI passe le prédicat), #2 non classée.
    let result = MailFetchResult(
        generatedAt: .now, days: 7, messageCount: 2,
        threads: (1...2).map { i in
            MailThread(subject: "Sujet \(i)", messages: [
                message(id: "\(i)", subject: "Sujet \(i)", date: .now, sender: "Client \(i) <c\(i)@x.fr>")])
        })
    let entries = MailReview.entries(
        result: result, triage: MailTriage(items: [.init(id: 1, bucket: .immediate)]), date: "2026-07-26")

    let groups = MailReview.archiveGroups(entries) { $0.bucket == nil || $0.index == 1 }
    #expect(groups.map(\.sender) == ["Client 1", "Client 2"])
    #expect(groups.map(\.count) == [1, 1])
}

@Test func senderNameFallsBackToAddress() {
    #expect(MailReport.senderName("\"Rémi Dupont\" <r@x.fr>") == "Rémi Dupont")
    #expect(MailReport.senderName("<compta@y.com>") == "compta@y.com")
    #expect(MailReport.senderName("no@z.io") == "no@z.io")
    #expect(MailReport.senderName("") == "(inconnu)")
}

// MARK: - Fixtures

private func message(
    id: String, subject: String, date: Date, sender: String = "a@b.c",
    to: String = "moi@x.fr", flagged: Bool = false, body: String = ""
) -> MailMessage {
    MailMessage(
        id: id, url: "message://\(id)", subject: subject, sender: sender, to: to, cc: "",
        date: date, mailbox: "Boîte", isRead: false, flagged: flagged, attachments: 0, body: body)
}

/// 4 conversations : #1 Devis, #2 Facture (2 mails, flaggée), #3 Newsletter, #4 Promo.
private let sampleResult = MailFetchResult(
    generatedAt: .init(timeIntervalSince1970: 0), days: 7, messageCount: 5,
    threads: [
        MailThread(subject: "Devis", messages: [
            message(id: "1", subject: "Devis", date: .now, sender: "\"Rémi Dupont\" <r@x.fr>")]),
        MailThread(subject: "Facture", messages: [
            message(id: "2", subject: "Facture", date: .now, sender: "compta@y.com", flagged: true),
            message(id: "2b", subject: "Re: Facture", date: .now, sender: "compta@y.com")]),
        MailThread(subject: "Newsletter", messages: [
            message(id: "3", subject: "Newsletter", date: .now, sender: "no@z.io")]),
        MailThread(subject: "Promo", messages: [
            message(id: "4", subject: "Promo", date: .now, sender: "News <no@z.io>")]),
    ])
