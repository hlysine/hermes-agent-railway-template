# Hermes Agent Railway Template

Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) on Railway using the official Nous Research image and s6 process supervision, with the community [Hermes Web UI](https://github.com/nesquena/hermes-webui) baked in as the browser surface in place of the built-in dashboard. A minimal compatibility entrypoint maps variables from existing template deployments before handing control to the upstream `/init` process.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/hermes-agent)

## Railway configuration

The Dockerfile is pinned to this official image:

```text
nousresearch/hermes-agent:v2026.8.3@sha256:16788311e2fa3035456bdc1bafb8ec2b1777db64ebf020af9bb7eb73c3712c9e
```

`v2026.8.3` is Hermes Agent v0.20.0, "The Herald Release." The compatibility entrypoint delegates to this release's upstream entrypoint dispatcher so both normal PID-1 startup and Railway runtimes with an init wrapper are supported.

Use these service settings:

| Setting | Value |
|---|---|
| Start command | `/usr/local/bin/hermes-railway-entrypoint gateway run` |
| Volume mount | `/data` |
| Public port | `8080` (Web UI; leave unexposed if you reach it over Tailscale) |
| Health-check path | `/health` |
| Replicas | `1` |

Railway continues building this GitHub repository so existing template consumers receive update notifications. The compatibility entrypoint only translates legacy environment variables, then executes the official image's `/init`; s6-overlay still supervises the Hermes gateway, and the entrypoint's main-program wrapper supervises the Web UI.

### Variables

```dotenv
PORT=8080
ADMIN_USERNAME=admin
ADMIN_PASSWORD=<generated-password>
```

The compatibility entrypoint maps the existing `ADMIN_USERNAME` and sealed `ADMIN_PASSWORD` values to the official dashboard variables before starting `/init`, and reuses `ADMIN_PASSWORD` as the Web UI login. Existing deployments therefore keep the same login without adding, copying, revealing, or re-entering credentials. It does not modify `config.yaml`. If `ADMIN_PASSWORD` is absent, it generates and logs a password as the previous template did.

For zero-interaction migration, a stable 32-byte dashboard session-signing secret is derived from `ADMIN_PASSWORD`. Derivation supports legacy passwords shorter than Hermes's 16-byte minimum signing-key length while preserving the existing login. After migration, operators may add `HERMES_DASHBOARD_BASIC_AUTH_SECRET` as an independent sealed value containing at least 32 random bytes. Rotating only this secret logs dashboard users out; it does not change the dashboard password or Hermes data. Neither the password nor the derived secret is written to `config.yaml`.

The Dockerfile supplies the remaining variables:

```dotenv
HERMES_HOME=/data/.hermes
HERMES_WRITE_SAFE_ROOT=/data/.hermes
HERMES_GATEWAY_BOOTSTRAP_STATE=running

HERMES_DASHBOARD=0
HERMES_DASHBOARD_HOST=0.0.0.0

HERMES_WEBUI_ENABLED=1
HERMES_WEBUI_SRC=/opt/hermes-webui
HERMES_WEBUI_HOST=0.0.0.0
HERMES_WEBUI_AGENT_DIR=/opt/hermes
HERMES_WEBUI_PYTHON=/opt/hermes/.venv/bin/python
HERMES_WEBUI_SKIP_ONBOARDING=1
HERMES_WEBUI_AUTO_INSTALL=0
HERMES_WEBUI_DEFAULT_WORKSPACE=/data/workspace
```

The entrypoint maps `PORT` to `HERMES_WEBUI_PORT` (and to `HERMES_DASHBOARD_PORT`, for the re-enabled-dashboard path below) at runtime, and `ADMIN_PASSWORD` to `HERMES_WEBUI_PASSWORD`.

Provider credentials, messaging channels, models, skills, profiles, and gateway state are managed through the Web UI and persisted under `/data/.hermes`.

### Web UI

[Hermes Web UI](https://github.com/nesquena/hermes-webui) is a community browser surface for the agent — sessions, chat, workspace file browser, settings. It is baked into this image and started beside the gateway, so it reads and writes the same `$HERMES_HOME`. The built-in `hermes dashboard` is turned off (`HERMES_DASHBOARD=0`) because the two would compete for the same port and the same job; the dashboard's s6 slot is left in place, so setting `HERMES_DASHBOARD=1` plus `HERMES_DASHBOARD_PORT=8081` brings it back without a rebuild.

**Lifecycle.** The Web UI is not an s6 service. The entrypoint's `hermes-railway-main` wrapper starts it as a background child after cont-init (so the UID remap and the PM dependency refresh are already done) and then `exec`s the upstream `main-wrapper.sh`. Two consequences: its logs land on the container's stdout, which is what `railway logs` collects, and the container's fate still follows the gateway — when the gateway exits, the container exits. A Web UI crash restarts itself after 5 s; it does not take the gateway down with it.

**Agent integration.** The UI imports `run_agent.AIAgent` into its own process rather than talking to the gateway over HTTP. `HERMES_WEBUI_AGENT_DIR=/opt/hermes` points it at the agent source in the image, and its `managed_agent_startup` hook runs the agent's own `hermes_bootstrap`, which activates the same PM dependency generation the gateway uses. That is why the UI needs no Python packages of its own: `api/yaml_compat.py` falls back to the `ruamel.yaml` the agent ships (PyYAML is not in the agent's core pins), and `cryptography` already is. Nothing is installed at build or run time, so the UI creates no dependency generation and adds no volume bytes beyond its own state. The `Dockerfile` asserts both halves of that contract at build time, so an agent image that moves `run_agent.py` fails the build instead of shipping a UI whose chat 500s.

**Volume footprint.** The 5 GB volume holds only UI state that is meant to persist:

| Path | Contents |
|---|---|
| `/opt/hermes-webui` | UI source (~14 MB of the ~51 MB checkout; `tests/`, `docs/` and the manifests the runtime does not read are pruned). Image layer, not the volume. |
| `/data/.hermes/webui/` | Sessions, UI settings, workspaces index, chat attachments, auth key. |
| `/data/workspace/` | The workspace file browser's root, i.e. whatever the agent writes there. |

`/data` itself arrives root-owned, so the entrypoint creates `/data/workspace` and opens it mode `1777` rather than chowning it: stage2 may remap the hermes UID to `HERMES_UID` afterwards, and an ownership set before that would be stranded on the old UID. If the directory cannot be created the Web UI falls back to a container-local workspace and the agent's files do not survive a redeploy.

Everything else stays off the volume: the UI's `HOME` is `/opt/data` (container scratch), logs go to stdout rather than `state_dir/bootstrap-<port>.log`, and `HERMES_WEBUI_AUTO_INSTALL=0` keeps the UI from pip-installing anything into a PM generation on the volume. Uploads are capped at 20 MB each (`HERMES_WEBUI_MAX_UPLOAD_MB` to change); attachments accumulate under `/data/.hermes/webui/attachments`, so a heavy attachment workflow is the realistic way to grow this directory.

**Access.** It binds `0.0.0.0:${PORT}` and requires the login password, so it is safe to leave unexposed. For Tailscale-only access, do not attach a public domain to the service — reach the container over the tailnet (or via a Tailscale sidecar on Railway's private network) and keep `PORT` as the listening port. Railway's health check uses `/health`, which is unauthenticated by design; it needs the port to stay bound, so if you unbind the port entirely, clear the health-check path in `railway.toml` as well rather than letting every deploy report unhealthy. On a fresh volume, cont-init seeds the PM dependency generation before either process starts, so the first boot can leave the port unbound — and the health check red — for minutes while it does.

**Updating.** The UI is pinned to a commit in `ARG HERMES_WEBUI_REF` because it imports agent code in-process. Bump it to a newer `nesquena/hermes-webui` commit after reading the upstream changelog, and rebuild. `latest`-style drift here means the UI and the agent image move independently, which is exactly the failure the build-time assertions exist to catch.


### Telegram webhook mode and Serverless

Railway suspends a service after 5 minutes with no outbound packets, and wakes it on inbound traffic. Webhook mode is the right direction here, but three things in the Telegram adapter defeat it:

1. **Idle keepalive probes (30s).** The fallback-IP transport sets `SO_KEEPALIVE` with a 30-second idle probe so a wedged `getUpdates` long-poll errors out instead of hanging. The probe is kernel-level so it logs nothing, and httpcore only prunes expired keepalive connections when a *new* request arrives, so one idle socket from the connect burst is probed forever. Webhook mode has no long-poll, so it buys nothing. Set `HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=true` for the plain `api.telegram.org` path, which injects no socket options.

2. **Periodic identity refresh (300s).** Webhook mode calls `get_me()` every `_BOT_IDENTITY_TTL_SECONDS` — 300s upstream, exactly Railway's idle window — so the silence never completes. No env var or `telegram.extra` key controls it, so the `Dockerfile` patches the constant to 3600s at build time and asserts the substitution matched. BotFather renames then take up to an hour to propagate; restart the gateway to pick one up sooner.

Each refresh opens a fresh TLS connection because `platform_httpx_limits()` sets `keepalive_expiry=2.0`, which is why the network graph shows multi-kilobyte inbound/outbound pairs rather than one small packet. Hermes' own `scale_to_zero` does not help: it arms only when messaging is relay-only or absent and a Fly/NAS suspend lever exists, so a directly-connected platform such as Telegram disqualifies it.

### Dependency storage

PM dependency state under `$HERMES_HOME` splits into recorded selection and rebuildable cache, and the two have opposite durability requirements.

`installs/` holds the recorded selection plus the venv generations it selects, and it stays on the volume. The gateway launches as `python -P -c "… site.addsitedir(os.environ['HERMES_SITE']) …"`; `-P` suppresses site initialization, so the selected generation is the **only** import path and the sealed `/opt/hermes/.venv` is never consulted at runtime. `aiohttp` reaches that generation through the baked `messaging` extra rather than core, so a selection recorded without the baseline loses exactly the `webhook` and `api_server` adapters while the core pins (`httpx`, `psutil`, `packaging`) keep importing.

`cache/uv` (wheel cache) and `cache/partials` (downloader archives) are machine-scoped and genuinely rebuildable, so the entrypoint symlinks them to container-local scratch:

| Path on the volume | Symlink target |
|---|---|
| `/data/.hermes/cache/uv` | `/opt/hermes-deps/cache/uv` |
| `/data/.hermes/cache/partials` | `/opt/hermes-deps/cache/partials` |

Override the destination with `HERMES_DEPS_ROOT`. If it resolves inside `HERMES_HOME` the relocation is skipped with a warning, since the links would nest into themselves. The trade is deliberate: Railway discards the writable layer on every recreate, so the first opt-in install after a deploy re-fetches its wheels instead of reusing the volume's copy. Nothing else pays for it — the uv cache is not an input to a generation's stamp, so an existing generation stays current across recreates.

**Narrowed selections are deleted at boot.** PM builds each later generation from the recorded selection as its baseline, and stage2's refresh re-seeds the image extras only into a volume that has *no* selection — a selection that is present but missing `messaging` survives both. The entrypoint therefore drops any `installs/<key>` whose `facts.json` does not name `messaging`, so stage2 re-seeds the full baseline. This is a repair, not an optimization: a gateway crash-looping on a narrowed selection publishes a fresh ~1 GB generation on every restart, and stage2's collector keeps anything younger than a day, so a single bad day takes the volume from ~260 MB to ~4 GB. Removing the loop removes the growth; `hermes pm gc` reclaims whatever is left once generations age out.

For the memory stack: `httpx==0.28.1`, `packaging==26.0` and `psutil==7.2.2` are core pins and `aiohttp==3.14.3` arrives with `messaging`, so **declare none of them**. Every declared dependency is admitted into the shared environment, and a declaration that forces a fresh selection is how the baseline gets lost. Custom dependencies Hermes does not already ship belong in the plugin's own `pyproject.toml` under `$HERMES_HOME/plugins/<name>/`, with upper bounds — PM refuses a plugin whose requirements cannot resolve against Hermes's exact pins.

To reclaim volume space beyond this, use the supported levers: stage2 already collects generations nothing selects on every container start, `hermes pm gc` removes unreferenced tool-store entries and download partials, and removing the plugin or extra that created a generation (`hermes plugins remove <name>`, `hermes memory off`) is the lever for anything large. If the gateway crash-loops, check memory before blaming dependencies — the gateway, dashboard, TUI and `tui_gateway` together run well past 1 GB resident, and an OOM kill landing mid-generation-build is how a partial environment gets published.


## Upgrading Hermes

Update the pinned release and digest in `Dockerfile` deliberately after reviewing the upstream [release notes](https://github.com/NousResearch/hermes-agent/releases) and validating the new image. Do not use `latest`. Because the template remains GitHub-backed, merging an upgrade to the default branch notifies existing template consumers.

See the official [Hermes Docker documentation](https://hermes-agent.nousresearch.com/docs/user-guide/docker) for image behavior and configuration details.
