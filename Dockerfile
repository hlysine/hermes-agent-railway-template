FROM nousresearch/hermes-agent:latest

USER root

# Webhook mode starts a bot-identity refresh loop that wakes every
# _BOT_IDENTITY_TTL_SECONDS (300s upstream) to call get_me(), so a BotFather
# rename does not break @username routing. That is an outbound Bot API request
# on the exact interval Railway needs to stay silent, so the service can never
# sleep. Widen it to an hour: renames then propagate within an hour, and idle
# stretches become long enough for Railway to suspend. The build fails loudly if
# a future image renames the constant rather than silently losing the patch.
RUN set -eu; \
    f=/opt/hermes/plugins/platforms/telegram/adapter.py; \
    test -f "$f"; \
    sed -i 's/^\([[:space:]]*_BOT_IDENTITY_TTL_SECONDS[[:space:]]*=[[:space:]]*\)300\.0/\13600.0/' "$f"; \
    grep -Eq '_BOT_IDENTITY_TTL_SECONDS[[:space:]]*=[[:space:]]*3600\.0' "$f"

# Hermes Web UI (community project, nesquena/hermes-webui) baked into the same
# image so it shares the gateway's $HERMES_HOME. Pinned to a commit: the UI
# imports run_agent.AIAgent into its own long-lived process, so an unpinned UI
# can drift away from the agent release this template tracks.
#
# It runs on the agent's own interpreter (/opt/hermes/.venv/bin/python) and needs
# no Python dependencies of its own: PyYAML is optional because
# api/yaml_compat.py falls back to the ruamel.yaml the agent ships, and
# cryptography is already a core agent pin. Both resolve whether the process ends
# up on the sealed venv or on the PM generation hermes_bootstrap activates.
# Nothing is installed at build or run time, so the UI adds no PM dependency
# generation and no bytes to the $HERMES_HOME volume beyond its own session state.
#
# Only the runtime surface is kept (server.py, api/, static/, scripts/ plus the
# launcher modules and manifests): ~14 MB of the ~51 MB checkout. Dropping .git
# also makes the UI's self-update checker skip itself, exactly as it does in the
# upstream Docker image where the updater is a no-op for non-checkouts.
ARG HERMES_WEBUI_REF=9e380c2da93463c813cb58dd57f11b75a21626b2
RUN set -eu; \
    curl -fsSL --retry 3 -o /tmp/hermes-webui.tar.gz \
        "https://codeload.github.com/nesquena/hermes-webui/tar.gz/${HERMES_WEBUI_REF}"; \
    mkdir -p /opt/hermes-webui; \
    tar -xzf /tmp/hermes-webui.tar.gz -C /opt/hermes-webui --strip-components=1; \
    rm -f /tmp/hermes-webui.tar.gz; \
    cd /opt/hermes-webui; \
    rm -rf .git tests docs .github nix images *.md start.ps1 docker_init.bash \
        Dockerfile .gitignore \
        docker-compose.yml docker-compose.two-container.yml \
        docker-compose.three-container.yml flake.lock flake.nix pytest.ini \
        eslint.runtime-guard.config.mjs requirements-dev.txt package-lock.json \
        .dockerignore .gitattributes .env.example .env.docker.example; \
    printf '__version__ = %s\n' "'${HERMES_WEBUI_REF}'" > api/_version.py; \
    chown -R root:root /opt/hermes-webui; \
    chmod -R a-w /opt/hermes-webui

# The UI reaches the agent through HERMES_WEBUI_AGENT_DIR, which
# managed_agent_startup.py feeds to the agent's own hermes_bootstrap so the WebUI
# process activates the same PM dependency generation the gateway runs on. Both
# halves of that contract are asserted here: a future agent image that moves
# run_agent.py, or a WebUI snapshot that stops shipping the ruamel fallback,
# fails the build instead of booting a UI whose chat silently 500s.
RUN set -eu; \
    py=/opt/hermes/.venv/bin/python; \
    "$py" -c 'import sys; sys.path.insert(0, "/opt/hermes-webui"); \
from api import yaml_compat; \
import cryptography; \
assert yaml_compat.safe_load(yaml_compat.safe_dump({"tool_progress": "off"})) == {"tool_progress": "off"}; \
print("[hermes-webui] yaml backend:", yaml_compat.BACKEND)'; \
    "$py" -c 'import importlib.util as u, sys; \
sys.path.append("/opt/hermes"); \
assert u.find_spec("run_agent") is not None, "run_agent not importable from /opt/hermes"; \
print("[hermes-webui] agent source: ok")'

# Container marker: the WebUI reads /.within_container to decide it is packaged
# (it relaxes the loopback-only advice and skips host-specific startup probes).
RUN printf '' > /.within_container

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/hermes-railway-entrypoint
COPY --chmod=0755 webui-main.sh /usr/local/bin/hermes-railway-main

ENV HERMES_HOME=/data/.hermes \
    HERMES_WRITE_SAFE_ROOT=/data/.hermes \
    HERMES_GATEWAY_BOOTSTRAP_STATE=running \
    HERMES_DASHBOARD=0 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    HERMES_WEBUI_ENABLED=1 \
    HERMES_WEBUI_SRC=/opt/hermes-webui \
    HERMES_WEBUI_HOST=0.0.0.0 \
    HERMES_WEBUI_AGENT_DIR=/opt/hermes \
    HERMES_WEBUI_PYTHON=/opt/hermes/.venv/bin/python \
    HERMES_WEBUI_SKIP_ONBOARDING=1 \
    HERMES_WEBUI_AUTO_INSTALL=0 \
    HERMES_WEBUI_DEFAULT_WORKSPACE=/data/workspace

ENTRYPOINT ["/usr/local/bin/hermes-railway-entrypoint"]
CMD ["gateway", "run"]
