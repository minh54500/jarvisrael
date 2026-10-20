# Encoche

Un petit bonhomme qui vit dans l'encoche de ton Mac et garde un œil sur Claude Code pour toi.

![Le bonhomme d'Encoche](docs/bonhomme.png)

## Ce qu'il fait

- **Suit tes sessions Claude Code** (VS Code ou terminal) : ce que Claude est en train de faire, quand il a fini, quand il attend.
- **Autorise ou refuse** les demandes de Claude depuis l'encoche, ou au clavier avec ⌥⇧Y / ⌥⇧N.
- **Écris à Claude sans quitter ce que tu fais** : ⌥Espace ouvre l'encoche prête à écrire, ⌥⇧Espace pour dicter.
- **Prompts favoris** en un clic (« Continue », « Lance les tests »…), **choix du modèle**, et un **bilan de fin** : fichiers modifiés, lignes, tokens.
- **Étagère** pour garder des fichiers sous la main, **historique du presse-papiers**, **capture d'écran** envoyée à Claude.
- **Onglet Dev** : tes serveurs locaux (ouvrir, arrêter), CPU, mémoire, batterie.
- **Spotify** : le morceau en cours, lecture/pause, précédent/suivant.
- **Rappels** : pause, verre d'eau, « va dormir »… Tout se coupe dans les Réglages.
- **Notifications sur ton téléphone** avec [ntfy](https://ntfy.sh), si tu veux (désactivé par défaut).

## Installer

Il te faut un Mac sous **macOS 14 (Sonoma) ou plus récent**, idéalement avec une encoche (sinon une encoche virtuelle apparaît en haut de l'écran), et **Claude Code**.

Colle ça dans le Terminal :

```sh
curl -fsSL https://raw.githubusercontent.com/minh54500/encoche/main/install.sh | zsh
```

Le script télécharge le code, le compile sur ton Mac (1 à 2 minutes) et installe Encoche dans `~/Applications`. Si macOS te propose d'installer les « outils de développement », accepte, attends la fin, puis relance la commande.

> Pourquoi compiler ? L'app n'est pas signée par Apple : téléchargée toute faite, macOS la bloquerait. Compilée chez toi, elle s'ouvre normalement.

## Premier lancement

1. Survole l'encoche en haut de l'écran et clique **Brancher à Claude Code**. Encoche ajoute ses hooks dans `~/.claude/settings.json` (une sauvegarde est faite à côté). Si Encoche n'est pas ouverte, Claude Code marche exactement comme avant.
2. Ouvre (ou relance) une session Claude Code : elle apparaît dans l'encoche.
3. macOS te demandera certaines autorisations la première fois que tu utilises la fonction concernée :
   - **Accessibilité** : pour écrire à Claude depuis l'encoche ;
   - **Automatisation → Spotify** : pour piloter la musique ;
   - **Micro et Reconnaissance vocale** : pour la dictée ;
   - **Enregistrement de l'écran** : pour la capture.

Les Réglages s'ouvrent avec la roue dentée de l'encoche, ou d'un clic droit sur le bonhomme.

> ⌥Espace remplace l'espace insécable du clavier français. Tu peux choisir un autre raccourci dans les Réglages.

## Mettre à jour

Relance la même commande `curl … | zsh`.

Chaque mise à jour redemande les autorisations macOS. Pour les garder d'une version à l'autre, lance une fois :

```sh
~/.encoche/tools/cert.sh
```

Ce script crée un certificat local qui donne toujours la même signature à l'app. macOS te demandera ton mot de passe pour l'ajouter au trousseau.

## Désinstaller

1. Clic droit sur le bonhomme → **Débrancher de Claude Code**, puis **Quitter Encoche**.
2. Supprime `~/Applications/Encoche.app`, `~/Library/Application Support/Encoche` et `~/.encoche`.

## Compiler à la main

```sh
git clone https://github.com/minh54500/encoche.git
cd encoche
./build.sh
```
