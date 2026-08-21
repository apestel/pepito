# Checklist QA — à passer avant chaque tag

Sur la **build release** (`./build-app.sh release && open .build/Pepito.app`), pas sur un build
debug. Tout ce qui suit échappe structurellement à la CI : matériel audio, TCC, vraie boîte mail,
vraie base de données. `release.sh` affiche cette liste et attend une validation explicite.

## Capture

- [ ] Le démarrage depuis la barre de menus lance l'enregistrement, le VU-mètre bouge à la voix.
- [ ] La sortie audio système est captée (tap Core Audio) : lancer une vidéo, vérifier le niveau.
- [ ] Réunion en présentiel (aucun son système) : `system.caf` vide, aucune erreur affichée.
- [ ] Stop → l'audio est sur disque, la réunion apparaît dans la timeline.

## Permissions (TCC)

- [ ] Micro, Enregistrement d'écran, Reconnaissance vocale, Calendrier, Rappels, Mail : chaque
      refus donne un message clair et un état dégradé, pas un crash ni un silence.

## Transcription & pipeline

- [ ] Transcription live : les segments arrivent pendant la réunion, le transcript final est écrit.
- [ ] Pipeline agentic bout en bout sur une réunion courte réelle → résumé, décisions, actions
      hiérarchisées, fichiers Markdown rangés dans le Vault.
- [ ] Les actions créées portent le bon projet et la bonne implication (own / follow / info).

## Mail

- [ ] Triage sur la vraie boîte Mail.app : la revue est rendue, les actions rejoignent le backlog.
- [ ] Re-lancer le même triage ne duplique pas les actions et préserve les statuts édités à la main.

## Migration (le risque n°1 d'une release)

- [ ] Lancer sur une **copie de la base de la version précédente** : aucune perte de réunion,
      d'action ni de projet ; les `status` et `involvement` modifiés à la main ont survécu.

## Performance

- [ ] `./profile.py` sur la build release, app au repos : CPU < 5 %.

## Le livrable

- [ ] Version affichée dans l'écran d'administration = version qu'on tague.
- [ ] Après publication : télécharger le DMG de la release, le monter, glisser dans Applications,
      lancer via **clic droit › Ouvrir** (l'app n'est pas notarisée) — l'icône et l'app sont bonnes.
