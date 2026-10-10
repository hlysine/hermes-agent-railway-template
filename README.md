# Hermes Agent Railway Template

Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) on Railway using the official Nous Research image, dashboard, and s6 process supervision. A minimal compatibility entrypoint maps variables from existing template deployments before handing control to the upstream `/init` process.

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
| Public port | `8080` |
| Health-check path | `/api/status` |
| Replicas | `1` |

Railway continues building this GitHub repository so existing template consumers receive update notifications. The compatibility entrypoint only translates legacy environment variables, then executes the official image's `/init`; s6-overlay still supervises the Hermes gateway and dashboard.

### Variables

```dotenv
PORT=8080
ADMIN_USERNAME=admin
ADMIN_PASSWORD=<generated-password>
```

The compatibility entrypoint maps the existing `ADMIN_USERNAME` and sealed `ADMIN_PASSWORD` values to the official dashboard variables before starting `/init`. Existing deployments therefore keep the same login without adding, copying, revealing, or re-entering credentials. It does not modify `config.yaml`. If `ADMIN_PASSWORD` is absent, it generates and logs a password as the previous template did.

For zero-interaction migration, a stable 32-byte dashboard session-signing secret is derived from `ADMIN_PASSWORD`. Derivation supports legacy passwords shorter than Hermes's 16-byte minimum signing-key length while preserving the existing login. After migration, operators may add `HERMES_DASHBOARD_BASIC_AUTH_SECRET` as an independent sealed value containing at least 32 random bytes. Rotating only this secret logs dashboard users out; it does not change the dashboard password or Hermes data. Neither the password nor the derived secret is written to `config.yaml`.

The Dockerfile supplies the remaining official variables:

```dotenv
HERMES_HOME=/data/.hermes
HERMES_WRITE_SAFE_ROOT=/data/.hermes
HERMES_DASHBOARD=1
HERMES_DASHBOARD_HOST=0.0.0.0
HERMES_GATEWAY_BOOTSTRAP_STATE=running
```

The entrypoint maps `PORT` to `HERMES_DASHBOARD_PORT` at runtime.

Provider credentials, messaging channels, models, skills, profiles, and gateway state are managed through the official dashboard and persisted under `/data/.hermes`.

### Telegram webhook mode and Serverless

Railway suspends a service after 5 minutes with no outbound packets, and wakes it on inbound traffic. Webhook mode is the right direction here, but three things in the Telegram adapter defeat it:

1. **Idle keepalive probes (30s).** The fallback-IP transport sets `SO_KEEPALIVE` with a 30-second idle probe so a wedged `getUpdates` long-poll errors out instead of hanging. The probe is kernel-level so it logs nothing, and httpcore only prunes expired keepalive connections when a *new* request arrives, so one idle socket from the connect burst is probed forever. Webhook mode has no long-poll, so it buys nothing. Set `HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=true` for the plain `api.telegram.org` path, which injects no socket options.

2. **Periodic identity refresh (300s).** Webhook mode calls `get_me()` every `_BOT_IDENTITY_TTL_SECONDS` — 300s upstream, exactly Railway's idle window — so the silence never completes. No env var or `telegram.extra` key controls it, so the `Dockerfile` patches the constant to 3600s at build time and asserts the substitution matched. BotFather renames then take up to an hour to propagate; restart the gateway to pick one up sooner.

Each refresh opens a fresh TLS connection because `platform_httpx_limits()` sets `keepalive_expiry=2.0`, which is why the network graph shows multi-kilobyte inbound/outbound pairs rather than one small packet. Hermes' own `scale_to_zero` does not help: it arms only when messaging is relay-only or absent and a Fly/NAS suspend lever exists, so a directly-connected platform such as Telegram disqualifies it.

### Dependency storage

Hermes keeps Python dependency state under `$HERMES_HOME` in two kinds of directory, and only one of them is a cache.

`installs/` holds the recorded PM selection plus the venv generations it selects. It is runtime state: the selection decides which extras the gateway boots onto. The image bakes `all`, `messaging`, `otlp`, `anthropic`, `bedrock`, `azure-identity`, `matrix`, and `google-chat`, records them as the baseline (`--record-selection` at image build), and stage2's dependency refresh restores that baseline into volumes that lost it — but only into a **real directory**. Diverting `installs/` to ephemeral scratch loses the selection, and the next boot runs a generation without the baked extras; the signature failure is `Webhook: aiohttp not installed` / `API Server: aiohttp not installed`, because aiohttp ships in `messaging`. `installs/` therefore stays on the volume, and the entrypoint heals the symlink an earlier version of this template created there.

`cache/uv` (wheel cache) and `cache/partials` (downloader archives) are machine-scoped and genuinely rebuildable, so the entrypoint symlinks them to container-local scratch:

| Path on the volume | Symlink target |
|---|---|
| `/data/.hermes/cache/uv` | `/opt/hermes-deps/cache/uv` |
| `/data/.hermes/cache/partials` | `/opt/hermes-deps/cache/partials` |

Override the destination with `HERMES_DEPS_ROOT` when the container has a larger scratch mount or a second volume. If it resolves inside `HERMES_HOME` the relocation is skipped with a warning, since the links would nest into themselves. Existing cache directories are migrated on the next boot (destination-wins on collision); because the targets live in the container's writable layer, they are discarded on redeploy and re-fetched on demand.

For the memory stack: `httpx==0.28.1`, `packaging==26.0`, and `psutil==7.2.2` are core pins in the Hermes image and `aiohttp==3.14.3` arrives with the baked `messaging` extra, so all four import from the selected generation without any Dockerfile install step. Baking packages into `/opt/hermes/.venv` cannot reach a generation anyway — PM resolves generations from the lock, the recorded extras, and enabled plugin declarations. Custom dependencies belong in the plugin's own `pyproject.toml` under `$HERMES_HOME/plugins/<name>/`; PM admits those declarations into the environment.

If `installs/` still dominates the volume quota, stale generations are the usual cause. Stage2 already collects generations nothing selects on every boot (`collect_generations`); the lever for anything larger is removing the plugin or extra that created it (`hermes plugins remove <name>`, `hermes memory off`), not relocating the directory.

## Upgrading Hermes

Update the pinned release and digest in `Dockerfile` deliberately after reviewing the upstream [release notes](https://github.com/NousResearch/hermes-agent/releases) and validating the new image. Do not use `latest`. Because the template remains GitHub-backed, merging an upgrade to the default branch notifies existing template consumers.

See the official [Hermes Docker documentation](https://hermes-agent.nousresearch.com/docs/user-guide/docker) for image behavior and configuration details.
