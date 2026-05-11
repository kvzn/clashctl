#!/usr/bin/env bash
# install.sh - one-shot installer for clashctl
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/kvzn/clashctl/main/install.sh | bash
#
# Override defaults:
#   BIN_PATH=$HOME/.local/bin/clashctl SCRIPT_REF=main bash install.sh
set -euo pipefail

BIN_PATH="${BIN_PATH:-/usr/local/bin/clashctl}"
SCRIPT_REF="${SCRIPT_REF:-main}"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/kvzn/clashctl/${SCRIPT_REF}/clashctl}"

SUDO=""
if [ "$(id -u)" -ne 0 ] && [ ! -w "$(dirname "$BIN_PATH")" ]; then
    SUDO="sudo"
fi

# 1) install uv (provides the inline-deps runtime for the script)
if ! command -v uv >/dev/null 2>&1; then
    echo "==> Installing uv (https://astral.sh/uv)"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # uv lands in ~/.local/bin; expose for this script and the shebang lookup
    export PATH="$HOME/.local/bin:$PATH"
fi

# 2) drop clashctl into place
echo "==> Downloading clashctl → $BIN_PATH"
$SUDO curl -fsSL "$SCRIPT_URL" -o "$BIN_PATH"
$SUDO chmod +x "$BIN_PATH"

# 3) warm the uv cache (first run resolves PyYAML / httpx / click)
echo "==> Warming dependency cache (one-off, ~5s)"
"$BIN_PATH" --version >/dev/null 2>&1 || true

# 4) friendly hint
echo
echo "clashctl installed at $BIN_PATH"
echo "Try: clashctl info"

# PATH hint if the install location isn't already exported
case ":$PATH:" in
  *":$(dirname "$BIN_PATH"):"*) ;;
  *)
    echo
    echo "Note: $(dirname "$BIN_PATH") is not in your PATH yet."
    echo "Add this to your shell rc:"
    echo "  export PATH=\"$(dirname "$BIN_PATH"):\$PATH\""
    ;;
esac
