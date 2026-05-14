#!/bin/bash
# Refresh clash subscription, preserve runtime customizations, hot-reload.
#
# Required env (one of):
#   SUBSCRIPTION_URL=https://...                      (passed directly), OR
#   ~/.config/clash/subscription.env defining SUBSCRIPTION_URL=...
#
# Optional env (defaults shown):
#   CLASH_CONFIG  config.yaml                # filename inside this script's dir
#   CLASH_API     http://127.0.0.1:9090      # mihomo external-controller
#   CLASH_ENV     ~/.config/clash/subscription.env
#
set -euo pipefail
cd "$(dirname "$0")"

ENVFILE="${CLASH_ENV:-$HOME/.config/clash/subscription.env}"
[ -f "$ENVFILE" ] && . "$ENVFILE"
: "${SUBSCRIPTION_URL:?set SUBSCRIPTION_URL or write it to $ENVFILE}"

CONFIG="${CLASH_CONFIG:-config.yaml}"
API="${CLASH_API:-http://127.0.0.1:9090}"
TMP="${CONFIG}.new"

curl -fsSL --connect-timeout 10 --max-time 60 -A Clash "$SUBSCRIPTION_URL" -o "$TMP"

if ! grep -q "^proxies:" "$TMP"; then
  echo "$(date -Iseconds) ERROR: invalid config from $SUBSCRIPTION_URL" >&2
  rm -f "$TMP"; exit 1
fi

# Apply user's runtime mode + per-group selection (read from the running clash via API)
# onto the freshly downloaded TMP file, so subscription refresh doesn't undo manual choices.
python3 - "$TMP" "$API" <<"PY"
import sys, json, urllib.request, yaml, contextlib
tmp_path, api = sys.argv[1], sys.argv[2]
def fetch(p, timeout=3):
    with contextlib.closing(urllib.request.urlopen(api+p, timeout=timeout)) as r:
        return json.loads(r.read())
try:
    configs = fetch("/configs")
    proxies = fetch("/proxies")["proxies"]
except Exception as e:
    print(f"(runtime API unreachable, skipping preserve: {e})", file=sys.stderr)
    sys.exit(0)
with open(tmp_path) as f: d = yaml.safe_load(f)
changes = []
mode = configs.get("mode")
if mode and d.get("mode") != mode:
    d["mode"] = mode
    changes.append(f"mode={mode}")
for pg in d.get("proxy-groups", []):
    if pg.get("type") not in ("select",): continue
    g = pg.get("name"); ps = pg.get("proxies", [])
    if g not in proxies: continue
    now = proxies[g].get("now")
    if now and now in ps and ps[0] != now:
        ps.remove(now); ps.insert(0, now); pg["proxies"] = ps
        changes.append(f"{g}->{now}")
if changes:
    with open(tmp_path, "w") as f:
        yaml.safe_dump(d, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
status = ", ".join(changes) if changes else "(none)"
print(f"preserved: {len(changes)} item(s): {status}", file=sys.stderr)
PY

mv "$TMP" "$CONFIG"
SIZE=$(wc -c < "$CONFIG")
PROXIES=$(grep -c "^- name:" "$CONFIG" || true)
echo "$(date -Iseconds) refreshed: ${SIZE}B, ${PROXIES} proxies"

# Hot-reload via clash external-controller
if curl -fsS -m 5 -X PUT -H "Content-Type: application/json" \
     --data "{\"path\":\"$PWD/$CONFIG\"}" \
     "$API/configs" >/dev/null 2>&1; then
  echo "$(date -Iseconds) reloaded via API"
else
  echo "$(date -Iseconds) API reload failed (clash maybe not running)"
fi
