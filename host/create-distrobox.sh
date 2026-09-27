#!/usr/bin/env bash
# Create the distrobox(es) described in distrobox.ini (the `dev` box: compilers and -devel libs).
# Run as your user. Safe to re-run: existing boxes are kept as they are.
# Usage: ./create-distrobox.sh             create missing boxes
#        ./create-distrobox.sh --replace   delete and recreate them from the ini (loses anything
#                                          installed in a box by hand)
set -euo pipefail

[ "$EUID" -ne 0 ] || { echo "run as your user, not root" >&2; exit 1; }
REPLACE=()
case ${1:-} in
  '') ;;
  --replace) REPLACE=(--replace) ;;
  *) echo "usage: $0 [--replace]" >&2; exit 1 ;;
esac

distrobox assemble create "${REPLACE[@]}" --file "$(dirname "$(readlink -f "$0")")/distrobox.ini"
distrobox list
