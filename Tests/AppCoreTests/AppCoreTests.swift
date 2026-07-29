import Testing
import Foundation
import AVFoundation
import CaptureKit
import ActionKit
@testable import AppCore

@Test func linkedKitsAreAllPresent() {
    let kits = AppCore.linkedKits()
    #expect(kits.count == 5)
    #expect(Set(kits) == ["CaptureKit", "TranscriptionKit", "AIKit", "VaultKit", "ActionKit"])
}

@Test func defaultFeatureFlags() {
    let flags = FeatureFlags.default
    #expect(flags.captureMicrophone)
    #expect(flags.captureSystemAudio)
    #expect(flags.useOnDeviceAI == false)
    #expect(flags.reviewAIProposalsBeforeWrite)
}

// MARK: - Prompt template

@Test func promptRenderingInterpolates() {
    let rendered = PromptTemplate.render(
        "Date: {{date}} / Participants: {{participants}} / Arbre: {{vault_tree}}",
        context: PromptContext(transcript: "T", date: "2026-07-15", participants: "Alice, Bob", vaultTree: "a.md")
    )
    #expect(rendered == "Date: 2026-07-15 / Participants: Alice, Bob / Arbre: a.md")
}

@Test func promptRenderingInterpolatesContextVars() {
    let rendered = PromptTemplate.render(
        "Ctx: {{context}} | Notes: {{user_notes}} | Ouvertes: {{open_actions}}",
        context: PromptContext(
            transcript: "T", date: "d", participants: "p", vaultTree: "",
            context: "Agenda: budget", userNotes: "- point clé", openActions: "abc: Envoyer")
    )
    #expect(rendered == "Ctx: Agenda: budget | Notes: - point clé | Ouvertes: abc: Envoyer")
}

// MARK: - Settings persistence

@Test func settingsRoundTripOnDisk() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = SettingsStore(fileURL: tmp)
    #expect(store.load() == .default) // absent → défaut

    var settings = Settings.default
    settings.vaultPath = "/Users/me/Vault"
    settings.aiModel = "gpt-4o-mini"
    try store.save(settings)

    #expect(store.load() == settings)
    #expect(settings.isConfigured)
}

// MARK: - Persistance des plans d'action (Phase A)

@Test func actionsPersistAcrossReopen() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pepito-actions-\(UUID().uuidString)")
    let dbPath = dir.appending(path: "pepito.db")
    defer { try? FileManager.default.removeItem(at: dir) }

    let meetingID = UUID()
    let parent = ActionItem(meetingID: meetingID, title: "Préparer le budget", owner: "Alice",
                            dueDate: Date(timeIntervalSince1970: 1_800_000_000), priority: .high)
    let child = ActionItem(parentID: parent.id, meetingID: meetingID, title: "Chiffrer les postes")

    do {
        let db = Database(path: dbPath)
        db.save(Meeting(id: meetingID, title: "Sync", folderPath: "f")) // FK: la réunion existe avant ses actions
        db.saveActions([parent, child])
        db.updateStatus(child.id, .done)
    }

    // Réouverture : la base doit rendre les actions et le statut modifié.
    let db = Database(path: dbPath)
    let all = db.loadAllActions()
    #expect(all.count == 2)
    let reloadedParent = all.first { $0.id == parent.id }
    #expect(reloadedParent?.owner == "Alice")
    #expect(reloadedParent?.priority == .high)
    #expect(reloadedParent?.dueDate == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(all.first { $0.id == child.id }?.parentID == parent.id)

    // updateStatus persiste ; allOpenActions exclut la terminée.
    #expect(db.loadAllActions().first { $0.id == child.id }?.status == .done)
    #expect(db.allOpenActions().map(\.id) == [parent.id])

    // Action issue d'un mail : pas de réunion d'origine, mais un lien ouvrable persisté. Réenregistrer
    // la même action (retriage) ne duplique pas la ligne et préserve le statut suivi manuellement.
    let mailAction = ActionItem(title: "Répondre — Splunk", sourceURL: "message://%3Cm1@x%3E")
    db.saveActions([mailAction])
    db.updateStatus(mailAction.id, .done)
    db.saveActions([mailAction])
    let reloadedMail = db.loadAllActions().filter { $0.id == mailAction.id }
    #expect(reloadedMail.count == 1)
    #expect(reloadedMail.first?.sourceURL == "message://%3Cm1@x%3E")
    #expect(reloadedMail.first?.meetingID == nil)
    #expect(reloadedMail.first?.status == .done)

    // Supprimer la réunion efface ses actions par cascade FK (pas les actions de mail).
    db.delete(meetingID)
    #expect(db.loadAll().isEmpty)
    #expect(db.loadAllActions().map(\.id) == [mailAction.id])
}

// MARK: - Historique des revues de mails

@Test func mailReviewsPersistAndReplaceOnRetriage() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pepito-mailrev-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = Database(path: dir.appending(path: "pepito.db"))

    func entry(_ date: String, _ idx: Int, bucket: MailBucket?, flagged: Bool = false,
               actionID: UUID? = nil, messages: Int = 1) -> MailReviewEntry {
        MailReviewEntry(
            reviewDate: date, index: idx, subject: "Sujet \(idx)", sender: "exp\(idx)@x.fr",
            url: "message://%3Cm\(idx)%3E", messageCount: messages, unread: 1, flagged: flagged,
            bucket: bucket, importance: "Haute", action: "Répondre", deadline: "2026-07-28",
            why: "pourquoi", summary: "résumé", actionID: actionID)
    }

    let actionID = UUID()
    db.saveMailReview([
        entry("2026-07-26", 1, bucket: .immediate, flagged: true, actionID: actionID, messages: 3),
        entry("2026-07-26", 2, bucket: nil),                    // non classée → archivable
    ])
    db.saveMailReview([entry("2026-07-19", 1, bucket: .week)])

    let reloaded = db.mailReview(date: "2026-07-26")
    #expect(reloaded.count == 2)
    #expect(reloaded[0].bucket == .immediate)
    #expect(reloaded[0].actionID == actionID)
    #expect(reloaded[0].url == "message://%3Cm1%3E")
    #expect(reloaded[1].bucket == nil)                          // NULL relu comme « archivable »

    // Historique : plus récent en tête, compteurs agrégés.
    let history = db.mailReviews()
    #expect(history.map(\.date) == ["2026-07-26", "2026-07-19"])
    #expect(history[0].threadCount == 2)
    #expect(history[0].messageCount == 4)
    #expect(history[0].immediateCount == 1)
    #expect(history[0].flaggedCount == 1)
    #expect(history[0].actionCount == 1)

    // Action traitée → la conversation sort du compteur « à traiter » de la pastille.
    db.saveActions([ActionItem(id: actionID, title: "Répondre", status: .done)])
    db.updateStatus(actionID, .done)                            // saveActions préserve le statut
    #expect(db.mailReviews()[0].immediateCount == 0)
    #expect(db.mailReviews()[0].threadCount == 2)               // la revue, elle, garde ses conversations

    // Retrier le même jour remplace la revue au lieu de l'empiler.
    db.saveMailReview([entry("2026-07-26", 1, bucket: .week)])
    #expect(db.mailReview(date: "2026-07-26").count == 1)
    #expect(db.mailReviews().count == 2)

    db.deleteMailReview(date: "2026-07-26")
    #expect(db.mailReviews().map(\.date) == ["2026-07-19"])
}

// MARK: - Export externe (Phase E)

@Test func thingsURLEncodesTitleAndNotes() {
    let url = ActionExport.thingsURL(title: "Envoyer la proposition", notes: "avant vendredi")
    let s = try! #require(url).absoluteString
    #expect(s.hasPrefix("things:///add"))
    #expect(s.contains("title=Envoyer%20la%20proposition"))
    #expect(s.contains("notes=avant%20vendredi"))
}

// MARK: - Token store

@Test func inMemoryTokenStore() throws {
    let store = InMemoryTokenStore()
    #expect(try store.token(for: "default") == nil)
    try store.setToken("sk-secret", for: "default")
    #expect(try store.token(for: "default") == "sk-secret")
    try store.setToken(nil, for: "default")
    #expect(try store.token(for: "default") == nil)
}

// MARK: - Analyse spectrale (visualisation live FFT)

@Test func spectrumMeterPeaksAtToneFrequency() {
    let meter = SpectrumMeter()
    let sr = 16000.0, freq = 2000.0
    let n = SpectrumMeter.fftSize
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    let p = buf.floatChannelData![0]
    for i in 0..<n { p[i] = Float(sin(2 * .pi * freq * Double(i) / sr)) }

    meter.push(buf, source: .microphone)
    let spec = meter.sample().mic

    // La bande dominante doit correspondre à 2 kHz ; les autres sources restent muettes.
    let peak = spec.enumerated().max { $0.element < $1.element }!.offset
    let expected = Int(freq * Double(n) / sr) * SpectrumMeter.bands / (n / 2)
    #expect(abs(peak - expected) <= 1)
    #expect(spec[peak] > 0.3)
    #expect(meter.sample().system.allSatisfy { $0 == 0 })
}

// MARK: - Filtre du bleed micro

@Test func bleedFilterRemovesMicDuplicatesOfSystem() {
    // Micro : ma phrase (unique) + un doublon de la sortie système (bleed HP).
    let mic = [
        TranscriptSegment(start: 0, end: 2, text: "Je suis d'accord avec toi"),
        TranscriptSegment(start: 3, end: 5, text: "Bonjour comment ça va"),   // bleed
    ]
    let system = [
        TranscriptSegment(start: 3, end: 5, text: "bonjour, comment ça va ?"), // source propre
    ]
    let clean = BleedFilter.micWithoutBleed(mic: mic, system: system)
    #expect(clean.map(\.text) == ["Je suis d'accord avec toi"])

    // Rien de commun avec le système → aucun retrait.
    let unrelated = [TranscriptSegment(start: 3, end: 5, text: "sujet totalement différent")]
    #expect(BleedFilter.micWithoutBleed(mic: mic, system: unrelated).count == 2)

    // Même texte mais hors de la fenêtre temporelle → conservé (pas un doublon simultané).
    let late = [TranscriptSegment(start: 30, end: 32, text: "bonjour comment ça va")]
    #expect(BleedFilter.micWithoutBleed(mic: mic, system: late).count == 2)
}

// MARK: - AEC hors-ligne (NLMS)

@Test func echoCancellerReducesReferenceEcho() {
    let n = 32000, half = 16000, delay = 60
    // Référence large bande (pseudo-aléatoire déterministe) = audio système.
    var state: UInt32 = 12345
    var x = [Float](repeating: 0, count: n)
    for i in 0..<n {
        state = state &* 1664525 &+ 1013904223
        x[i] = Float(state) / Float(UInt32.max) * 2 - 1
    }
    // 1ʳᵉ moitié : écho seul (le filtre converge). 2ᵉ moitié : double-talk — ma voix (ton) s'ajoute ;
    // l'adaptation doit se figer (Geigel), l'écho rester annulé et ma voix survivre.
    var mic = [Float](repeating: 0, count: n)
    var nearEnd = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let s = i >= half ? 0.3 * Float(sin(2 * .pi * 200 * Double(i) / 16000)) : 0
        nearEnd[i] = s
        let echo = i >= delay ? 0.3 * x[i - delay] : 0
        mic[i] = s + echo
    }

    let out = EchoCanceller().cancel(mic: mic, reference: x, maxLag: 250)

    // Sur la moitié double-talk : ce qui dépasse de ma voix (résidu d'écho + distorsion NLMS) doit
    // être bien plus faible que l'écho brut → écho annulé ET voix intacte.
    var residual: Float = 0, rawEcho: Float = 0
    for i in half..<n {
        residual += (out[i] - nearEnd[i]) * (out[i] - nearEnd[i])   // ce qui reste au-delà de ma voix
        rawEcho += (mic[i] - nearEnd[i]) * (mic[i] - nearEnd[i])    // l'écho d'origine
    }
    #expect(residual < 0.2 * rawEcho)          // >7 dB de réduction d'écho
    #expect(EchoCanceller.estimateDelay(mic: mic, reference: x, maxLag: 250) == delay)
}

@Test func echoCancellerTracksClockDrift() {
    // Dérive d'horloge simulée : l'écho arrive 1 échantillon plus TÔT tous les 4000 (dérive cumulée
    // de 96 échantillons) — un alignement unique à t=0 finit non-causal et ne peut plus annuler.
    // Filtre et blocs raccourcis pour un test rapide (mêmes proportions qu'en production).
    let n = 384_000, drift = 4000
    var state: UInt32 = 98765
    var x = [Float](repeating: 0, count: n)
    for i in 0..<n {
        state = state &* 1664525 &+ 1013904223
        x[i] = Float(state) / Float(UInt32.max) * 2 - 1
    }
    var mic = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let d = 500 - i / drift
        if i >= d { mic[i] = 0.3 * x[i - d] }
    }

    var aec = EchoCanceller()
    aec.filterLength = 128
    aec.blockLength = 16_000
    aec.refineRadius = 64

    func lastBlockResidual(_ out: [Float]) -> Float {
        var e: Float = 0
        for i in (n - 16_000)..<n { e += out[i] * out[i] }
        return e
    }
    let echo = lastBlockResidual(mic)

    // Par blocs : le ré-alignement suit la dérive, l'écho reste annulé jusqu'au bout.
    #expect(lastBlockResidual(aec.cancel(mic: mic, reference: x, maxLag: 600)) < 0.2 * echo)

    // Contre-épreuve : en un seul bloc (alignement unique), la dérive fait échouer l'annulation.
    aec.blockLength = n
    #expect(lastBlockResidual(aec.cancel(mic: mic, reference: x, maxLag: 600)) > 0.5 * echo)
}

// MARK: - Projets et implication (migration incluse)

@Test func projectsAndInvolvementPersist() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pepito-projects-\(UUID().uuidString)")
    let dbPath = dir.appending(path: "pepito.db")
    defer { try? FileManager.default.removeItem(at: dir) }

    let project = Project(name: "Migration SI", color: "blue", owner: "Alice")
    let meetingID = UUID()
    let action = ActionItem(meetingID: meetingID, projectID: project.id, title: "Chiffrer les postes")

    do {
        let db = Database(path: dbPath)
        db.saveProject(project)
        db.save(Meeting(id: meetingID, title: "Sync", projectID: project.id, folderPath: "f"))
        db.saveActions([action])
        db.updateInvolvement(action.id, .follow)
    }

    let db = Database(path: dbPath)
    #expect(db.loadProjects().map(\.name) == ["Migration SI"])
    #expect(db.loadProjects().first?.color == "blue")
    #expect(db.loadAll().first?.projectID == project.id)
    let reloaded = db.loadAllActions().first
    #expect(reloaded?.projectID == project.id)
    #expect(reloaded?.involvement == .follow)

    // Re-traitement du pipeline : la surcharge d'implication survit, comme le statut.
    db.saveActions([action])
    #expect(db.loadAllActions().first?.involvement == .follow)

    // Supprimer un projet ne supprime pas ses actions : project_id repasse simplement à NULL.
    db.deleteProject(project.id)
    #expect(db.loadProjects().isEmpty)
    #expect(db.loadAllActions().count == 1)
    #expect(db.loadAllActions().first?.projectID == nil)
    #expect(db.loadAll().first?.projectID == nil)
}

@Test func migrationAddsColumnsToAPreExistingDatabase() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pepito-migrate-\(UUID().uuidString)")
    let dbPath = dir.appending(path: "pepito.db")
    defer { try? FileManager.default.removeItem(at: dir) }

    // Base à l'ancien schéma (sans project/involvement), telle qu'une install existante.
    let legacy = ActionItem(title: "Action héritée", owner: "Alice")
    let fixture = LegacyDatabaseFixture(path: dbPath)
    fixture.insertLegacyAction(id: legacy.id, title: legacy.title, owner: "Alice")
    fixture.close()

    // L'ouverture normale migre : l'action historique remonte, non classée et sans surcharge.
    let db = Database(path: dbPath)
    let all = db.loadAllActions()
    #expect(all.count == 1)
    #expect(all.first?.title == "Action héritée")
    #expect(all.first?.projectID == nil)
    #expect(all.first?.involvement == nil)
    // involvement nil ⇒ classée par déduction : Alice est dans mon équipe.
    #expect(all.first?.resolvedInvolvement(me: "Antoine", team: ["Alice"]) == .follow)
}

// MARK: - Regroupement des réunions récurrentes

@Test func seriesKeyGroupsOccurrencesOfTheSameMeeting() {
    // Casse, accents, ponctuation et numéro d'occurrence ne doivent pas séparer une série.
    #expect(Meeting.seriesKey("Weekly Produit") == Meeting.seriesKey("weekly  produit"))
    #expect(Meeting.seriesKey("Weekly Produit #12") == Meeting.seriesKey("Weekly Produit"))
    #expect(Meeting.seriesKey("Comité 2026-07-28") == Meeting.seriesKey("Comité"))
    #expect(Meeting.seriesKey("Réunion d'équipe") == "reunion d equipe")
    // Deux réunions différentes restent séparées.
    #expect(Meeting.seriesKey("Weekly Produit") != Meeting.seriesKey("Weekly Tech"))
}

@MainActor
@Test func meetingSeriesKeepsChronologicalOrder() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pepito-series-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = MeetingCoordinator(
        settingsStore: SettingsStore(fileURL: dir.appending(path: "settings.json")),
        database: Database(path: dir.appending(path: "pepito.db")),
        tokenStore: InMemoryTokenStore())

    func meeting(_ title: String, _ day: Int) -> Meeting {
        Meeting(title: title, startedAt: Date(timeIntervalSince1970: Double(day) * 86_400), folderPath: "f")
    }
    // Ordre de `Database.loadAll()` : started_at DESC.
    app.meetings = [
        meeting("Weekly Produit", 30),
        meeting("Point client Acme", 29),
        meeting("Weekly Produit #2", 23),
        meeting("weekly produit", 16),
    ]

    let series = app.meetingSeries
    #expect(series.map(\.isRecurring) == [true, false])
    // Un groupe se classe à son occurrence la plus récente, et son contenu reste antéchronologique.
    #expect(series[0].meetings.count == 3)
    #expect(series[0].title == "Weekly Produit")
    #expect(series[0].meetings.map(\.startedAt) == series[0].meetings.map(\.startedAt).sorted(by: >))
    #expect(series[1].meetings.map(\.title) == ["Point client Acme"])
}
