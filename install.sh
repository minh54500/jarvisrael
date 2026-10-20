#!/bin/zsh
# Installe (ou met à jour) Encoche : télécharge le code, le compile sur ce Mac et l'installe dans ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/minh54500/jarvisrael/main/install.sh | zsh
# Compilée sur place, l'app s'ouvre sans l'alerte « développeur non vérifié » de macOS.
set -euo pipefail

REPO=https://github.com/minh54500/jarvisrael.git
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

# Une seule fois : proposer le certificat local qui garde les autorisations macOS d'une mise à jour à l'autre.
if ! security find-certificate -c "Encoche Dev" >/dev/null 2>&1 && [[ ! -e $SRC/.cert-asked ]] && [[ -r /dev/tty ]]; then
  touch $SRC/.cert-asked
  echo
  echo "→ Sans certificat, macOS redemande les autorisations (Accessibilité…) après chaque mise à jour."
  echo "  Encoche peut créer un certificat local, rien qu'à elle, pour l'éviter (macOS demandera ton mot de passe)."
  printf "  Créer le certificat ? [o/N] "
  read -r answer < /dev/tty || answer=""
  if [[ $answer == [oOyY]* ]]; then
    $SRC/tools/cert.sh || echo "  Certificat non créé : ce n'est pas grave, Encoche marche sans."
  fi
  echo
fi

echo "→ Compilation (1 à 2 minutes)…"
$SRC/build.sh
# Juste après l'installation, macOS peut ne pas encore connaître la nouvelle app : on réessaie.
open ~/Applications/Encoche.app 2>/dev/null || { sleep 2; open ~/Applications/Encoche.app; }

echo
echo "C'est installé. Survole l'encoche en haut de l'écran et clique « Brancher à Claude Code »."
