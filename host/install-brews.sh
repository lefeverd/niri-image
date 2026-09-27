#!/usr/bin/env bash
# Install Homebrew (base-main doesn't ship it) and the formulae from Brewfile.
# Run as your user; asks for sudo once to create /home/linuxbrew. Safe to re-run.
# The image's /etc/profile.d/brew.sh puts brew on PATH in new login shells.
set -euo pipefail

BREW=/home/linuxbrew/.linuxbrew/bin/brew
[ "$EUID" -ne 0 ] || { echo "run as your user, not root" >&2; exit 1; }

if [ ! -x "$BREW" ]; then
  echo "== installing Homebrew"
  NONINTERACTIVE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$("$BREW" shellenv)"

BREWFILE=$(dirname "$(readlink -f "$0")")/Brewfile
# brew refuses formulae from third-party taps until they're trusted
while read -r t; do
  brew tap "$t"
  brew trust "$t"
done < <(sed -n 's/^tap "\([^"]*\)".*/\1/p' "$BREWFILE")

echo "== brew bundle"
brew bundle --file "$BREWFILE"
