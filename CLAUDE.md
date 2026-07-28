# CLAUDE.md — Pépito

> Assistant de réunion natif macOS, boosté à l'IA générative : enregistre, transcrit,
> structure et suit les plans d'action.

Ce fichier oriente Claude Code (et les humains) sur l'intention du projet, la stack, les
contraintes et les conventions. Il fait autorité : en cas de doute, s'y référer avant de coder.

---

## 1. Vision produit

Pépito est une application **macOS native** qui se comporte comme un super-assistant de réunion :

1. **Capture** — S'active en un geste (menu bar / raccourci global) pour enregistrer
   simultanément le **micro** (s'il est actif) et la **sortie audio système** (l'autre partie de
   la visio).
2. **Transcription** — Génère un transcript en temps réel / post-réunion via
   **Apple SpeechAnalyzer / SpeechTranscriber** (on-device, natif).
3. **Intelligence** — Une fois le transcript terminé, un traitement **agentic** piloté par un
   prompt configurable appelle une **IA générative OpenAI-compatible** pour : résumer, extraire
   les décisions, produire et **hiérarchiser des plans d'action**, et ranger tout ça dans une
   arborescence documentaire locale.
4. **Suivi** — L'app aide au suivi des plans d'action dans le temps (statuts, échéances,
   relances, liens entre réunions).
5. **Plus tard** — Un composant **API + UI Cloud** synchronisera et centralisera ces informations
   (multi-appareils, partage d'équipe).

Principe directeur : **local-first**. Tout fonctionne hors-ligne sur la machine de l'utilisateur ;
le Cloud est une extension optionnelle, jamais un prérequis. L'audio brut ne quitte jamais la
machine sans action explicite.

---

## 2. Stack technique

### Langage & UI
- **Swift 6 + SwiftUI** en langage principal. Raison assumée : les briques cœur du produit
  (SpeechAnalyzer, capture audio système, Foundation Models, UI menu-bar native) sont
  **exclusivement accessibles depuis l'écosystème Apple**. Un cœur en Rust n'apporterait que des
  ponts FFI fragiles pour un bénéfice nul à ce stade.
- **AppKit** ponctuellement pour ce que SwiftUI ne couvre pas proprement (item de menu bar,
  raccourcis globaux, fenêtres accessoires).
- **Rust : réservé au futur backend Cloud** (§8) et à un éventuel moteur de sync headless
  partagé. Pas de Rust dans l'app macOS v1.

### Cible OS
- **macOS 26 (Tahoe) minimum** — imposé par SpeechAnalyzer / SpeechTranscriber.
- Apple Silicon requis (les modèles de transcription/summarization on-device l'exigent).

### Frameworks Apple clés
- **Speech** → `SpeechAnalyzer`, `SpeechTranscriber` (transcription on-device, live + fichier).
- **AVFoundation / Core Audio** → capture micro, mixage, gestion des périphériques.
- **Core Audio taps (macOS 14.4+) / ScreenCaptureKit** → capture de la **sortie audio système**
  (audio des autres participants). Choisir Core Audio process taps en priorité (plus léger,
  pas de capture d'écran) ; ScreenCaptureKit en repli.
- **Foundation Models (optionnel)** → IA générative on-device Apple, en alternative au endpoint
  OpenAI-compatible pour les traitements légers/privés.
- **SwiftData** (ou GRDB/SQLite) → persistance des métadonnées, réunions, plans d'action.
- **App Sandbox + Hardened Runtime + notarization** → distribution.

### IA générative
- Client **OpenAI-compatible** (Chat Completions + éventuellement Responses/Tools) :
  endpoint + token configurables. Fonctionne avec OpenAI, Azure OpenAI, Ollama, vLLM, LM Studio,
  OpenRouter, etc.
- Boucle **agentic** : le modèle peut appeler des outils exposés par l'app (créer un plan
  d'action, écrire un fichier dans l'arborescence, taguer, lier à une réunion antérieure…).

---

## 3. Architecture (modules)

```
Pepito.app
├─ CaptureKit        Capture audio (micro + sortie système), mixage, VU-mètre, fichiers
├─ TranscriptionKit  Wrapper SpeechAnalyzer/SpeechTranscriber, segmentation, diarisation légère
├─ AIKit             Client OpenAI-compatible, boucle agentic, registre d'outils, prompts
├─ VaultKit          Arborescence documentaire locale (Markdown + front-matter), indexation
├─ ActionKit         Modèle de plans d'action, hiérarchie, statuts, échéances, suivi
├─ MailKit           Triage boîte mail : extraction Mail.app, digest compact, rendu de la revue
├─ AppCore           Modèles de domaine, persistance (SwiftData), coordination, état
├─ AdminUI           Écran d'administration (réglages IA, dossier, prompt agentic)
├─ AppUI             Menu bar, fenêtre principale, timeline réunions, éditeur de transcript
└─ CloudSync (futur) Client de synchro vers l'API Cloud
```

Règle de dépendances : `AppUI`/`AdminUI` → `AppCore` → (`CaptureKit`, `TranscriptionKit`,
`AIKit`, `VaultKit`, `ActionKit`, `MailKit`). Les Kits ne dépendent pas de l'UI. Chaque Kit est un module
Swift Package local testable isolément.

---

## 4. Modèle de données (domaine)

- **Meeting** — id, titre, date début/fin, participants (best-effort), source(s) audio,
  chemin transcript, statut (recording / transcribing / processing / done), tags.
- **TranscriptSegment** — meetingId, t0/t1, speaker (best-effort), texte, confiance.
- **ActionItem** — id, meetingId d'origine, titre, description, **parentId** (hiérarchie),
  responsable, échéance, statut (todo / in-progress / blocked / done / dropped), priorité,
  liens vers segments/transcript sources, historique de suivi.
- **VaultDocument** — chemin relatif dans l'arborescence, type (meeting-note / summary /
  action-plan / index), front-matter YAML, contenu Markdown.
- **Settings** — endpoint IA, token (Keychain), modèle, dossier Vault, prompt agentic, options
  de capture, langue de transcription.

Format de stockage : **Markdown + front-matter YAML** dans le dossier Vault choisi par
l'utilisateur (portable, versionnable avec git, lisible sans l'app). Les métadonnées/index vivent
en base (SwiftData/SQLite) et sont **reconstructibles** à partir du Vault (le Vault est la source
de vérité du contenu).

---

## 5. Interface d'administration (exigence explicite)

L'écran d'admin doit permettre de configurer **au minimum** :

1. **IA générative OpenAI-compatible** — URL d'endpoint + token d'auth (stocké en **Keychain**,
   jamais en clair), sélection du modèle, bouton « Tester la connexion ».
2. **Dossier de stockage** — le répertoire racine de la hiérarchie documentaire (Vault), avec
   accès sécurisé via security-scoped bookmark.
3. **Prompt agentic** — le prompt système qui définit le comportement de l'IA **une fois le
   transcript terminé** (résumé, extraction d'actions, hiérarchisation, rangement). Éditeur
   multi-ligne, versionné, avec valeur par défaut fournie et variables interpolables
   (ex. `{{transcript}}`, `{{date}}`, `{{participants}}`, `{{vault_tree}}`).

Réglages secondaires : options de capture (quelles sources), langue de transcription, on-device
vs endpoint distant, raccourci global.

---

## 6. Parcours utilisateur clé

1. L'utilisateur clique l'icône menu bar (ou raccourci global) → **enregistrement démarre**
   (micro actif + sortie système), VU-mètre visible.
2. Fin de réunion → stop. L'audio est transcrit via SpeechAnalyzer (live pendant, finalisé après).
3. **Pipeline agentic** se déclenche : le prompt configuré + le transcript sont envoyés à l'IA,
   qui produit résumé, décisions et **plans d'action hiérarchisés**, et écrit/range les documents
   dans le Vault via les outils exposés.
4. L'utilisateur relit dans la fenêtre principale, ajuste les actions, assigne échéances.
5. Au fil du temps, Pépito **relance sur le suivi** des actions ouvertes.

---

## 7. Contraintes & principes

- **Local-first & privacy** : aucun envoi réseau sans configuration explicite. Afficher clairement
  quand des données partent vers l'endpoint IA (surtout si distant). Prévoir un mode 100 %
  on-device (SpeechAnalyzer + Foundation Models).
- **Consentement d'enregistrement** : rappeler à l'utilisateur ses obligations légales
  (enregistrer une réunion peut requérir le consentement des participants selon les juridictions).
- **Permissions** : micro (`NSMicrophoneUsageDescription`), capture système (TCC), Speech.
  Gérer proprement les refus et les états dégradés.
- **Résilience** : ne jamais perdre un enregistrement. Écriture incrémentale sur disque, reprise
  après crash, transcription re-lançable depuis l'audio conservé.
- **Testabilité** : logique métier (hiérarchisation, parsing d'actions, boucle agentic) découplée
  des frameworks Apple derrière des protocoles, pour tests unitaires sans matériel audio.
- **Coût/latence IA** : batching, streaming des réponses, troncature intelligente des longs
  transcripts (chunking + map-reduce de résumé).

---

## 8. Composant Cloud (futur — hors v1)

- **API** (candidate : **Rust** — Axum/Actix — pour perf et partage de logique) exposant
  réunions, transcripts, plans d'action ; **UI web** de consultation/suivi d'équipe.
- Sync depuis l'app macOS via `CloudSync`. Chiffrement en transit + au repos. Auth utilisateur.
- Modèle de sync : le Vault local reste source de vérité ; le Cloud est un miroir/agrégateur
  multi-appareils et multi-utilisateurs. Résolution de conflits à définir (CRDT ou last-write-wins
  par document).

---

## 9. Conventions de code

- Swift 6, concurrence stricte (`async/await`, acteurs pour l'état partagé — capture, sessions IA).
- Un **Swift Package local par Kit** (§3) ; l'app cible ne fait qu'assembler.
- Pas de secrets en dur ni en `UserDefaults` : **Keychain** pour le token IA.
- Logs via `os.Logger` (sous-systèmes par Kit). Pas de PII/transcript dans les logs par défaut.
- Erreurs typées par domaine ; jamais de `try!` sur un chemin utilisateur.
- Style : suivre le code environnant ; documenter les API publiques des Kits.

---

## 10. Commandes (à maintenir au fil du build)

```bash
swift build              # build de tous les modules + app
swift test               # tests unitaires (swift-testing) de tous les Kits
./build-app.sh           # assemble .build/Pepito.app (bundle requis pour fenêtres/réglages/TCC)
open .build/Pepito.app   # lance l'app menu-bar
./profile.py [secondes]  # profile l'app EN COURS D'EXÉCUTION (défaut 10 s) : points chauds + flamegraph
./profile.py <fichier.txt>  # réanalyse un brut déjà capturé, sans réechantillonner
```

Important : lancer le **bundle** `.app` (via `build-app.sh`), pas le binaire SPM nu
(`.build/debug/Pepito`) — sans bundle Info.plist, la gestion des fenêtres, l'activation, les
Réglages et les permissions macOS (TCC) ne fonctionnent pas correctement.

### Profilage CPU (`./profile.py`)

Enveloppe `sample(1)` — pas Instruments, dont le `.trace` est illisible en ligne de commande.
L'app doit tourner ; le script trouve le PID seul. Sorties dans `.build/` (gitignoré) : le `.svg`
(flamegraph, ouvrir dans un navigateur) et le `.txt` brut. **Le classement imprimé sur stdout suffit
à décider** — pas besoin d'ouvrir le SVG.

**Profiler un build `release`**, sinon on mesure le coût du mode debug, pas celui de l'app :

```bash
./build-app.sh release && open .build/Pepito.app && ./profile.py
```

`build-app.sh` construit en **debug par défaut**. En debug les génériques ne sont pas spécialisés
et le retain/release n'est pas élidé : le profil se remplit de `_swift_getGenericMetadata`,
`swift_getAssociatedTypeWitness`, `IndexingIterator.next()`, `Collection.formIndex(after:)` — du
bruit de configuration qui disparaît en release. Si ces symboles dominent le self time, arrêter
d'optimiser et rebuild en release avant toute autre conclusion.

Comment le lire :
- **`% CPU instantané`** en tête : le seul chiffre qui compte pour un avant/après.
- **Colonnes `actif` / `total`** : `sample` échantillonne *tous* les threads, endormis compris.
  `total` ne mesure donc rien ; `actif` exclut les symboles de blocage connus (liste `BLOCKED`,
  à compléter si un thread manifestement idle remonte en tête). Le flamegraph ne couvre que le
  thread le plus actif.
- **« Self time (feuilles) »** : où le CPU part vraiment — c'est la table à lire en premier.
- **« Inclusif, code Pepito »** : typiquement < 1 %. Dans une app SwiftUI, le coût est presque
  toujours dans le framework, sur les données qu'on lui donne — chercher *quelle vue* alimente le
  symbole système chaud, pas une boucle à optimiser dans le code Swift.

Précédent utile (juillet 2026) : 100 % CPU au repos, dont ~80 % en encodage de glyphes CoreText
(`TASCIIEncoder::Encode`) — un `Text` unique contenant tout le transcript live d'une réunion de 3 h,
re-mesuré et re-typographié à chaque frame. Corrigé en plafonnant le texte **affiché**
(`MeetingCoordinator.liveDisplaySegmentCap`) et en retirant l'animation du scroll auto. Réflexe :
dans cette app, un pic CPU vient d'abord d'une vue qui grossit sans borne, pas d'un algorithme.

Prérequis : macOS 26+, Xcode 26+, Apple Silicon. Layout : monorepo SwiftPM, un module par Kit
sous `Sources/`, tests sous `Tests/`, app exécutable `Sources/Pepito`.

---

## 11. État & feuille de route (résumé)

- **Statut actuel** : Phases 0 → 7 implémentées + triage mail natif (87 tests verts, `swift build`/`swift test` OK,
  l'app se lance). Logique testée : Vault, client IA OpenAI-compatible (requête/réponse/SSE/chunking),
  boucle agentic + outils + `MeetingPipeline`, hiérarchie & suivi des actions, réglages/Keychain,
  `MeetingStore`, et l'orchestration end-to-end `MeetingCoordinator` (capture→transcription→analyse).
  **Réel mais compile-vérifié seulement** (nécessite audio/appareil pour l'exécution) : capture micro
  (AVAudioEngine) + sortie système (**Core Audio process taps** primaires, repli ScreenCaptureKit
  automatique) et transcription **SpeechAnalyzer réelle** —
  API validées contre le SDK 26. UI SwiftUI complète (timeline, détail réunion, dashboard de suivi,
  admin). Reste : validation matérielle des taps, résultats live, permissions TCC, éditions UI avancées,
  durcissement/distribution (Phase 8), Cloud (Phase 9).
- **v1 (local-first)** : capture double-source → transcript SpeechAnalyzer → pipeline agentic →
  Vault Markdown + plans d'action hiérarchisés → admin (IA/dossier/prompt) → suivi basique.
- **v2** : suivi avancé (relances, dashboards), diarisation, recherche sémantique du Vault.
- **v3** : composant Cloud (API Rust + UI web) et sync multi-appareils.

Le plan d'implémentation détaillé et phasé est tenu à jour dans `PLAN.md`.
