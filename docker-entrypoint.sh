#!/bin/sh
set -eu

dashboard_username="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-${ADMIN_USERNAME:-admin}}"
dashboard_password="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-${ADMIN_PASSWORD:-}}"

if [ -z "$dashboard_password" ]; then
    dashboard_password="$(python -c 'import secrets; print(secrets.token_urlsafe(16))')"
    echo "Generated admin password: $dashboard_password"
fi

dashboard_secret="${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}"
if [ -z "$dashboard_secret" ]; then
    dashboard_secret="$(
        ADMIN_PASSWORD="$dashboard_password" python -c \
            'import base64, hashlib, os; print(base64.b64encode(hashlib.sha256(("hermes-dashboard-session:" + os.environ["ADMIN_PASSWORD"]).encode()).digest()).decode())'
    )"
fi

export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-${PORT:-8080}}"
export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="$dashboard_username"
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$dashboard_password"
export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$dashboard_secret"

# Python dependency state under $HERMES_HOME splits into two kinds.
# installs/ holds the recorded PM selection plus its venv generations:
# runtime state, not a cache. The image's stage2 dependency refresh restores
# the baked extras baseline (all, messaging, otlp, ...) only into a real
# directory there; a diverted selection boots a generation without aiohttp
# ("Webhook/API Server: aiohttp not installed"). So installs/ stays on the
# volume. cache/uv and cache/partials are machine-scoped rebuildable caches,
# so those move to container-local scratch to spare the size-capped volume.
hermes_home="${HERMES_HOME:-/data/.hermes}"
deps_root="${HERMES_DEPS_ROOT:-/opt/hermes-deps}"

# Heal deployments created by the earlier entrypoint, which symlinked
# installs/ to ephemeral scratch and lost the recorded selection.
if [ -L "$hermes_home/installs" ]; then
    echo "Healing $hermes_home/installs: removing symlink left by an earlier" \
         "entrypoint; stage2 will restore the image dependency baseline."
    rm -f "$hermes_home/installs"
fi

relocate_cache() {
    link="$hermes_home/$1"
    target="$deps_root/$1"

    mkdir -p "$target" "$(dirname "$link")" || return 0

    if [ -L "$link" ]; then
        [ "$(readlink "$link")" = "$target" ] || rm -f "$link"
    elif [ -d "$link" ]; then
        find "$link" -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r child; do
            if [ -e "$target/$(basename "$child")" ]; then
                rm -rf "$child"
            else
                mv "$child" "$target/" || true
            fi
        done
        rmdir "$link" 2>/dev/null || true
    fi

    if [ -L "$link" ]; then
        return 0
    fi
    if [ -e "$link" ]; then
        echo "Warning: $link is not a symlink; $1 still counts against the volume quota"
        return 0
    fi
    ln -s "$target" "$link" || echo "Warning: could not link $link"
}

case "$deps_root/" in
    "$hermes_home/" | "$hermes_home"/*)
        echo "Warning: HERMES_DEPS_ROOT is inside HERMES_HOME; leaving caches in place"
        ;;
    *)
        for dep in cache/uv cache/partials; do
            relocate_cache "$dep"
        done
        # The runtime UID is only remapped by the upstream stage2 hook after
        # this script, and that hook chowns nothing under $deps_root, so widen
        # mode bits rather than setting ownership.
        chmod -R a+rwX "$deps_root" 2>/dev/null || true
        ;;
esac

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
