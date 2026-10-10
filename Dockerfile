FROM nousresearch/hermes-agent:latest

USER root

# Copy the uv binary directly from its official image stage
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Compile the memory stack's runtime deps cleanly into Hermes' environment
RUN uv pip install --python /opt/hermes/.venv/bin/python \
    "aiohttp" \
    "httpx>=0.27,<1" \
    "psutil>=5.9,<9" \
    "packaging>=23,<27"

# Clean up the uv binary to keep your image slim
RUN rm /usr/local/bin/uv

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

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/hermes-railway-entrypoint

ENV HERMES_HOME=/data/.hermes \
    HERMES_WRITE_SAFE_ROOT=/data/.hermes \
    HERMES_DASHBOARD=1 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    HERMES_GATEWAY_BOOTSTRAP_STATE=running

ENTRYPOINT ["/usr/local/bin/hermes-railway-entrypoint"]
CMD ["gateway", "run"]
