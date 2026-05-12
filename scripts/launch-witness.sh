#!/usr/bin/env bash
# Launch basecamp with the vendored Qt6 QtLocation/QtPositioning plugins
# wired into QT_PLUGIN_PATH so the OSM Map tile provider resolves.
#
# Why this script exists: basecamp's bundled wrapper exports a fixed
# QT_PLUGIN_PATH and clobbers anything we pass in. We have to wedge our
# plugin dir into the env *after* the wrapper has set its own, which means
# bypassing the wrapper. We replicate the wrapper's env and append ours.
#
# Run this in place of `lgs basecamp launch <profile>`.

set -euo pipefail

PROFILE="${1:-alice}"
EXTRA_ARGS=("${@:2}")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# 1. Let lgs build + install the .lgx into the profile dir. We piggyback
#    on its build/install flow but suppress the actual launch so we can
#    do it ourselves with augmented env.
#
#    lgs has no "install-only" mode for `basecamp launch`, but `basecamp
#    install` does the same install step. Use it.
lgs basecamp install >&2

# 2. Resolve basecamp from the scaffold state.
BASECAMP_PIN="$(awk -F\" '/^pin/ {print $2; exit}' \
    < <(sed -n '/\[repos\.basecamp\]/,/^\[/p' scaffold.toml))"
BC_ROOT="$HOME/.cache/logos-scaffold/basecamp/${BASECAMP_PIN}/app-result"
BC_BIN="$BC_ROOT/bin/.LogosBasecamp"   # inner binary, skipping wrapper
WRAPPER="$BC_ROOT/bin/LogosBasecamp"   # for env extraction
test -x "$BC_BIN"   || { echo "basecamp inner binary not found: $BC_BIN" >&2; exit 1; }
test -x "$WRAPPER"  || { echo "basecamp wrapper not found: $WRAPPER" >&2; exit 1; }

# 3. Reproduce the wrapper's env in this shell (LD_LIBRARY_PATH,
#    QT_PLUGIN_PATH, QML2_IMPORT_PATH, DYLD_LIBRARY_PATH, XDG_DATA_DIRS,
#    QT_QPA_PLATFORM). We `source` it but stop short of the final exec by
#    intercepting via a sed-trimmed copy.
TRIMMED_WRAPPER="$(mktemp --suffix=.sh)"
trap 'rm -f "$TRIMMED_WRAPPER"' EXIT
# Drop the trailing `exec ...` line so sourcing just sets env.
sed '$d' "$WRAPPER" > "$TRIMMED_WRAPPER"
# The wrapper expands $DYLD_LIBRARY_PATH (macOS-only) and $LD_LIBRARY_PATH
# unguarded; under `set -u` on Linux this aborts. It also tests
# $WAYLAND_DISPLAY / $QT_QPA_PLATFORM with `[ -n ... ]`, which would also
# trip `set -u` if either is unset. Pre-seed all four to empty so the
# wrapper's append-style assignments work on a fresh login shell.
: "${DYLD_LIBRARY_PATH:=}"
: "${LD_LIBRARY_PATH:=}"
: "${WAYLAND_DISPLAY:=}"
: "${QT_QPA_PLATFORM:=}"
: "${XDG_DATA_DIRS:=}"
# shellcheck source=/dev/null
. "$TRIMMED_WRAPPER"

# 4. Compute QtLocation/QtPositioning paths from the basecamp nixpkgs pin
#    via flake metadata. We need the nixpkgs node specifically — the older
#    awk-grabs-first-rev trick was buggy because the first "rev" in the
#    basecamp lock is logos-capability-module, not nixpkgs. Pin to the
#    nixpkgs node via python's json parser (always available on this host).
BC_LOCK=""
if [ -f /tmp/lb-bc/flake.lock ]; then
    BC_LOCK=/tmp/lb-bc/flake.lock
else
    rm -rf /tmp/lb-bc-launch
    git clone --depth 1 https://github.com/logos-co/logos-basecamp /tmp/lb-bc-launch >&2 2>&1
    BC_LOCK=/tmp/lb-bc-launch/flake.lock
fi
NIXPKGS_REV="$(python3 -c "import json,sys; print(json.load(open('$BC_LOCK'))['nodes']['nixpkgs']['locked']['rev'])")"

# Honor pre-set QTLOC_STORE / QTPOS_STORE so callers without network/build
# permissions (CI, sandboxed shells) can supply already-built store paths
# directly. Falls back to `nix build` to fetch + build from nixpkgs.
if [ -z "${QTLOC_STORE:-}" ]; then
    QTLOC_STORE="$(nix build --no-link --print-out-paths \
        "github:nixos/nixpkgs/${NIXPKGS_REV}#qt6.qtlocation" 2>/dev/null || true)"
fi
if [ -z "${QTPOS_STORE:-}" ]; then
    QTPOS_STORE="$(nix build --no-link --print-out-paths \
        "github:nixos/nixpkgs/${NIXPKGS_REV}#qt6.qtpositioning" 2>/dev/null || true)"
fi
if [ -z "${QTLOC_STORE}" ] || [ -z "${QTPOS_STORE}" ]; then
    echo "could not resolve QtLocation/QtPositioning store paths" >&2
    echo "  QTLOC_STORE='${QTLOC_STORE}'  QTPOS_STORE='${QTPOS_STORE}'" >&2
    exit 1
fi

# 5. Append our plugin/library paths. Qt scans subdirs of each QT_PLUGIN_PATH
#    entry, so `<qtlocation>/lib/qt-6/plugins/{geoservices,position}` etc.
#    are discovered transparently.
export QT_PLUGIN_PATH="${QTLOC_STORE}/lib/qt-6/plugins:${QTPOS_STORE}/lib/qt-6/plugins:${QT_PLUGIN_PATH:-}"
export LD_LIBRARY_PATH="${QTLOC_STORE}/lib:${QTPOS_STORE}/lib:${LD_LIBRARY_PATH:-}"

# 6. Launch the inner binary directly. Pass profile via the same args lgs
#    would have used.
ALICE_HOME="$REPO_ROOT/.scaffold/basecamp/profiles/${PROFILE}"
export XDG_DATA_HOME="$ALICE_HOME/xdg-data"
export XDG_CONFIG_HOME="$ALICE_HOME/xdg-config"
export XDG_CACHE_HOME="$ALICE_HOME/xdg-cache"

echo "launching basecamp for profile $PROFILE (witness wrapper)" >&2
exec "$BC_BIN" "${EXTRA_ARGS[@]}"
