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

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
