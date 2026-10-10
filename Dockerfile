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

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/hermes-railway-entrypoint

ENV HERMES_HOME=/data/.hermes \
    HERMES_WRITE_SAFE_ROOT=/data/.hermes \
    HERMES_DASHBOARD=1 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    HERMES_GATEWAY_BOOTSTRAP_STATE=running

ENTRYPOINT ["/usr/local/bin/hermes-railway-entrypoint"]
CMD ["gateway", "run"]
