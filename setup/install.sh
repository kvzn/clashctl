#!/usr/bin/env bash
# Server bootstrap: install mihomo + systemd unit + daily refresh cron + clashctl.
#
# One-shot install:
#   SUBSCRIPTION_URL="https://your-provider/.../clash.yaml" \
#     curl -fsSL https://raw.githubusercontent.com/kvzn/clashctl/main/setup/install.sh | bash
#
# Override env (defaults shown):
#   CLASH_DIR        $HOME/clash       # working directory; mihomo binary, yaml, cache.db live here
#   CLASH_USER       $USER             # user the service runs as
#   CLASH_CONFIG     config.yaml       # yaml filename inside CLASH_DIR
#   PROXY            (none)            # http proxy used for downloads (Github / mihomo release)
#   RAW_BASE         this repo's main
#
# Idempotent: re-running upgrades mihomo + reinstalls scripts + leaves your yaml/cache.db alone.

set -euo pipefail

: "${SUBSCRIPTION_URL:?set SUBSCRIPTION_URL=https://your-subscription-url and re-run}"
CLASH_DIR="${CLASH_DIR:-$HOME/clash}"
CLASH_USER="${CLASH_USER:-$USER}"
CLASH_CONFIG="${CLASH_CONFIG:-config.yaml}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/kvzn/clashctl/main}"

CURL_PROXY=()
if [ -n "${PROXY:-}" ]; then
  export http_proxy="$PROXY" https_proxy="$PROXY"
  CURL_PROXY=(-x "$PROXY")
fi

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo "==> $CLASH_DIR"
mkdir -p "$CLASH_DIR" "$HOME/.config/clash"

# 1) mihomo binary -------------------------------------------------------------
echo "==> Resolving latest mihomo release"
TAG=$(curl -fsSL --connect-timeout 10 "${CURL_PROXY[@]}" \
  https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
  | grep -oE '"tag_name": "[^"]+"' | head -1 | cut -d'"' -f4)
[ -z "$TAG" ] && { echo "ERROR: could not resolve mihomo tag (check network or set PROXY)" >&2; exit 1; }
echo "    tag: $TAG"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        MARCH=amd64 ;;
  aarch64|arm64) MARCH=arm64 ;;
  *) echo "ERROR: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
ASSET="mihomo-linux-${MARCH}-${TAG}.gz"
URL="https://github.com/MetaCubeX/mihomo/releases/download/${TAG}/${ASSET}"
echo "==> Downloading $ASSET"
curl -fL --connect-timeout 15 --max-time 600 "${CURL_PROXY[@]}" -o "$CLASH_DIR/$ASSET" "$URL"
gunzip -f "$CLASH_DIR/$ASSET"
mv -f "$CLASH_DIR/mihomo-linux-${MARCH}-${TAG}" "$CLASH_DIR/mihomo"
chmod +x "$CLASH_DIR/mihomo"
echo "    installed: $($CLASH_DIR/mihomo -v 2>&1 | head -1)"

# 2) subscription env ----------------------------------------------------------
ENVFILE="$HOME/.config/clash/subscription.env"
echo "==> Writing $ENVFILE"
umask 077
cat > "$ENVFILE" <<EOF
SUBSCRIPTION_URL="$SUBSCRIPTION_URL"
CLASH_CONFIG="$CLASH_CONFIG"
EOF

# 3) refresh.sh ----------------------------------------------------------------
echo "==> Installing refresh.sh"
curl -fsSL "${CURL_PROXY[@]}" "$RAW_BASE/setup/refresh.sh" -o "$CLASH_DIR/refresh.sh"
chmod +x "$CLASH_DIR/refresh.sh"

# 4) seed initial config -------------------------------------------------------
if [ ! -f "$CLASH_DIR/$CLASH_CONFIG" ]; then
  echo "==> Seeding initial config via refresh.sh"
  "$CLASH_DIR/refresh.sh" || {
    echo "ERROR: initial subscription fetch failed; check SUBSCRIPTION_URL / network" >&2
    exit 1
  }
fi

# 5) systemd unit --------------------------------------------------------------
echo "==> Installing /etc/systemd/system/clash.service"
TMPUNIT=$(mktemp)
curl -fsSL "${CURL_PROXY[@]}" "$RAW_BASE/setup/clash.service" \
  | sed "s|__CLASH_USER__|$CLASH_USER|g; s|__CLASH_DIR__|$CLASH_DIR|g; s|__CLASH_CONFIG__|$CLASH_CONFIG|g" \
  > "$TMPUNIT"
$SUDO install -m 644 "$TMPUNIT" /etc/systemd/system/clash.service
rm -f "$TMPUNIT"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now clash.service
sleep 1
echo "    state: $(systemctl is-active clash.service)"

# 6) cron (daily refresh at 5am) -----------------------------------------------
echo "==> Installing daily refresh cron"
CRONLINE="0 5 * * * $CLASH_DIR/refresh.sh >> $CLASH_DIR/refresh.log 2>&1"
( crontab -l 2>/dev/null | grep -v "/refresh.sh" ; echo "$CRONLINE" ) | crontab -

# 7) clashctl ------------------------------------------------------------------
echo "==> Installing clashctl"
curl -fsSL "${CURL_PROXY[@]}" "$RAW_BASE/install.sh" | bash

# 8) summary -------------------------------------------------------------------
cat <<EOF

==================================================================
 Done. Clash is running under systemd as user '$CLASH_USER'.

 Service:     systemctl status clash.service
 Subscription:  $ENVFILE
 Config:      $CLASH_DIR/$CLASH_CONFIG
 Cron:        $(crontab -l | grep refresh.sh)

 Try:
   clashctl info
   clashctl groups
   clashctl test
==================================================================
EOF
