#!/bin/zsh
# Installe (ou met à jour) Encoche : télécharge le code, le compile sur ce Mac et l'installe dans ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/minh54500/encoche/main/install.sh | zsh
# Compilée sur place, l'app s'ouvre sans l'alerte « développeur non vérifié » de macOS.
set -euo pipefail

REPO=https://github.com/minh54500/encoche.git
SRC=~/.encoche

if (( ${$(sw_vers -productVersion)%%.*} < 14 )); then
  echo "✗ Encoche demande macOS 14 (Sonoma) ou plus récent."
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "→ Il faut les outils de développement d'Apple (gratuits). Une fenêtre s'ouvre :"
  echo "  clique « Installer », attends la fin, puis relance cette commande."
  xcode-select --install || true
  exit 1
fi

if [[ -d $SRC/.git ]]; then
  echo "→ Mise à jour du code…"
  git -C $SRC pull --ff-only --quiet
else
  echo "→ Téléchargement du code…"
  git clone --depth 1 --quiet $REPO $SRC
fi

echo "→ Compilation (1 à 2 minutes)…"
$SRC/build.sh
open ~/Applications/Encoche.app

echo
echo "C'est installé. Survole l'encoche en haut de l'écran et clique « Brancher à Claude Code »."
