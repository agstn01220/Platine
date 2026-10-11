# Platine

Mini player flottant pour macOS qui affiche et contrôle ce qui joue sur le Mac, quelle que soit la source : Chrome (Deezer, YouTube...), Safari, Spotify, Musique.

- Pochette, titre, artiste, précédent / lecture-pause / suivant, barre de progression.
- Choix de la sortie audio (icône haut-parleur).
- Toujours au premier plan, sur tous les bureaux, masqué dans Mission Control.
- Déplaçable à la souris, redimensionnable par la poignée en bas à droite.
- Icône dans la barre des menus : clic pour masquer / afficher le lecteur, clic droit pour le menu.
- Clic droit sur le lecteur : masquer, lancer à l'ouverture de session, quitter.

## Clavier

Après un clic sur le lecteur :

| Touche | Action |
| --- | --- |
| Espace | Lecture / pause |
| ← / → | Reculer / avancer de 10 s |
| ⇧← / ⇧→ | Morceau précédent / suivant |

## Installer

1. Télécharger `Platine.dmg` depuis la page [Releases](../../releases/latest).
2. Ouvrir le fichier et glisser Platine dans Applications.
3. Au premier lancement, macOS bloque l'app car elle n'est pas notarisée par Apple : ouvrir `Réglages Système > Confidentialité et sécurité`, puis cliquer sur « Ouvrir quand même ».

Prérequis : macOS 13 ou plus récent.

## Compiler soi-même

```sh
./build.sh install
```

Construit l'app, la copie dans `~/Applications` et la lance. Prérequis : Xcode Command Line Tools.

## Fonctionnement

L'app lit le « À l'écoute » de macOS (framework privé MediaRemote). Depuis macOS 15.4, ce framework est réservé aux binaires Apple ; l'accès passe donc par [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3, copié dans `vendor/` au commit `797729d`), exécuté par `/usr/bin/perl`. Apple peut casser ce contournement lors d'une mise à jour.

| Fichier | Rôle |
| --- | --- |
| `main.swift` | Toute l'app |
| `selftest.swift` | Auto-vérification : `PLATINE_SELFTEST=/tmp/p.png <chemin affiché par build.sh>/Contents/MacOS/Platine` |
| `icon.swift` | Génère `AppIcon.icns` |
| `build.sh` | Compile et assemble `Platine.app` |

## Licence

MIT. `vendor/mediaremote-adapter` reste sous sa licence BSD-3.
