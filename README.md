# clashctl

A small CLI for controlling a locally-running [mihomo] (Clash.Meta) proxy via its
external-controller API. Persists `mode` and per-group node selections back to the
YAML config so changes survive `systemctl restart` and subscription refresh.

[mihomo]: https://github.com/MetaCubeX/mihomo

---

## Why

mihomo ships as a daemon — its CLI surface is `mihomo -f config.yaml`. For
day-to-day operations (switch node, toggle Rule / Global / Direct, peek at
latency, tail logs) you'd otherwise:

- curl the API by hand and remember the JSON shape, or
- run a full web dashboard (yacd / metacubexd / clash-verge) just to click two
  buttons.

`clashctl` wraps the common ops into a single self-contained Python script.

## Requirements

- A running **mihomo** (or compatible Clash core) instance with
  `external-controller` exposed without a secret — typically `127.0.0.1:9090`.
- A YAML config file mihomo loads from (path configurable via `CLASH_YAML`).
- [**uv**](https://astral.sh/uv) — auto-installed by `install.sh` if missing.

`uv` handles Python ≥ 3.10 and the script's runtime dependencies (`PyYAML`,
`httpx`, `click`) automatically via [PEP 723] inline metadata. You don't set up
a virtualenv or `pip install` anything.

[PEP 723]: https://peps.python.org/pep-0723/

`sudo` is required only for `clashctl logs` (which shells out to `journalctl`).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kvzn/clashctl/main/install.sh | bash
```

Drops a single executable at `~/.local/bin/clashctl`. First invocation resolves
dependencies into the local `uv` cache (a few seconds); every subsequent call is
sub-10 ms.

Behind a firewall — prefix the command with a proxy env var:

```bash
HTTPS_PROXY=http://127.0.0.1:7890 \
  curl -fsSL https://raw.githubusercontent.com/kvzn/clashctl/main/install.sh | bash
```

Custom install path:

```bash
BIN_PATH=/usr/local/bin/clashctl \
  curl -fsSL https://raw.githubusercontent.com/kvzn/clashctl/main/install.sh | bash
```

## Configuration

Two environment variables, both optional:

| Variable     | Default                            | Meaning                              |
| ------------ | ---------------------------------- | ------------------------------------ |
| `CLASH_API`  | `http://127.0.0.1:9090`            | mihomo external-controller endpoint  |
| `CLASH_YAML` | `$HOME/clash/AgentNEO_wLUA.yaml`   | YAML config to write persistence to  |

Export them in your shell rc if the defaults don't fit your layout.

## Commands

### `clashctl info`

Shows version, current routing mode, and listening ports.

```
$ clashctl info
mihomo v1.19.24  meta=True
  mode           rule
  log-level      info
  port           7890
  socks-port     7891
  mixed-port     0
```

### `clashctl groups`

Lists every proxy group together with its currently-selected node.

```
$ clashctl groups
Selector  GLOBAL                 → DIRECT                       (41 nodes)
Selector  ⚡️ 代理                  → 🔄 自动                         (32 nodes)
Selector  📺 流媒体                  → ⚡️ 代理                        (2 nodes)
URLTest   🔄 自动                   → x1.0 香港 - 中转4                (31 nodes)
Selector  🚫 屏蔽                   → REJECT                       (1 nodes)
```

### `clashctl proxies <group>`

Lists every node inside a specific group. The current selection is marked with `→`.

```
$ clashctl proxies "⚡️ 代理"
⚡️ 代理 (Selector) → 🔄 自动
 → 🔄 自动
   x1.0 香港 - 中转1
   x1.0 香港 - 中转2
   x1.0 美西 - 中转2
   ...
```

### `clashctl select <group> <node>`

Switches a group to a specific node. **Persistent** — see [Persistence](#persistence).

```
$ clashctl select "⚡️ 代理" "x1.0 美西 - 中转2"
selected: ⚡️ 代理 → x1.0 美西 - 中转2
```

### `clashctl mode [Rule | Global | Direct]`

Without an argument: prints the current mode. With one: applies it. **Persistent**.

```
$ clashctl mode
rule
$ clashctl mode global
mode set to: global
```

### `clashctl reload`

Tells mihomo to re-read its YAML config from disk (no service restart).

```
$ clashctl reload
reloaded from /home/kvzn/clash/AgentNEO_wLUA.yaml
```

### `clashctl logs [<journalctl args>...]`

Pass-through wrapper around `sudo journalctl -u clash.service`.

```bash
clashctl logs -n 50              # last 50 lines
clashctl logs -f                 # follow new entries
clashctl logs --since "10 min ago"
clashctl logs --grep "REJECT"
```

(Assumes the systemd unit is named `clash.service`. Adjust the constant in the
source if yours is named differently.)

### `clashctl test [<url>]`

Fetches `<url>` (default `https://ipinfo.io/ip`) twice — once through
`127.0.0.1:7890`, once direct — to confirm routing behaviour.

```
$ clashctl test
PROXY : 152.32.196.118
DIRECT: 120.229.60.231
```

Identical IPs typically mean the target hit a `DIRECT` rule (proxy didn't change
the egress). To force proxied egress for testing, `clashctl mode global` first.

### `clashctl delay <group>`

Measures HTTP latency of every node in the group (probe URL:
`https://www.gstatic.com/generate_204`, 3 s timeout per node). Sorted
fastest-first; timed-out nodes appear last with `0 ms`.

```
$ clashctl delay "🔄 自动"
  270 ms   x1.0 香港 - 中转4
  308 ms   x1.0 新加坡 - 中转2
  404 ms   x1.0 韩国 - 中转1
  415 ms   x1.0 美西 - 中转2
  ...
      0 ms   x1.0 莫斯科 - 中转1
```

## Persistence

mihomo's external-controller treats most config changes as **runtime-only** —
they revert on the next service restart. `clashctl` patches the YAML as well:

| Operation                     | Effect now via API | Survives `systemctl restart`? |
| ----------------------------- | ------------------ | ----------------------------- |
| Raw API call (`curl PATCH …`) | ✓                  | ✗ (re-reads YAML)             |
| `clashctl mode X`             | ✓                  | ✓ — writes `mode: X` into YAML |
| `clashctl select G N`         | ✓                  | ✓ — reorders the group's `proxies:` array so `N` is first; mihomo's `cache.db` also remembers the choice |

### Caveat: subscription refresh

If you maintain a refresher script that downloads a fresh YAML from your
subscription provider and overwrites the local config, your custom `mode` and
node selections in YAML are lost. To preserve them, snapshot the **runtime
state** from the running mihomo before activating the new file:

```bash
# inside your refresh script, after downloading $TMP and before mv:
python3 - "$TMP" "$CLASH_API" <<'PY'
import json, urllib.request, yaml, sys
tmp, api = sys.argv[1], sys.argv[2]
cfg = json.loads(urllib.request.urlopen(api+"/configs", timeout=3).read())
pxs = json.loads(urllib.request.urlopen(api+"/proxies", timeout=3).read())["proxies"]
with open(tmp) as f: d = yaml.safe_load(f)
d["mode"] = cfg.get("mode", d.get("mode"))
for pg in d.get("proxy-groups", []):
    if pg.get("type") != "select": continue
    g, ps = pg["name"], pg.get("proxies", [])
    if g in pxs and (now := pxs[g].get("now")) in ps and ps[0] != now:
        ps.remove(now); ps.insert(0, now); pg["proxies"] = ps
with open(tmp, "w") as f:
    yaml.safe_dump(d, f, allow_unicode=True, sort_keys=False)
PY
```

## How it works

The whole tool is a single Python file beginning with a [PEP 723] inline
metadata block:

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "click>=8",
#     "httpx>=0.27",
#     "PyYAML>=6",
# ]
# ///
```

`uv` parses the block, builds (or reuses a cached) ephemeral environment
containing exactly those dependencies, and runs the script in it. Result: a
self-contained Python tool with zero system-wide footprint, no `pip install`,
no `venv`, no `requirements.txt`.

The HTTP layer uses `httpx`; YAML I/O uses `PyYAML`; the CLI is `click`. URL
encoding for proxy group names containing spaces, emoji, or CJK is handled via
`urllib.parse.quote`.

## Uninstall

```bash
rm ~/.local/bin/clashctl
# Optional — also remove uv and its cache:
rm ~/.local/bin/uv ~/.local/bin/uvx
rm -rf ~/.local/share/uv ~/.cache/uv
```

## Project status

Personal tool for single-host setups. Not packaged for general distribution;
not on PyPI. PRs/issues welcome if you find it useful, but no SLA on
responsiveness.
