#!/bin/sh
set -eu

dashboard_username="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-${ADMIN_USERNAME:-admin}}"
dashboard_password="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-${ADMIN_PASSWORD:-}}"

if [ -z "$dashboard_password" ]; then
    dashboard_password="$(python -c 'import secrets; print(secrets.token_urlsafe(16))')"
    echo "Generated admin password (dashboard and Web UI login): $dashboard_password"
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

# Hermes Web UI replaces the built-in dashboard as the browser surface, so it
# takes the same PORT and the same credential. The dashboard's own s6 service
# stays disabled (HERMES_DASHBOARD=0 in the Dockerfile); these four exports are
# what a re-enabled dashboard would still need, and the legacy names keep
# existing deployments logging in with the password they already have.
export HERMES_WEBUI_PORT="${HERMES_WEBUI_PORT:-${PORT:-8787}}"
export HERMES_WEBUI_PASSWORD="${HERMES_WEBUI_PASSWORD:-$dashboard_password}"

# PM dependency state under $HERMES_HOME splits in two:
#
#  - installs/ holds the recorded selection plus the venv generations it
#    selects. The gateway launches as `python -P -c "... addsitedir($HERMES_SITE) ..."`,
#    and -P makes the selected generation the ONLY import path — the sealed
#    /opt/hermes/.venv is never consulted. aiohttp ships in the baked `messaging`
#    extra, not core, so a narrowed selection loses exactly the webhook and
#    api_server adapters while core pins keep importing. It stays on the volume.
#
#  - cache/uv and cache/partials are machine-scoped rebuildable caches. They
#    move to container-local scratch so they never touch the volume quota; the
#    cost is a cold re-fetch on first use after each recreate.
hermes_home="${HERMES_HOME:-/data/.hermes}"
deps_root="${HERMES_DEPS_ROOT:-/opt/hermes-deps}"

# Heal deployments created by the earlier entrypoint, which symlinked
# installs/ to ephemeral scratch and lost the recorded selection.
restore_installs() {
    link="$hermes_home/installs"
    [ -L "$link" ] || return 0

    target="$(readlink "$link")"
    case "$target" in
        /*) ;;
        *) target="$deps_root/$target" ;;
    esac
    rm -f "$link"

    if [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        mkdir -p "$link" || return 0
        find "$target" -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r child; do
            [ -e "$link/$(basename "$child")" ] || mv "$child" "$link/" || true
        done
        chown -R hermes:hermes "$link" 2>/dev/null || true
        echo "Restored $link onto the volume from $target"
    else
        echo "Removed stale symlink $link; stage2 restores the dependency baseline"
    fi
}

restore_installs

# A selection that lost the baked extras cannot be repaired in place: PM builds
# each later generation from the recorded selection as its baseline, and stage2
# only re-seeds a volume that has *no* selection. Drop the narrowed keys so
# stage2 re-seeds the image baseline; this is what stops the crash-loop that
# otherwise stacks a fresh ~1 GB generation per restart.
if [ -d "$hermes_home/installs" ]; then
    for facts in "$hermes_home"/installs/*/facts.json; do
        [ -f "$facts" ] || continue
        if ! grep -q '"messaging"' "$facts"; then
            echo "Dropping narrowed dependency selection $(dirname "$facts");" \
                 "stage2 will re-seed the image baseline"
            rm -rf "$(dirname "$facts")"
        fi
    done
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

# The Web UI's workspace is the only directory under the volume root the runtime
# user has to create for itself: /data arrives root-owned, and stage2 chowns
# nothing outside $HERMES_HOME. Prepare it here, world-writable rather than
# chowned, because stage2 may still remap the hermes UID to HERMES_UID after this
# script runs and an ownership set now would strand it on the old UID. Matched
# against /data/* so an override cannot widen permissions elsewhere; the Web UI
# falls back to a container-local workspace if this fails.
webui_workspace="${HERMES_WEBUI_DEFAULT_WORKSPACE:-/data/workspace}"
case "$webui_workspace" in
    /data/*)
        mkdir -p "$webui_workspace" 2>/dev/null \
            && chmod 1777 "$webui_workspace" 2>/dev/null \
            || echo "Warning: could not prepare $webui_workspace; the Web UI will use a container-local workspace"
        ;;
esac

# Upstream's entrypoint-dispatch.sh is not reusable here: it hard-codes
# /opt/hermes/docker/main-wrapper.sh as the main program, and the WebUI needs a
# hook between /init's cont-init (stage2) and that wrapper — the WebUI must start
# after the UID remap and the dependency refresh, and it must inherit the
# container's stdout. So dispatch's two branches are reproduced here with
# hermes-railway-main substituted for main-wrapper; that wrapper exec's
# main-wrapper.sh unchanged once the WebUI is supervised.
if [ "$$" -eq 1 ]; then
    exec /init /usr/local/bin/hermes-railway-main "$@"
fi

echo "[hermes] WARNING: container entrypoint is not PID 1; skipping s6-overlay " \
    "/init and falling back to direct bootstrap. Supervised services are " \
    "unavailable in this runtime, but the requested command will still run." >&2
# /init normally seeds PATH with s6's helpers; the non-PID-1 fallback skips it,
# and hermes-railway-main needs s6-setuidgid to drop the WebUI to hermes.
export PATH="/command:/package/admin/s6/command:${PATH}"
/opt/hermes/docker/stage2-hook.sh
exec /usr/local/bin/hermes-railway-main "$@"
