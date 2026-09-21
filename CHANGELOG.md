# Changelog

Toutes les versions de Pépito sont documentées ici. Chaque version a deux sections :
**Fonctionnel** (ce que l'utilisateur voit) et **Technique** (architecture, migrations, perf).
Format inspiré de [Keep a Changelog](https://keepachangelog.com/) ; le projet est pré-1.0, où
une version MINOR peut apporter une rupture (schéma SQLite, format du Vault).

## [Unreleased]

## [0.6.0] - 2026-09-21

### Fonctionnel

- **Missions persistantes** — confier une tâche à l’IA, importer ses fichiers, suivre les appels
  d’outils et reprendre la conversation après fermeture. Les accès aux données de Pépito et les
  changements métier restent soumis aux autorisations de la mission et aux validations prévues.
- **Livrables intégrés** — consulter les documents, fichiers et sources dans le panneau de la
  mission, avec aperçu Markdown, HTML autonome et Quick Look, puis exporter les résultats.
- **Scripts et navigateur** — exécuter Python, JavaScript ou shell dans le dossier de travail
  de la mission ; autoriser explicitement Internet. Le navigateur intégré propose une session
  indépendante et une prise en main manuelle.
- **Consignes de synthèse dictées** — dicter les instructions qui guideront l’analyse d’une
  réunion, en complément des notes.
- **Fiabilité des réunions** — sauvegardes et reprises plus robustes ; retraiter une réunion
  préserve les modifications manuelles des actions et évite leur duplication.

### Technique

- Ajout d’AgentKit et SandboxKit, protocole Pi avec reprise de session, journaux d’appels
  persistants et contrôles de conflit avant application des changements métier.
- Scripts macOS isolés par Seatbelt, environnement minimal, scratchpad persistant par mission,
  limites de durée et de sortie, arrêt des groupes de processus et réseau soumis à autorisation.
- Navigateur WebKit éphémère ; runtime Node 24.21.0 embarqué, archive vérifiée par SHA-256 et
  dépendances npm verrouillées, installées sans scripts. Aucune VM Linux à télécharger.
- Transactions SQLite et tests de régression sur les échecs de sauvegarde, suppressions et
  retraitements ; conservation des statuts et de l’implication modifiés manuellement.
- Ajustements du traitement audio et du budget de transcript transmis à l’IA ; persistance
  des consignes de synthèse.
- Les chemins autorisés par Seatbelt sont résolus pour prendre en charge les installations
  Xcode accessibles par un lien symbolique, notamment sur les runners GitHub.
- Validation locale : 141 tests Swift et 9 tests du runtime, dont l’isolation native, la
  persistance du scratchpad, les permissions réseau, l’annulation et les limites d’exécution.

### Limites connues

- Application signée ad-hoc et non notarisée : au premier lancement, utiliser **clic droit ›
  Ouvrir**. La reconstruction peut imposer de réaccorder les permissions macOS.
- L’isolation des scripts repose sur Seatbelt, mécanisme macOS déprécié, et partage le noyau
  de l’hôte. Les bibliothèques Python tierces ne sont pas embarquées.
- Les sous-ressources du navigateur utilisent le réseau WebKit ; une autorisation Internet
  pour un script lui donne aussi accès au réseau local pendant cet appel.
- Capture audio, permissions TCC, transcription réelle, Mail et migration d’une base existante
  nécessitent la QA manuelle décrite dans `Packaging/QA-CHECKLIST.md`.

## [0.5.0] - 2026-08-21

Première version distribuée. Le produit couvre la boucle complète : capturer une réunion, la
transcrire, en extraire des actions, et les suivre dans le temps — plus le triage de la boîte mail.

### Fonctionnel

- **Enregistrement et transcription** — capture simultanée du micro et de la sortie audio système
  (taps Core Audio, repli ScreenCaptureKit), transcription on-device via SpeechAnalyzer, en direct
  pendant la réunion puis finalisée à l'arrêt.
- **Analyse IA** — à la fin de la réunion, résumé, décisions et plan d'action hiérarchisé, rangés
  en Markdown dans le Vault. L'IA *complète* vos notes au lieu de les régénérer.
- **Calendrier** — l'événement en cours pré-remplit titre, participants et contexte dès le
  démarrage de l'enregistrement.
- **Projets** — les actions et les réunions se rattachent à un projet (actif/clos, couleur,
  référent). Le projet est choisi au démarrage, rapproché du titre de l'événement calendrier.
- **Implication** — chaque action est classée *à faire soi-même* / *à suivre* / *pour info*,
  déduite du responsable via votre nom et votre équipe (Réglages). Corriger l'équipe reclasse tout
  l'historique ; une correction manuelle, elle, ne se fait jamais écraser.
- **Suivi** — tableau de bord organisé par implication puis par projet, sous-tâches indentées,
  retards signalés une seule fois, création manuelle d'action, export vers Rappels (et Things).
- **Pré-brief** — au démarrage d'une réunion récurrente, les actions restées ouvertes aux
  occurrences précédentes remontent en tête ; l'IA peut les clore d'elle-même en fin de réunion.
- **Triage mail** — revue de la boîte Mail.app sur une période choisie (jour ou intervalle), en
  lecture seule : conversations classées par urgence, actions extraites dans le même backlog que
  les réunions. Re-trier ne duplique rien et préserve vos statuts.
- **Résumé éditable** — double-clic sur le corps d'un résumé pour l'éditer ; le Vault reste la
  source de vérité.
- **Administration** — endpoint IA OpenAI-compatible (token en Keychain), dossier Vault, prompts
  agentic et mail, projets, équipe, options de capture.

### Technique

- **Modules** : `CaptureKit`, `TranscriptionKit`, `AIKit`, `VaultKit`, `ActionKit`, `MailKit`,
  `AppCore`, app SwiftUI. 111 tests (swift-testing), `swift build` et `swift test` sans warning.
- **Persistance** : SQLite, migrations additives et idempotentes (`PRAGMA table_info` +
  `ALTER TABLE`), sans numéro de version. Tables `action`, `mail_item`, `project` ; colonnes
  `participants`, `user_notes`, `source_url`, `project_id`, `involvement`. Migration vérifiée sur
  base réelle : 64 actions et 5 réunions préservées.
- **Ce qu'un humain a édité survit au pipeline** : `status` et `involvement` sont exclus du
  `DO UPDATE` des upserts. `involvement` nullable = déduit, d'où un reclassement de l'historique
  sans backfill.
- **Identité des revues mail** : `MailPeriod` (jours calendaires inclusifs) remplace `days: Int`.
  Sa clé (`2026-07-27` ou `2026-07-21_2026-07-27`) sert de clé SQLite, de nom de document Vault et
  de sélection dans la barre latérale — `review_date` change de sens sans changer de forme, donc
  sans migration.
- **Consignes du modèle en Swift, pas dans le prompt** : contrat JSON, liste des projets et
  identité de l'utilisateur sont concaténés autour du prompt utilisateur — `defaultAgenticPrompt`
  est figé dans le `settings.json` des installations existantes et ne peut rien propager.
- **Perf** : ~100 % → 26 % de CPU pendant une longue réunion. Transcript live plafonné et rendu en
  `LazyVStack` (une `Text` par tour) au lieu d'une `Text` unique re-typographiée à chaque frame,
  scroll auto désanimé, FFT du spectrogramme coupée quand rien ne l'affiche, spectrogramme
  composité en un seul `CGImage`. Outil de mesure : `./profile.py`.
- **Correctif de perte de données** : l'AEC hors-ligne écrivait un fichier vide en signalant un
  succès quand le micro était illisible, et la transcription enchaînait sur du silence. `writeMono16k`
  lève désormais au lieu d'écrire, et le repli s'active.
- **Robustesse IA** : une réponse à `content` null ne remonte plus en `DecodingError` opaque.
- **Séries de réunions** : clé de série par titre normalisé ; un titre auto (« Réunion du 21 août
  2026 ») ne forme plus de série. Le pré-brief est scoré (série +20 > projet > responsable >
  participants) au lieu d'un filtre binaire.
- **Confidentialité** : seul le digest mail (métadonnées + 300 caractères d'aperçu par
  conversation) atteint l'endpoint IA, jamais le corps des messages ; aucun contenu de mail dans
  les logs. Pépito ne modifie, ne classe ni n'envoie aucun mail.

### Reporté

- **Recherche sémantique du Vault (RAG)** — attend la base vectorielle native de macOS 27, pour
  éviter un index d'embeddings maison jetable.
- **IA générative on-device (Foundation Models)** — 4096 tokens de contexte sur macOS 26, soit 4 à
  7 minutes de transcript par appel ; `PrivateCloudComputeLanguageModel` passe à 32 000 tokens sur
  macOS 27.
- **Écriture dans Mail** — brouillons de réponse, drapeaux, archivage et triage automatique restent
  hors périmètre.

### Limites connues

- **Non notarisée** : pas de compte Apple Developer, donc DMG signé ad-hoc et avertissement
  Gatekeeper au premier lancement (voir les instructions d'installation de la release).
- Les chemins matériels (taps Core Audio, TCC, SpeechAnalyzer, Mail, Calendrier, Rappels) ne sont
  pas couverts par la CI : ils passent par la checklist QA manuelle (`Packaging/QA-CHECKLIST.md`).
- L'envoi d'Apple Events à Mail exige une entitlement d'exception temporaire refusée par le Mac App
  Store — sans effet sur une distribution Developer ID notarisée. À trancher en phase 8.
