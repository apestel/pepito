# Missions Pépito

## Parcours

Créer une mission, préciser le résultat et importer les fichiers utiles. Les réunions,
actions, revues de mails et calendrier ne sont accessibles qu’avec l’autorisation dédiée.
Les réponses et les groupes d’outils forment la conversation. Chaque appel peut être déplié :
**Requête**, **Vérification**, **Réponse** (stdout, stderr, durée et code de sortie pour les scripts).
Les états en cours, échec et interruption sont conservés avec la mission.

Le panneau droit se masque et propose **Livrables**, **Fichiers**, **Sources**, **Web**.
Un livrable s’ouvre dans le panneau : Markdown, texte, HTML autonome, ou aperçu Quick Look
pour les formats pris en charge par macOS (PDF, images, documents…). L’HTML peut exécuter
son JavaScript de rendu mais ne dispose ni de réseau, ni de pont vers Pépito. Les bibliothèques
et images doivent être intégrées dans le document. Le bouton Source montre le contenu brut.
Les aperçus texte sont plafonnés à 1 Mio ; les fichiers complets restent exportables.

**Arrêter** interrompt l’agent et les scripts. Une nouvelle instruction reprend la session
et retrouve son scratchpad. Un appel au résultat incertain n’est jamais rejoué automatiquement.
Les changements métier restent soumis à validation et aux contrôles de conflit existants.

## Scratchpad et isolation

Chaque mission possède `missions/<UUID>/scratchpad`, à côté de `inputs`, `outputs`, `events`
et `session`. Les imports sont copiés dans le scratchpad ; l’original reste inchangé. Le dossier
courant des scripts est ce scratchpad, également disponible dans `PEPITO_WORKSPACE`. Il persiste
entre les tours. `read_artifact` publie un fichier du scratchpad dans les livrables, même après
une reprise. Les journaux complets d’exécution restent dans `events`, hors des livrables.

Les scripts sont des processus macOS sous **Seatbelt** (`sandbox-exec`), sans VM, conteneur,
noyau téléchargé ou image Linux. Un superviseur Node de confiance construit une politique
`deny default`, puis lance le code avec un environnement minimal, sans token ni variables
personnelles. Les lectures sont limitées au scratchpad et aux composants système/runtime
nécessaires ; les écritures au scratchpad. Aucun repli non isolé n’est prévu en cas d’échec.

Python utilise l’interpréteur des outils Apple ; JavaScript utilise Node embarqué ; le shell
est `/bin/bash` sans profils utilisateur. Les bibliothèques Python tierces ne sont pas embarquées.
La sandbox n’est pas une VM : elle partage le noyau macOS et dépend du mécanisme Seatbelt,
déprécié par Apple. Une commande dispose de 60 secondes, sa sortie est limitée à 4 Mio, avec
limites CPU et taille de fichier. Le superviseur termine le groupe de processus à l’arrêt,
au délai et à la fin. Ce n’est pas un quota de disque global ni une garantie contre tous les
mécanismes de détachement d’un processus hostile. Les descendants héritent néanmoins de la politique.

Les entrées et exports sont limités à 100 Mio par fichier, avec noms simples et refus des liens,
traversées, fichiers spéciaux et liens physiques. Les lectures vérifient le descripteur ouvert
avec `O_NOFOLLOW`. Un fichier du scratchpad est copié hors de la zone modifiable avant aperçu.
Les livrables texte créés directement par `write_artifact` sont limités à 1 Mio.

### Internet

Le réseau des scripts est bloqué par défaut. Le modèle peut demander `network: true` pour
`curl`, DuckDuckGo ou un téléchargement. Si **Autoriser Internet aux scripts** est activé pour
la mission, cet appel est permis ; sinon, l’utilisateur valide ce script précis. La demande
et la vérification indiquent que le script peut transmettre le contenu de son scratchpad.
Le réseau est alors disponible aux processus de cet appel, y compris le réseau local ;
cela n’élargit pas leurs droits de lecture/écriture. L’autorisation ne copie aucun secret.

`download_file` conserve son contrôleur HTTP séparé : DNS épinglé, réseau privé refusé,
pas de redirection, 8 Mio maximum et validation humaine. Pi ne reçoit que les outils Pépito,
sans shell hôte, extensions ou configuration personnelle. Son token IA arrive par stdin.

### Navigateur

Le navigateur utilise **WebKit**, avec une session éphémère indépendante de Safari. Les pages
s’affichent directement dans le panneau. **Prendre la main** permet de cliquer, remplir un
formulaire et naviguer ; le modèle cesse alors de piloter. Les actions du modèle sont soumises
à confirmation. Les navigations automatisées restent sur les domaines explicitement ouverts,
en HTTP(S), avec GET/HEAD ; les envois de formulaire nécessitent le contrôle manuel.
Les sous-ressources utilisent le réseau WebKit normal, pas le contrôleur DNS de `download_file`.
Les fenêtres secondaires et schémas externes sont refusés. Aucun profil de connexion n’est partagé. La page reste consultable à la fin du tour ; la session est remplacée lors de l’ouverture du navigateur d’une autre mission ou à la fermeture de l’app.

## Assemblage et tests

`./build-app.sh release` vérifie l’archive Node 24.21.0 par SHA-256, installe le verrou npm
sans scripts d’installation, assemble et signe le bundle. Aucun téléchargement de VM n’a lieu.
Python 3 et npm servent à construire ; Xcode/Command Line Tools fournit Python pour les scripts.

```sh
swift test
PATH="$PWD/.build/agent-assets:$PATH" npm test --prefix Runtime
./build-app.sh release
.build/release/PepitoAgentProbe .build/Pepito.app/Contents/Resources/AgentRuntime /tmp/pepito-scratch-test
.build/release/PepitoAgentProbe --endpoint-test .build/Pepito.app/Contents/Resources/AgentRuntime
```

Les tests utilisent le Node autonome préparé par `Packaging/prepare-agent-runtime.py` (ou un Node officiel équivalent). Les distributions Homebrew avec bibliothèques externes ne sont pas le runtime du bundle.

Les tests natifs d’isolation doivent tourner hors d’une sandbox parent qui interdit
`sandbox-exec`. Ils utilisent un faux secret et un serveur HTTP loopback, vérifient les trois
langages, la persistance, les refus de lecture/écriture, les alias du volume, les liens,
l’accès réseau opt-in, l’annulation, les descendants, le délai et la limite de sortie.
Les tests Swift vérifient aussi la reprise, les conflits et la compatibilité des anciens journaux.
Le diagnostic endpoint utilise les réglages enregistrés et ne transmet aucune donnée métier.

## Inspiration inspectée

Bionic sépare un scratchpad hôte de son outil Python Pyodide/WASM sous Deno : entrées copiées
vers `/inputs`, sorties collectées depuis `/outputs`, limites explicites et appels repliables.
Pépito reprend les concepts de workspace, traçabilité et rendu intégré avec les briques macOS
existantes ; il ne copie pas le runtime de Bionic et ne prétend pas utiliser son isolation WASM.

Une mission fonctionne à la fois, tant que le Mac et Pépito restent actifs. Les automatisations,
sous-agents de revue et plugins tiers ne sont pas ajoutés. L’onglet Vérification affiche les
contrôles effectifs et décisions humaines, sans prétendre qu’un second modèle a audité le code.
