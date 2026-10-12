# Hermes Agent Railway Template

## Architecture

Dockerfile wrapper around the official `nousresearch/hermes-agent` image. The
template adds a compatibility entrypoint, the community Hermes Web UI, and a
Railway volume contract.

- `Dockerfile` — pins the upstream image, patches the Telegram identity-refresh TTL, vendors `hermes-webui` into `/opt/hermes-webui`, sets the env contract
- `docker-entrypoint.sh` — legacy variable translation (dashboard basic auth, Web UI password/port), PM dependency-cache relocation, then dispatches to `/init`
- `webui-main.sh` — the container's main program: supervises the Web UI as a background child, then `exec`s the upstream `main-wrapper.sh`
- `railway.toml` — build/start command, `/health` health check, restart policy
- Config and all persistent Hermes state live on the Railway volume at `/data`, with `HERMES_HOME=/data/.hermes` (5 GB quota)

## Key patterns

- The built-in `hermes dashboard` is disabled (`HERMES_DASHBOARD=0`); the Web UI is the browser surface and listens on `PORT`
- Hermes Web UI runs in-process with the agent (`HERMES_WEBUI_AGENT_DIR=/opt/hermes`), on the agent's own interpreter and PM dependency generation — never pip-install anything for it, and never add a Python dependency to the image
- Anything the Web UI or entrypoint writes must stay off the volume unless it is real state: `HOME=/opt/data`, logs to stdout, caches symlinked to `/opt/hermes-deps`
- The Web UI is a background child of the main program, not an s6 service, so its logs reach `railway logs` and the container still exits with the gateway
- Gateway lifecycle is upstream's: `/init` (s6-overlay) runs cont-init/stage2, then the main wrapper exec's `hermes gateway run`
