---
name: release
description: Publie une version de Pépito — choix du numéro semver, changelog Fonctionnel/Technique, tests, QA manuelle validée par l'utilisateur, tag, et release GitHub avec DMG. Utiliser quand l'utilisateur demande de « faire une release », « publier une version », « taguer », « livrer », « sortir une v0.x », ou de préparer un DMG à distribuer.
---

# Release de Pépito

Une release passe par **quatre portes**, dans cet ordre. Ne jamais en sauter une, ne jamais taguer
« pour voir ».

```
tests verts  →  changelog écrit  →  QA manuelle validée PAR L'UTILISATEUR  →  tag poussé
                                                                              ↓
                                                     workflow Release : DMG + notes + publication
```

## 1. Choisir le numéro

Pré-1.0 : `MINOR` = fonctionnalité **ou** rupture (schéma SQLite, format Vault), `PATCH` = correctif.
`1.0.0` seulement quand la phase 8 est faite : signature Developer ID, notarisation, validation
matérielle des taps Core Audio.

Regarder ce qui s'est passé depuis le dernier tag avant de proposer :

```bash
git describe --tags --abbrev=0            # dernier tag (rien au tout début : 0.5.0 est le départ)
git log $(git describe --tags --abbrev=0)..HEAD --format='%s%n%b'
```

Proposer le numéro à l'utilisateur avec une justification d'une ligne, et le laisser trancher.

Pour répéter la chaîne sans publier une vraie version : `X.Y.Z-rc.N` → le workflow publie une
**pre-release**. C'est le bon réflexe la première fois, ou après un changement du workflow.

## 2. Écrire le changelog

Dans `CHANGELOG.md`, remplacer `## [Unreleased]` par `## [X.Y.Z] - AAAA-MM-JJ` (et remettre un
`## [Unreleased]` vide au-dessus). Deux sections obligatoires, elles ont deux lecteurs différents :

- `### Fonctionnel` — ce que l'utilisateur voit et peut faire. Pas de nom de type Swift.
- `### Technique` — modules, migrations SQLite, seams, perf chiffrée, correctifs de fond.

Ajouter `### Limites connues` s'il y en a (non notarisée, chemins non couverts par la CI…).

La matière vient des messages de commit (ils sont détaillés dans ce dépôt : les lire, pas seulement
les titres). Le texte de cette section **est** la note de release publiée : la rédiger pour être lue
telle quelle, en français.

## 3. Lancer `./release.sh X.Y.Z`

Le script tient les portes locales et s'arrête à la moindre : branche ≠ `main`, arbre sale, tag
déjà pris, `swift test` rouge, section de changelog absente. Puis il bumpe `Packaging/Info.plist`
(`CFBundleShortVersionString` + `CFBundleVersion`), construit la build **release**, lance l'app et
attend une validation.

**C'est ici que Claude sert à quelque chose** : dérouler `Packaging/QA-CHECKLIST.md` avec
l'utilisateur, item par item, en attendant sa réponse. Ne jamais répondre `oui` à sa place, ne
jamais supposer qu'un test matériel est passé. Si un item échoue : répondre `non` (le script
restaure la version), corriger, recommencer.

L'item **migration depuis la base de la version précédente** est le plus important : c'est le seul
risque de perte de données d'une release.

Validation donnée → le script commit, tague `vX.Y.Z` et pousse.

## 4. Vérifier la publication

Le tag déclenche `.github/workflows/release.yml` sur un runner `macos-26` : tests, bundle, DMG,
notes extraites du changelog + bloc d'installation, publication.

```bash
gh run watch                          # si gh est installé (brew install gh) — sinon, l'onglet Actions
gh release view "vX.Y.Z"
```

Vérifier : le DMG et le `.sha256` sont attachés, les notes correspondent bien à la section du
changelog, et une `-rc` est bien marquée pre-release. Puis passer le dernier item de la checklist :
télécharger le DMG, le monter, installer, lancer via **clic droit › Ouvrir** (l'app n'est pas
notarisée).

## Ce que la chaîne ne fait pas

- **Pas de notarisation** (pas de compte Apple Developer) : Gatekeeper avertit au premier lancement,
  c'est documenté dans chaque note de release. Le jour où un compte existe : `Developer ID
  Application` + `xcrun notarytool` + `stapler` dans le workflow, avec 4 secrets GitHub.
- **Pas de mise à jour automatique** : Sparkle quand il y aura des utilisateurs tiers.
- **Pas de rollback automatique** : une release ratée se retire à la main
  (`gh release delete`, `git push --delete origin vX.Y.Z`) et se remplace par un `PATCH`.

## Icône

`swift Packaging/make-icon.swift` régénère `Packaging/Pepito.icns` (bulle de dialogue + transcript
coché, dessinée en Core Graphics). À ne relancer que si le dessin change ; toujours montrer
`.build/icon-preview.png` à l'utilisateur avant de commiter le `.icns`.
