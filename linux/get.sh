#!/usr/bin/env bash
# Linux Silent Installer - web bootstrapper.
#
#   curl -fsSL https://raw.githubusercontent.com/rifathridoy40/win-silent-installer/main/linux/get.sh | bash
#
# With arguments:
#   curl -fsSL .../linux/get.sh | bash -s -- --apps chrome,git,node --yes
#
# Downloads the repository to ~/.local/share/win-silent-installer and runs linux/install.sh from
# there, so the interactive picker gets a real terminal instead of the piped script.

set -uo pipefail

REPO="${WSI_REPO:-rifathridoy40/win-silent-installer}"
BRANCH="${WSI_BRANCH:-main}"
HOME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/win-silent-installer"
APP_DIR="$HOME_DIR/app"
TARBALL="${WSI_TARBALL_URL:-https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz}"

printf '\033[36mDownloading %s (%s)...\033[0m\n' "$REPO" "$BRANCH"

for tool in curl tar; do
    command -v "$tool" >/dev/null || { printf 'Please install %s first.\n' "$tool"; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsSL "$TARBALL" -o "$tmp/repo.tar.gz"; then
    printf 'Download failed: %s\n' "$TARBALL"
    exit 1
fi
mkdir -p "$tmp/x"
tar -xzf "$tmp/repo.tar.gz" -C "$tmp/x" || { printf 'Could not unpack the download.\n'; exit 1; }
src=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -d $src ]] || { printf 'Unexpected archive layout.\n'; exit 1; }

mkdir -p "$HOME_DIR"
rm -rf "$APP_DIR"
mv "$src" "$APP_DIR"
chmod +x "$APP_DIR/linux/install.sh" 2>/dev/null

# the picker reads keys from the terminal, not from this pipe
exec </dev/tty 2>/dev/null || true
exec bash "$APP_DIR/linux/install.sh" --log-dir "$HOME_DIR/logs" "$@"
