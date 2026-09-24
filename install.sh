#!/bin/sh
# Installe SB'Music depuis le dépôt signé (apt, dnf ou pacman) :
#   curl -fsSL https://sb-music.github.io/packages/install.sh | sh
#
# Les distributions dérivées sont reconnues par leur famille (ID et ID_LIKE
# de /etc/os-release), à défaut par le gestionnaire de paquets présent.
# Options :
#   --detect                        affiche la famille détectée, sans rien installer
#   SBMUSIC_FAMILY=apt|dnf|pacman   force la famille (distribution exotique)
set -eu

REPOSITORY_URL="${SBMUSIC_REPO_BASE:-https://sb-music.github.io/packages}"
KEY_FINGERPRINT="E44ADA052DE08C1995D39F15A03603D044744D0F"
KEY_URL="$REPOSITORY_URL/sbmusic-packages-key.asc"
OS_RELEASE="${SBMUSIC_OS_RELEASE:-/etc/os-release}"

say() { printf '%s\n' ":: $*"; }
warn() { printf '%s\n' "Attention : $*" >&2; }
fail() { printf '%s\n' "Erreur : $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

# ---- Famille de la distribution ----------------------------------------

ID=""
ID_LIKE=""
PRETTY_NAME=""
if [ -r "$OS_RELEASE" ]; then
  # shellcheck disable=SC1090
  . "$OS_RELEASE"
fi
os_name="${PRETTY_NAME:-${ID:-inconnue}}"

# Une famille d'après un identifiant (ID ou un mot de ID_LIKE).
family_of() {
  case "$1" in
    debian|ubuntu|linuxmint|mint|pop|elementary|zorin|kali|parrot|deepin|pureos|\
    mx|devuan|neon|raspbian|tuxedo|peppermint|lmde|bodhi|trisquel|kubuntu|xubuntu|\
    lubuntu|ubuntu-mate|ubuntustudio|ubuntukylin|vanilla|siduction|sparky|antix|q4os|\
    feren|lite|nitrux|bunsenlabs|makululinux|rhino)
      echo apt ;;
    arch|archarm|manjaro|manjaro-arm|endeavouros|garuda|cachyos|artix|arcolinux|\
    archcraft|rebornos|steamos|biglinux|blendos|crystal|mabox|archman|parabola|\
    hyperbola|athena|chimeraos|xerolinux|bluestar|obarun|instantos|axos)
      echo pacman ;;
    fedora|rhel|centos|rocky|almalinux|nobara|ultramarine|ol|amzn|risios|qubes|\
    bazzite|aurora|bluefin)
      echo dnf ;;
    opensuse*|suse|sles|sled)
      echo zypper ;;
    *) echo "" ;;
  esac
}

detect_family() {
  if [ -n "${SBMUSIC_FAMILY:-}" ]; then
    echo "$SBMUSIC_FAMILY"
    return
  fi
  # Minuscules : certaines dérivées écrivent « Ubuntu » ou « Arch ».
  for word in $(printf '%s %s' "$ID" "$ID_LIKE" | tr '[:upper:]' '[:lower:]' | tr '"' ' '); do
    found="$(family_of "$word")"
    if [ -n "$found" ]; then echo "$found"; return; fi
  done
  # Distribution inconnue : on se fie au gestionnaire de paquets.
  if has pacman; then echo pacman
  elif has apt-get && has dpkg; then echo apt
  elif has dnf; then echo dnf
  elif has zypper; then echo zypper
  else echo ""
  fi
}

case "${SBMUSIC_FAMILY:-}" in
  ''|apt|dnf|pacman) ;;
  *) fail "SBMUSIC_FAMILY doit valoir apt, dnf ou pacman" ;;
esac
family="$(detect_family)"

if [ "${1:-}" = "--detect" ]; then
  printf '%s\n' "${family:-aucune}"
  exit 0
fi

# ---- Vérifications générales ---------------------------------------------

machine="$(uname -m)"
case "$machine" in
  x86_64|amd64) ;;
  *) fail "architecture non prise en charge : $machine (x86_64 uniquement)" ;;
esac

case "$family" in
  apt|dnf|pacman) ;;
  zypper)
    fail "openSUSE n'est pas encore pris en charge ($os_name) : les noms de ses paquets diffèrent de ceux de Fedora." ;;
  *)
    fail "distribution non reconnue ($os_name). Si elle dérive de Debian, d'Arch ou de Fedora, relancez avec SBMUSIC_FAMILY=apt, pacman ou dnf." ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  RUN=""
elif has sudo; then
  RUN="sudo"
elif has doas; then
  RUN="doas"
else
  fail "lancez ce script en root, ou installez sudo ou doas"
fi

# Systèmes au disque en lecture seule : on ne peut pas y ajouter de paquet
# de cette façon.
if has steamos-readonly && steamos-readonly status 2>/dev/null | grep -q enabled; then
  fail "SteamOS est en lecture seule : désactivez-la d'abord (sudo steamos-readonly disable)."
fi
if [ -e /run/ostree-booted ]; then
  fail "système immuable (ostree) : l'installation directe n'est pas possible, passez par une boîte distrobox."
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

download_key() {
  has curl || fail "curl est requis"
  curl -fsSL "$KEY_URL" -o "$tmp_dir/key.asc" || fail "impossible de télécharger la clé du dépôt ($KEY_URL)"
}

verify_key() {
  actual_fingerprint="$(gpg --batch --show-keys --with-colons "$tmp_dir/key.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
  [ "$actual_fingerprint" = "$KEY_FINGERPRINT" ] || \
    fail "empreinte de clé invalide : ${actual_fingerprint:-absente}"
}

# ---- Installation ----------------------------------------------------------

say "Distribution : $os_name (famille $family)"

case "$family" in
  apt)
    say "Configuration du dépôt APT SB'Music"
    # Un dépôt tiers cassé ne doit pas empêcher l'installation.
    $RUN env DEBIAN_FRONTEND=noninteractive apt-get update || \
      warn "apt-get update a signalé des erreurs (un autre dépôt ?), on continue"
    $RUN env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    download_key
    verify_key
    gpg --batch --dearmor < "$tmp_dir/key.asc" > "$tmp_dir/key.gpg"
    $RUN install -Dm0644 "$tmp_dir/key.gpg" /usr/share/keyrings/sbmusic-archive-keyring.gpg
    printf '%s\n' "deb [arch=amd64 signed-by=/usr/share/keyrings/sbmusic-archive-keyring.gpg] $REPOSITORY_URL/deb stable main" > "$tmp_dir/sbmusic.list"
    $RUN install -Dm0644 "$tmp_dir/sbmusic.list" /etc/apt/sources.list.d/sbmusic.list
    $RUN env DEBIAN_FRONTEND=noninteractive apt-get update || \
      warn "apt-get update a signalé des erreurs (un autre dépôt ?), on continue"
    # WebKitGTK 4.1 : Debian 12, Ubuntu 22.04 et leurs dérivées, ou plus récent.
    if ! apt-cache show libwebkit2gtk-4.1-0 >/dev/null 2>&1; then
      fail "WebKitGTK 4.1 est introuvable sur $os_name : il faut une base Debian 12 ou Ubuntu 22.04 au minimum."
    fi
    $RUN env DEBIAN_FRONTEND=noninteractive apt-get install -y sb-music-desktop
    ;;
  dnf)
    say "Configuration du dépôt DNF SB'Music"
    has dnf || fail "dnf est requis"
    download_key
    has gpg || $RUN dnf install -y gnupg2
    verify_key
    $RUN rpm --import "$tmp_dir/key.asc"
    cat > "$tmp_dir/sbmusic.repo" <<EOF
[sbmusic]
name=SB'Music
baseurl=$REPOSITORY_URL/rpm/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$KEY_URL
EOF
    $RUN install -Dm0644 "$tmp_dir/sbmusic.repo" /etc/yum.repos.d/sbmusic.repo
    $RUN dnf install -y sb-music-desktop
    ;;
  pacman)
    say "Configuration du dépôt pacman SB'Music"
    download_key
    has gpg || $RUN pacman -S --needed --noconfirm gnupg
    verify_key
    # Sans effet sur un trousseau prêt ; nécessaire sur certaines dérivées
    # minimales où il n'a jamais été initialisé.
    $RUN pacman-key --init
    $RUN pacman-key --add "$tmp_dir/key.asc"
    $RUN pacman-key --lsign-key "$KEY_FINGERPRINT"
    if ! grep -q '^\[sbmusic\]' /etc/pacman.conf; then
      cat > "$tmp_dir/pacman.conf" <<EOF

[sbmusic]
Server = $REPOSITORY_URL/arch
EOF
      # shellcheck disable=SC2016 # $1 est lu par le sh -c, pas ici.
      $RUN sh -c 'cat "$1" >> /etc/pacman.conf' sh "$tmp_dir/pacman.conf"
    fi
    # Mise à jour complète : pacman ne gère pas les mises à jour partielles.
    $RUN pacman -Syu --needed --noconfirm sb-music-desktop
    ;;
esac

say "SB'Music est installé. Lancez-le depuis votre menu d'applications ou avec sb_music."
