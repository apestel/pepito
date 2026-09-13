# Missions Pépito — première implémentation

Branche : `codex/pepito-agentic`. Pas de publication ni changement de version.

## Parcours

Ouvrir **Missions**, créer une mission, préciser le résultat attendu et joindre les fichiers
nécessaires. **Confier à Pépito** dans une réunion donne accès à cette réunion et à ses actions.
La case d’autorisation ajoute les réunions, actions, revues de mails déjà enregistrées et le
calendrier. Sans cette autorisation, aucune recherche globale n’est possible.

La conversation montre les réponses et les opérations. Le panneau droit conserve les sources
et les livrables. Les changements de statut, téléchargements et interactions navigateur sont
présentés avant application ; les décisions sont journalisées. Un changement concurrent de
l’action invalide la proposition. Un livrable peut être révélé dans le Finder ou exporté.

**Arrêter** interrompt l’agent et les VM. Une nouvelle instruction reprend la conversation.
Après interruption, les opérations en cours sont signalées comme incertaines ; leurs
identifiants ne sont pas rejoués. Les appels terminés ont un reçu persistant.

## Assemblage

- `AgentKit` : processus local et protocole JSONL ; `Runtime/bridge.mjs` : SDK Pi 0.85.1.
- `SandboxKit` : Apple Containerization 0.45.0, Virtualization.framework.
- AppCore : autorisations, journal de mission, lecture métier, conflits, réseau du navigateur.
- SwiftUI : espace Missions, validation et aperçu interactif du navigateur.
- Configuration IA existante : endpoint, modèle, budget et token Keychain. Le test dans
  Réglages effectue un vrai appel d’outil ; aucune substitution de fournisseur.

`./build-app.sh release` prépare Node 24.21.0 et le noyau Kata 3.32.0, vérifie les archives SHA-256,
installe le verrou npm avec scripts d’installation désactivés, assemble et signe le bundle.
Python 3.11+ et npm sont nécessaires à la construction, pas à l’usage de l’app.
`Package.resolved` et `Runtime/package-lock.json` verrouillent les dépendances.

Le premier build télécharge environ 714 Mo d’archives. Le premier usage des scripts ou du
navigateur télécharge une image Playwright Linux et l’init Apple (environ 1,4 Go de contenu
compressé par cache). Chaque VM a 2 CPU, 2 Go de mémoire maximum et un disque de 8 Go.
Les caches scripts et navigateur sont distincts. Le bundle release mesure environ 654 Mo.

## Frontières d’exécution

Les scripts Python, Node et shell s’exécutent uniquement dans Linux. Aucun NIC, partage
virtiofs, Vault, dossier personnel, profil de navigateur ou token IA n’est monté dans leur VM.
Les fichiers importés sont copiés ; les exports refusent les chemins absolus, traversées et
liens symboliques. Les fichiers importés sont limités à 32 Mo, les livrables à 1 Mo et la sortie
d’une commande à 4 Mo. Une commande dispose de 60 secondes ; un dépassement arrête sa VM.

Le navigateur utilise une autre VM sans NIC. Playwright relaie les requêtes au contrôleur
HTTP hôte : domaines explicitement ouverts, DNS résolu et épinglé, réseaux privés refusés,
réponses limitées à 8 Mo. Les redirections repassent par ce contrôle. WebSockets et service
workers sont bloqués. Les requêtes autres que GET/HEAD exigent la prise de contrôle humaine.
Les scripts ne disposent pas de ce canal. `download_file` passe par le même contrôleur, avec
validation du nom et de l’URL ; il n’utilise aucun cookie de navigateur ni secret IA.

Pi reçoit uniquement les outils Pépito déclarés. Aucun outil shell ou fichier de Pi n’est
exposé sur l’hôte ; les extensions, skills, contextes et plugins personnels sont désactivés.
Le token est fourni au processus Pi par son entrée standard et n’est pas enregistré dans sa
configuration. Les erreurs d’authentification sont présentées sans réponse brute du proxy.

Les missions et sessions sont stockées à côté de `settings.json`, dans `missions/<UUID>`.
Les contenus sélectionnés sont envoyés au seul endpoint configuré. Les scripts et le
navigateur ont des environnements temporaires, détruits à la fin de chaque tour ; seuls les
fichiers explicitement exportés et les imports restent disponibles sur le Mac.

## Vérifications reproductibles

```sh
swift test
npm test --prefix Runtime
./build-app.sh release
codesign --force --sign - --entitlements Packaging/Agent.entitlements .build/release/PepitoAgentProbe
.build/release/PepitoAgentProbe .build/agent-assets/vmlinux .build/agent-smoke
.build/release/PepitoAgentProbe --browser-test .build/agent-assets/vmlinux .build/agent-smoke .build/Pepito.app/Contents/Resources/AgentRuntime
.build/release/PepitoAgentProbe --endpoint-test .build/Pepito.app/Contents/Resources/AgentRuntime
```

Le diagnostic endpoint lit le token configuré mais ne transmet aucune donnée métier.
Sans arguments supplémentaires, il utilise les réglages **enregistrés sur disque**, qui peuvent
différer des valeurs affichées dans une fenêtre Réglages non enregistrée. Il affiche toujours
le modèle et l’endpoint testés. Pour vérifier les valeurs actives sans les enregistrer :

```sh
.build/release/PepitoAgentProbe --endpoint-test .build/Pepito.app/Contents/Resources/AgentRuntime <endpoint> <modele>
```

Le diagnostic navigateur utilise uniquement `https://example.com` et enregistre une capture
dans le cache de test. Les diagnostics VM ne sont pas exécutés en CI.

État vérifié le 13 septembre 2026 : 140 tests Swift, 6 tests Node ; exécution réelle des trois
langages, absence de réseau direct et de secrets, export, consultation web, capture et arrêt.
Le contrôle UI dans un bundle et une base séparés a vérifié le rendu des colonnes, la création,
la saisie et l’import d’un fichier. Les tests couvrent JSONL fragmenté, refus, annulation, sortie du processus, reprise de session,
non-persistance du token, récupération après interruption et conflit avec une édition humaine.

Correction du diagnostic : le premier HTTP 401 concernait les réglages enregistrés sur disque,
qui pointaient vers un autre fournisseur que celui affiché dans Pépito. Le client natif confirme
HTTP 200 avec la configuration affichée ; le token utilisateur est valide. Le parcours réel
Swift → Pi → outil → réponse est également confirmé avec cette même configuration. Le scénario
métier complet reste à valider.
La QA avec un enregistrement réel et la mesure des ressources pendant cet enregistrement
restent à effectuer ; aucun enregistrement utilisateur n’a été démarré pour ces tests.

## Périmètre actuel

Une mission à la fois, tant que le Mac et Pépito sont actifs. Les revues de mails déjà présentes
sont consultables ; la mission ne lit pas directement une nouvelle boîte mail. Les documents
sont autorisés par import, sans indexation implicite de tout le Vault. Le seul changement métier
exposé pour ce lot est le statut d’une action ; les relances sont des brouillons Markdown.

Le navigateur est un aperçu Chromium pilotable par clic et saisie, avec reprise manuelle.
Les connexions impliquant plusieurs domaines exigent de les ouvrir explicitement ; les flux
OAuth à fenêtres multiples, WebSockets et téléchargements du navigateur ne sont pas couverts.
Les transactions importantes doivent être finalisées manuellement. Les profils de connexion
ne sont pas conservés entre les tours. Automatisations, sous-agents et plugins tiers sont hors lot.
