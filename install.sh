#!/usr/bin/env bash
# tm installer — https://github.com/MoarNachos/tm
# Usage: curl -fsSL https://raw.githubusercontent.com/MoarNachos/tm/main/install.sh | bash
set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/MoarNachos/tm/main/tm"
INSTALL_DIR="${TM_INSTALL_DIR:-$HOME/.local/bin}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v tmux >/dev/null 2>&1 || say "warning: tmux not found on this machine (needed to manage local sessions)"

# Ensure the rich library is available
if ! python3 -c 'import rich' >/dev/null 2>&1; then
    say "Installing python dependency: rich"
    python3 -m pip install --user rich 2>/dev/null \
        || python3 -m pip install --user --break-system-packages rich \
        || die "could not install 'rich' — install it manually: pip install rich"
fi

say "Installing tm to $INSTALL_DIR/tm"
mkdir -p "$INSTALL_DIR"
curl -fsSL "$RAW_URL" -o "$INSTALL_DIR/tm"
chmod +x "$INSTALL_DIR/tm"

case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) say "note: $INSTALL_DIR is not on your PATH — add: export PATH=\"$INSTALL_DIR:\$PATH\"" ;;
esac

say "Done. Run: tm"
