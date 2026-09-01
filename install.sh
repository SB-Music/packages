#!/bin/sh
set -eu

REPOSITORY_URL="${SBMUSIC_REPO_BASE:-https://sb-music.github.io/packages}"
KEY_FINGERPRINT="E44ADA052DE08C1995D39F15A03603D044744D0F"
KEY_URL="$REPOSITORY_URL/sbmusic-packages-key.asc"

say() { printf '%s\n' ":: $*"; }
fail() { printf '%s\n' "Erreur: $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  RUN=""
elif command -v sudo >/dev/null 2>&1; then
  RUN="sudo"
else
  fail "lancez ce script en root ou installez sudo"
fi

machine="$(uname -m)"
case "$machine" in
  x86_64|amd64) ;;
  *) fail "architecture non prise en charge: $machine (x86_64 uniquement)" ;;
esac

[ -r /etc/os-release ] || fail "/etc/os-release est introuvable"
# shellcheck disable=SC1091
. /etc/os-release
distribution="${ID:-} ${ID_LIKE:-}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

download_key() {
  command -v curl >/dev/null 2>&1 || fail "curl est requis"
  curl -fsSL "$KEY_URL" -o "$tmp_dir/key.asc"
}

verify_key() {
  actual_fingerprint="$(gpg --batch --show-keys --with-colons "$tmp_dir/key.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
  [ "$actual_fingerprint" = "$KEY_FINGERPRINT" ] || \
    fail "empreinte de clé invalide: ${actual_fingerprint:-absente}"
}

case "$distribution" in
  *debian*|*ubuntu*)
    say "Configuration du dépôt APT SB'Music"
    $RUN env DEBIAN_FRONTEND=noninteractive apt-get update
    $RUN env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    download_key
    verify_key
    gpg --batch --dearmor < "$tmp_dir/key.asc" > "$tmp_dir/key.gpg"
    $RUN install -Dm0644 "$tmp_dir/key.gpg" /usr/share/keyrings/sbmusic-archive-keyring.gpg
    printf '%s\n' "deb [arch=amd64 signed-by=/usr/share/keyrings/sbmusic-archive-keyring.gpg] $REPOSITORY_URL/deb stable main" > "$tmp_dir/sbmusic.list"
    $RUN install -Dm0644 "$tmp_dir/sbmusic.list" /etc/apt/sources.list.d/sbmusic.list
    $RUN apt-get update
    $RUN env DEBIAN_FRONTEND=noninteractive apt-get install -y sb-music-desktop
    ;;
  *fedora*|*rhel*|*centos*)
    say "Configuration du dépôt DNF SB'Music"
    download_key
    command -v gpg >/dev/null 2>&1 || $RUN dnf install -y gnupg2
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
  *arch*|*manjaro*)
    say "Configuration du dépôt pacman SB'Music"
    download_key
    verify_key
    $RUN pacman-key --init
    $RUN pacman-key --add "$tmp_dir/key.asc"
    $RUN pacman-key --lsign-key "$KEY_FINGERPRINT"
    if ! grep -q '^\[sbmusic\]$' /etc/pacman.conf; then
      cat > "$tmp_dir/pacman.conf" <<EOF

[sbmusic]
Server = $REPOSITORY_URL/arch
EOF
      $RUN sh -c 'cat "$1" >> /etc/pacman.conf' sh "$tmp_dir/pacman.conf"
    fi
    $RUN pacman -Syu --noconfirm sb-music-desktop
    ;;
  *)
    fail "distribution non prise en charge: ${ID:-inconnue}"
    ;;
esac

say "SB'Music est installé. Lancez-le depuis votre menu d'applications ou avec sb_music."
