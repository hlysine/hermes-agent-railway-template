#!/bin/sh
# shellcheck shell=sh
# /usr/local/bin/hermes-railway-main — the container's main program.
#
# s6-overlay's /init runs this AFTER cont-init (upstream stage2-hook.sh), so the
# hermes UID remap, $HERMES_HOME seeding and the PM dependency refresh have all
# completed by the time it starts. It launches Hermes Web UI as a background
# child and then exec's the image's own main-wrapper, which keeps the gateway's
# lifecycle byte-for-byte upstream: the container exits when the gateway exits,
# and Railway's restart policy still keys off the gateway.
#
# Why a background child and not an s6-rc service: an s6 service's stdout goes to
# s6-overlay's per-service log directory, which never reaches `railway logs`.
# Inheriting the main program's fds keeps both processes on the container log
# stream. The price is no s6 supervision, so the loop below supplies a minimal
# one: restart on exit with a fixed backoff.

set -eu

# /init scrubs the environment before it hands off to the main program. Rehydrate
# through with-contenv exactly as upstream main-wrapper.sh does, and hand it the
# same guard variable so the wrapper does not re-exec a second time.
if [ -z "${HERMES_MAIN_WRAPPER_ENV_READY:-}" ] && \
   [ -z "${HERMES_HOME:-}" ] && \
   [ -x /command/with-contenv ]; then
    export HERMES_MAIN_WRAPPER_ENV_READY=1
    exec /command/with-contenv sh "$0" "$@"
fi
unset HERMES_MAIN_WRAPPER_ENV_READY

webui_src="${HERMES_WEBUI_SRC:-/opt/hermes-webui}"
webui_python="${HERMES_WEBUI_PYTHON:-/opt/hermes/.venv/bin/python}"

start_webui() {
    case "${HERMES_WEBUI_ENABLED:-}" in
        1|true|TRUE|True|yes|YES|Yes) ;;
        *)
            echo "[webui] disabled (HERMES_WEBUI_ENABLED=${HERMES_WEBUI_ENABLED:-unset})"
            return 0
            ;;
    esac

    if [ ! -f "$webui_src/server.py" ]; then
        echo "[webui] disabled: $webui_src/server.py is missing from the image" >&2
        return 0
    fi

    # HOME anchors every $HOME-relative path the WebUI and the agent resolve
    # (XDG state, lockfiles, the default workspace). Point it at the image's
    # scratch home, not the volume: the WebUI's own persistent state is addressed
    # through HERMES_WEBUI_STATE_DIR ($HERMES_HOME/webui) and nothing else.
    export HOME=/opt/data

    # Drop to the hermes user the way upstream's wrappers do. stage2 may remap
    # that UID to HERMES_UID, and everything the WebUI writes into $HERMES_HOME
    # (sessions, settings, its auth key) must be owned by it or the gateway stops
    # reading its own state directory.
    drop() { [ "$(id -u)" = 0 ] && set -- s6-setuidgid hermes "$@"; exec "$@"; }

    echo "[webui] supervising http://${HERMES_WEBUI_HOST:-127.0.0.1}:${HERMES_WEBUI_PORT:-8787}"
    (
        # cwd only for the WebUI: /opt/hermes-webui is read-only, and the
        # launcher's own cwd is left alone so the gateway still starts where
        # upstream's main-wrapper puts it.
        cd "$HOME" 2>/dev/null || cd /
        while :; do
            rc=0
            # Nested subshell: drop() exec's, so it must not replace the loop.
            ( drop "$webui_python" "$webui_src/server.py" ) || rc=$?
            echo "[webui] server exited (rc=$rc); restarting in 5s"
            sleep 5
        done
    ) &
}

start_webui

exec /opt/hermes/docker/main-wrapper.sh "$@"
