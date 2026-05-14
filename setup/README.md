# setup/ — server-side bootstrap for a clash host

This directory holds the pieces needed to provision a fresh Linux host as a
clash (mihomo) proxy server, *not* just the client-side CLI. If you only want
the `clashctl` tool, use the root `install.sh` instead.

## Files

| File | Purpose |
| --- | --- |
| `install.sh`     | One-shot bootstrap: mihomo binary + systemd unit + daily refresh cron + clashctl. |
| `clash.service`  | systemd unit template. Placeholders `__CLASH_USER__` / `__CLASH_DIR__` / `__CLASH_CONFIG__` are substituted by `install.sh`. |
| `refresh.sh`     | Daily subscription refresher with state preservation. Reads `SUBSCRIPTION_URL` from `~/.config/clash/subscription.env`. |

## One-shot install

```bash
SUBSCRIPTION_URL="https://your-provider/.../clash.yaml" \
  curl -fsSL https://raw.githubusercontent.com/kvzn/clashctl/main/setup/install.sh | bash
```

Behind a proxy (e.g. when the host is in China and can't reach `github.com`
directly):

```bash
SUBSCRIPTION_URL="https://..." \
PROXY="http://127.0.0.1:7890" \
  curl -fsSL https://raw.githubusercontent.com/kvzn/clashctl/main/setup/install.sh | bash
```

Optional overrides:

| Env | Default | Meaning |
| --- | --- | --- |
| `CLASH_DIR`     | `$HOME/clash`     | Working dir; mihomo, yaml, cache.db live here. |
| `CLASH_USER`    | `$USER`           | User the systemd service runs as. |
| `CLASH_CONFIG`  | `config.yaml`     | YAML filename inside `CLASH_DIR`. |
| `PROXY`         | _none_            | HTTP proxy used during downloads. |

## What it does

1. Downloads the latest mihomo release for `linux-amd64` / `linux-arm64` into `CLASH_DIR/mihomo`.
2. Writes `~/.config/clash/subscription.env` (mode `0600`) holding `SUBSCRIPTION_URL`.
3. Installs `refresh.sh` into `CLASH_DIR/` and runs it once to seed the initial yaml.
4. Renders `clash.service` from the template into `/etc/systemd/system/`, then `daemon-reload` + `enable --now`.
5. Installs a daily cron at 05:00 running `refresh.sh` and logging to `CLASH_DIR/refresh.log`.
6. Installs `clashctl` via the root installer.

Re-running `install.sh` upgrades mihomo, re-renders the unit, and reinstalls
the refresh script. Existing yaml, cache.db, and the user-edited subscription
env are left alone.

## What it explicitly does *not* do

- No host-specific tweaks (WiFi power-save fixes, NIC driver workarounds, BIOS
  reg-domain hacks). Those belong in a per-host config repo.
- No secret management beyond `chmod 600` on the env file. `SUBSCRIPTION_URL`
  is a bearer token — treat it like one.
- No firewall / DNS / TUN configuration.

## Uninstall

```bash
sudo systemctl disable --now clash.service
sudo rm /etc/systemd/system/clash.service
crontab -l | grep -v "/refresh.sh" | crontab -
rm -rf "$CLASH_DIR"      # CAUTION: deletes mihomo, yaml, cache.db
rm    "$HOME/.config/clash/subscription.env"
```

(Removing `clashctl` itself is documented in the root [README](../README.md#uninstall).)
