# PLAN.md — Plan d'implémentation de Pépito

Plan phasé, exhaustif et enrichi. Chaque phase liste un objectif, des tâches, et un critère de
« fait ». Les fonctionnalités marquées 💡 sont des enrichissements proposés au-delà du cahier des
charges initial.

---

## Phase 0 — Amorçage & fondations (semaine 1) — ✅ TERMINÉE

**Objectif** : squelette buildable, décisions techniques verrouillées.

- [x] Workspace SwiftPM + app SwiftUI (`Pepito`), cible **macOS 26**, Apple Silicon.
- [x] Modules par Kit : `CaptureKit`, `TranscriptionKit`, `AIKit`, `VaultKit`, `ActionKit`,
      `AppCore` (avec protocoles/modèles amorces mockables).
- [x] `os.Logger` par sous-système (`Log`), sans PII.
- [x] `swift build` + `swift test` verts (15 tests swift-testing, 1+ par Kit).
- [x] Menu bar (start/stop enregistrement) + fenêtre principale + écran Réglages placeholder.
- [x] 💡 Feature flags (on-device vs cloud, sources de capture) centralisés (`FeatureFlags`).
- [ ] Reste à faire (déféré au moment de la distribution) : signing, Hardened Runtime,
      App Sandbox, entitlements, config SwiftLint/format, CI.

**Fait quand** : ~~l'app se lance, apparaît en menu bar, tous les Kits compilent et testent.~~ ✅

---

## Phase 1 — Capture audio double-source (semaines 2-3) — 🟢 IMPLÉMENTÉE (compile-vérifiée)

**Objectif** : enregistrer micro + sortie système de façon fiable.

> Fait : `MicrophoneRecorder` réel (AVAudioEngine → CAF), `CoreAudioTapSystemAudioRecorder` réel
> (**Core Audio process taps** — capture de la sortie système SANS permission d'enregistrement
> d'écran ; tap ciblé par app ou global + périphérique agrégé privé dont la sortie par défaut
> fournit l'horloge + IOProc) **primaire**, repli **ScreenCaptureKit automatique** (erreur au
> démarrage ou watchdog 3 s sans buffers — la panne « un seul buffer » venait de l'agrégat sans
> sous-périphérique d'horloge), `CaptureController` **tolérant** (chaque source indépendante,
> micro-seul si la sortie système n'est pas autorisée), seam `AudioCapturing` injectable.
> Machine à états + session testées ; capture réelle **compile contre le SDK 26**, à valider sur
> matériel (TCC, audio live). Reste : écriture incrémentale résiliente, écriture disque hors
> thread temps-réel.

- [ ] `CaptureKit` : session micro via AVAudioEngine, choix du périphérique, VU-mètre.
- [x] Capture **sortie système** via **Core Audio process taps** (macOS 14.4+) ; repli
      ScreenCaptureKit si indisponible.
- [ ] Détection « micro actif » (n'enregistrer le micro que s'il capte réellement).
- [ ] Mixage/enregistrement des deux flux : fichiers séparés + timeline commune (pour diarisation
      grossière ultérieure : « moi » vs « eux »).
- [ ] Écriture incrémentale sur disque (résilience crash), format PCM/CAF puis conversion.
- [ ] Gestion des permissions (micro TCC, capture système) avec états de refus propres.
- [ ] Contrôles : start/stop/pause, indicateur d'enregistrement global.
- 💡 Auto-détection de début de réunion (app de visio au premier plan : Zoom/Meet/Teams) →
      proposition d'enregistrer.
- 💡 Raccourci clavier global pour start/stop.

**Fait quand** : un enregistrement produit deux pistes horodatées récupérables après un kill -9.

---

## Phase 2 — Transcription SpeechAnalyzer (semaines 3-4) — 🟢 IMPLÉMENTÉE (compile-vérifiée)

**Objectif** : transcript live + finalisé, on-device.

> Fait : `SpeechAnalyzerTranscriber` **réel** (SpeechAnalyzer + SpeechTranscriber, lecture fichier,
> conversion de format, collecte des segments avec fenêtre temporelle, installation du modèle de
> langue via `AssetInventory`, matching de locale tolérant + logs) — **compile contre le SDK 26**,
> non exécutable ici (nécessite audio + modèle installé). **Diarisation par source câblée** : les
> deux flux (micro=« Moi », sortie=« Interlocuteurs ») sont transcrits indépendamment puis fusionnés
> par timestamp (`transcribeSources` + `TranscriptFormatter`), testé via mock. **Transcript live
> câblé** : `SpeechAnalyzerLiveTranscriber` (streaming + résultats volatils) alimenté par les buffers
> micro (tap unique qui écrit ET streame), état live observable dans le coordinateur, fenêtre
> « Transcript en direct » ouvrable au menu (fermée par défaut), testé via `MockLiveTranscriber`.
> **Live bi-source** : micro (« Moi ») ET sortie système (« Interlocuteurs ») transcrits en direct
> chacun via son `SpeechAnalyzerLiveTranscriber`, buffers du tap Core Audio forwardés, affichage
> labellisé — testé. **Live = source de vérité** : les segments finalisés du live (avec timing)
> forment le transcript final — **plus de double transcription** ; repli fichier via l'API fiable
> `start(inputAudioFile:)` seulement si le live n'a rien produit. Fix du `nilError` de
> `start(inputSequence:)` : conversion au format exact de l'analyseur, `bufferStartTime` monotone,
> buffers ≥ 16k frames. Tout reste sur SpeechAnalyzer/SpeechTranscriber. Reste : ring buffer audio
> (au lieu de fichiers complets), UX téléchargement modèle, diarisation intra-flux.

- [ ] `TranscriptionKit` : wrapper `SpeechAnalyzer` + `SpeechTranscriber` derrière un protocole
      `Transcriber` (mockable).
- [ ] Téléchargement/gestion des modèles de langue on-device (état, taille, langue).
- [ ] Transcription **live** pendant la réunion (résultats partiels affichés).
- [ ] Finalisation post-réunion depuis les fichiers audio conservés (re-lançable).
- [ ] Segmentation en `TranscriptSegment` (t0/t1, confiance, source micro/système).
- [ ] Diarisation légère basée sur la source (moi vs interlocuteurs) ; labels éditables.
- [ ] Sélection de langue + fallback si modèle absent.
- 💡 Correction/édition manuelle des segments dans l'UI.
- 💡 Détection de silences/chapitrage automatique.

**Fait quand** : un enregistrement donne un transcript segmenté, éditable, avec sources.

---

## Phase 3 — Persistance, Vault & modèle de domaine (semaine 5) — 🟢 LOGIQUE FAITE

**Objectif** : stockage local structuré et portable.

> Fait : modèles `Meeting`/`TranscriptSegment`/`ActionItem`/`VaultDocument`/`Settings` ;
> `Vault` (écritures atomiques, listing, `treeOutline`), `FrontMatter` (round-trip),
> `PathBuilder` (slug + convention `AAAA/MM/JJ-slug`) — tous testés. Reste : security-scoped
> bookmark, index base reconstructible, migrations, compatibilité git.

- [ ] `AppCore` : modèles `Meeting`, `TranscriptSegment`, `ActionItem`, `VaultDocument`,
      `Settings` ; persistance SwiftData (ou GRDB).
- [ ] `VaultKit` : arborescence Markdown + front-matter YAML dans le dossier choisi ;
      security-scoped bookmark ; lecture/écriture/rename atomiques.
- [ ] Convention d'arborescence par défaut (ex. `/AAAA/MM/réunion-slug/…`) + index générés.
- [ ] Reconstruction de l'index base ↔ Vault (Vault = source de vérité contenu).
- [ ] Migration de schéma versionnée.
- 💡 Compatibilité git (le Vault peut être un repo) et détection de modifs externes.

**Fait quand** : une réunion + son transcript sont écrits dans le Vault et rechargés à froid.

---

## Phase 4 — Intégration IA OpenAI-compatible (semaine 6) — 🟢 LOGIQUE FAITE

**Objectif** : client IA robuste et configurable.

> Fait : `OpenAIRequestBuilder` (auth/path/body — testé), `OpenAIResponseParser` (testé),
> `OpenAICompatibleProvider` (URLSession), `SSEParser` (streaming — testé), `TokenEstimator` +
> `TranscriptChunker` (budget/hard-split — testés). Reste : streaming réel branché à l'UI,
> retries/timeouts, provider Foundation Models on-device, cache/coût.

- [ ] `AIKit` : client Chat Completions OpenAI-compatible (endpoint + token), streaming SSE.
- [ ] Token en **Keychain** ; « Tester la connexion » ; gestion des erreurs/timeouts/retries.
- [ ] Abstraction provider (OpenAI, Azure, Ollama, vLLM, OpenRouter, LM Studio).
- [ ] Comptage de tokens + chunking / map-reduce pour longs transcripts.
- [ ] ⏸️ Backend on-device via **Foundation Models** — **reporté à macOS 27** (2026-07-29).
      Aujourd'hui `SystemLanguageModel.contextSize` vaut **4096 tokens** (entrée + sortie) : après
      le prompt système et le JSON attendu, il reste 4 à 7 min de transcript par appel, soit ~10
      passes de condensation pour une réunion d'une heure, produites par un modèle de 3 Md.
      macOS 27 apporte `PrivateCloudComputeLanguageModel` à **32 000 tokens** sans clé d'API :
      la même réunion passe en **une seule fois**. Tout se branche derrière l'unique fabrique
      `AppCore.makeProvider(settings:token:)` ; `TokenEstimator`/`TranscriptChunker` sont prêts
      si un fold reste nécessaire.
- [ ] 💡 Cache des réponses + estimation de coût affichée.

**Fait quand** : un prompt libre + transcript renvoie une réponse streamée depuis l'endpoint réglé.

---

## Phase 5 — Analyse du transcript (semaines 7-8) — 🟢 FAIT

**Objectif** : le cœur « super-assistant ».

> **Décision** : abandon du tool-calling agentic (fragile — protocole `role:"tool"` rejeté en 500
> par les gateways litellm→Gemini). Remplacé par une **analyse en une seule passe** : le modèle
> renvoie un JSON structuré (résumé + actions hiérarchisées + tags), et l'app écrit le Vault et crée
> les `ActionItem` de façon **déterministe** (`MeetingPipeline`). Tolérant au texte/fences autour du
> JSON. Testé (parsing, hiérarchie parent/enfant, écriture Vault, prose autour du JSON). Supprimé :
> `AgenticSession`, `ToolExecuting`, `VaultToolExecutor`, `JSONValue`. Reste : presets de prompts,
> prévisualisation accept/reject avant écriture.

- [ ] `AIKit` : boucle agentic (tool-calling) avec registre d'outils exposés par l'app :
      - `create_action_item(parentId?, …)` — créer/hiérarchiser un plan d'action ;
      - `write_vault_document(path, frontmatter, markdown)` — ranger dans l'arborescence ;
      - `link_to_previous_meeting(query)` — relier à une réunion antérieure ;
      - `tag_meeting(tags)`, `set_summary(...)`.
- [ ] Prompt système agentic configurable (§ admin) avec variables interpolées
      (`{{transcript}}`, `{{date}}`, `{{participants}}`, `{{vault_tree}}`).
- [ ] Orchestration post-transcript : résumé → décisions → **plans d'action hiérarchisés** →
      rangement Vault, le tout via outils, avec garde-fous (validation des chemins, dry-run).
- [ ] Journalisation des étapes agentic (traçabilité, rejouable).
- 💡 Prévisualisation « proposé par l'IA » avec accept/reject par item avant écriture.
- 💡 Bibliothèque de prompts / presets par type de réunion.

**Fait quand** : à la fin d'un transcript, l'IA produit et range automatiquement un plan d'action
hiérarchisé validable par l'utilisateur.

---

## Phase 6 — Interface d'administration (semaine 9) — 🟢 FONCTIONNELLE

**Objectif** : exigence explicite du cahier des charges.

> Fait : `SettingsStore` (JSON persistant — testé), `TokenStore` Keychain + `InMemoryTokenStore`
> (testé), `AdminView` SwiftUI (endpoint/modèle/token/test connexion, sélecteur de dossier Vault,
> éditeur de prompt agentic avec variables, toggles de capture). Reste : security-scoped bookmark,
> versionnage du prompt, bannière de confidentialité, raccourci global.

- [ ] Réglages IA : endpoint, token (Keychain), modèle, test connexion.
- [ ] Sélecteur du dossier Vault (bookmark) + validation d'accès.
- [ ] Éditeur du **prompt agentic** : multi-ligne, variables, valeur par défaut, versionnage,
      restauration.
- [ ] Réglages capture (sources, langue, on-device vs distant), raccourci global.
- [ ] Bannière de confidentialité quand un endpoint distant est utilisé.

**Fait quand** : tout le comportement IA/stockage se pilote sans toucher au code.

---

## Phase 7 — UI principale & suivi des actions (semaines 10-11) — 🟢 IMPLÉMENTÉE

**Objectif** : consultation, édition, suivi.

> Fait : `ActionHierarchy` + `ActionTracking` (testés). UI SwiftUI complète : `MainView`
> (NavigationSplitView timeline des réunions), `MeetingDetailView` (statut, participants, actions),
> `DashboardView` (actions ouvertes + en retard, transverses), badges de statut, `MenuBarContent`
> (démarrer/arrêter câblé au coordinateur). `MeetingStore` (index JSON persistant). Orchestration
> end-to-end `MeetingCoordinator` testée. Reste : édition inline, drag-and-drop de hiérarchie,
> notifications de relance, recherche plein-texte/sémantique.

- [ ] `ActionKit` : logique de hiérarchie, statuts, échéances, priorités, historique.
- [ ] Timeline des réunions + vue détail (transcript synchronisé, résumé, actions).
- [ ] Vue « Plans d'action » transverse : arborescence, filtres (statut/échéance/responsable).
- [ ] Édition inline des actions, drag-and-drop de hiérarchisation.
- [ ] **Suivi** : relances des actions ouvertes (notifications), échéances à venir.
- 💡 Recherche plein-texte + 💡 recherche sémantique du Vault (embeddings via l'endpoint IA).
- 💡 Dashboard : actions ouvertes, en retard, par personne.
- 💡 Export (Markdown/PDF), 💡 « chat with your meeting » (Q/R sur un transcript).

**Fait quand** : on parcourt ses réunions, suit ses actions, et Pépito relance sur l'ouvert.

---

## Phase 7 bis — Structuration des tâches — 🟢 IMPLÉMENTÉE

**Objectif** : rendre le suivi actionnable — savoir d'un coup d'œil ce que je porte, ce que je
relance, et ce qui n'est là que pour information, projet par projet.

> Fait : entité **`Project`** (table dédiée, actif/clos, couleur, référent, gérée dans les
> Réglages) ; `ActionItem.projectID` + **`involvement`** (own / follow / info) *nullable = déduit*
> de `owner` via `Settings.userName` / `teamMembers` ; `DashboardView` en trois sections
> d'implication sous-groupées par projet, retards dédoublonnés, filtre projet ; `ActionRow` montre
> projet, `details` et **réunion d'origine cliquable** ; hiérarchie enfin rendue
> (`ActionHierarchy.flattened`) ; **création manuelle** d'action (suivi, fiche réunion, barre de
> menu) ; projet choisi **dès le démarrage** de la réunion (rapproché du titre calendrier) +
> tags en direct ; **pré-brief scoré** (projet > responsable > participants, pénalité « pour
> info ») ; le pipeline classe les actions dans les projets existants et remplace « moi » par le
> vrai nom ; réunions **récurrentes repliables** dans la barre latérale (`Meeting.seriesKey`).
> Migration vérifiée sur base réelle (64 actions, 5 réunions préservées).

- [x] `Project` + `Involvement`, migrations additives, `resolvedInvolvement`.
- [x] Suivi par implication × projet, retards non répétés, contexte sur chaque ligne.
- [x] Saisie manuelle d'action + éditeur enrichi (projet, implication, détail).
- [x] Projet & tags dès le démarrage ; pré-brief ciblé ; héritage du projet par les actions.
- [x] Regroupement des réunions récurrentes (titre normalisé).
- [ ] Relances/notifications sur les actions « À suivre » — à faire une fois la classification
      éprouvée à l'usage.
- [ ] Fusion/renommage en masse de projets ; `series_key` explicite issue d'`EKEvent`.

**Fait quand** : ~~le suivi distingue ce que je porte de ce que je relance, projet par projet.~~ ✅

---

## Phase 8 — Durcissement & distribution (semaine 12)

**Objectif** : app livrable.

- [ ] Tests d'intégration bout-en-bout (capture mock → transcript mock → agentic → Vault).
- [ ] Gestion mémoire/longues réunions, profils de perf, fuites.
- [ ] Accessibilité (VoiceOver, contrastes), localisation FR/EN.
- [ ] Notarization, mises à jour (Sparkle ou App Store), crash reporting respectueux de la privacy.
- [ ] Documentation utilisateur + onboarding (permissions, consentement, premier setup).

**Fait quand** : build notarisé installable, onboarding complet, tests verts.

---

## Phase 9 — Cloud (v3, ultérieur)

**Objectif** : centralisation et partage d'équipe.

- [ ] API **Rust** (Axum) : réunions, transcripts, plans d'action ; auth utilisateur.
- [ ] UI web de consultation/suivi.
- [ ] `CloudSync` dans l'app : sync Vault ↔ Cloud, chiffrement transit+repos, résolution de
      conflits (CRDT ou last-write-wins par document).
- [ ] Partage d'équipe, permissions, multi-appareils.

---

## Risques & points de vigilance

| Risque | Mitigation |
|---|---|
| Capture sortie système restreinte par TCC | Core Audio process taps (aucune permission d'écran, contrairement à ScreenCaptureKit) ; tester tôt sur matériel réel |
| SpeechAnalyzer = macOS 26 only (base installée faible) | Assumé ; pas de repli SFSpeechRecognizer en v1 (qualité inférieure) — à réévaluer |
| Transcripts longs → coût/latence IA | Chunking + map-reduce, streaming, mode on-device |
| Fuite de données via endpoint distant | Bannière claire, mode 100 % on-device, Keychain, opt-in explicite |
| Aspects légaux de l'enregistrement | Avertissement de consentement à l'onboarding |
| Perte d'enregistrement | Écriture incrémentale, reprise après crash, audio toujours conservé |

## Ordonnancement critique

Chemin critique : **Phase 1 (capture)** et **Phase 2 (transcription)** d'abord — ce sont les
briques à plus haut risque technique (dépendantes du matériel et d'API récentes). Les valider tôt
sur machine réelle conditionne tout le reste. Phases 4-5 (IA agentic) sont la valeur produit ;
Phases 3/6/7 peuvent avancer en parallèle une fois le domaine posé.
