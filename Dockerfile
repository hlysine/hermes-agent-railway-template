FROM nousresearch/hermes-agent:latest

USER root

# The official image refuses on-demand dependency installs, so the Hindsight
# memory-provider SDK is baked into the shipped venv instead of being fetched
# on the first agent turn. The range matches the plugin's own declaration.
RUN uv="$(/usr/local/bin/python3 -c 'from pm import installed_package; print(installed_package("uv").binary)')" && \
    "$uv" pip install --no-cache --python /opt/hermes/.venv/bin/python 'hindsight-client>=0.10.1,<1' && \
    /opt/hermes/.venv/bin/python -c 'import hindsight_client'

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/hermes-railway-entrypoint

ENV HERMES_HOME=/data/.hermes \
    HERMES_WRITE_SAFE_ROOT=/data/.hermes \
    HERMES_DASHBOARD=1 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    HERMES_GATEWAY_BOOTSTRAP_STATE=running

ENTRYPOINT ["/usr/local/bin/hermes-railway-entrypoint"]
CMD ["gateway", "run"]
