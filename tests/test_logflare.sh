#!/usr/bin/env bash
# Exercise turning analytics off: the logs overlay leaves COMPOSE_FILE whether
# or not upstream's run.sh does the job, every other overlay keeps its place,
# and the CLI hands command-level options (cleanup --dry-run and friends)
# through to the command instead of rejecting them.
#
# Nothing here needs Docker or a live stack.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/logflare.sh"

pass=0; fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
    else
        printf 'FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
        fail=$((fail+1))
    fi
}

T="$(mktemp -d)"
export SUPABASE_DIR="$T"
ENV="${T}/.env"
SO_LOG_FILE=""

_reset() {
    rm -f "${T}/run.sh"
    printf 'COMPOSE_FILE=%s\nJWT_SECRET=x\n' "$1" >"$ENV"
}

# --- registered / not registered ---------------------------------------------
_reset "docker-compose.yml:docker-compose.logs.yml:docker-compose.sentinel-logging.yml"
logflare_overlay_registered; check "overlay detected in COMPOSE_FILE" "0" "$?"
_reset "docker-compose.yml:docker-compose.sentinel-logging.yml"
logflare_overlay_registered; check "absent overlay not detected" "1" "$?"
_reset "docker-compose.yml:docker-compose.logs.yml.bak"
logflare_overlay_registered; check "similarly named file is not the overlay" "1" "$?"

# --- removal without run.sh ---------------------------------------------------
_reset "docker-compose.yml:docker-compose.logs.yml:docker-compose.sentinel-logging.yml"
logflare_remove_overlay >/dev/null 2>&1
check "remove without run.sh succeeds" "0" "$?"
check "other overlays keep their order" \
    "docker-compose.yml:docker-compose.sentinel-logging.yml" "$(env_get "$ENV" COMPOSE_FILE)"
check "other variables untouched" "x" "$(env_get "$ENV" JWT_SECRET)"

# --- removal when run.sh does nothing -----------------------------------------
_reset "docker-compose.yml:docker-compose.logs.yml"
printf '#!/bin/sh\nexit 0\n' >"${T}/run.sh"
logflare_remove_overlay >/dev/null 2>&1
check "run.sh that leaves the overlay: still removed" "docker-compose.yml" "$(env_get "$ENV" COMPOSE_FILE)"

# --- removal when run.sh fails ------------------------------------------------
_reset "docker-compose.yml:docker-compose.logs.yml"
printf '#!/bin/sh\nexit 3\n' >"${T}/run.sh"
logflare_remove_overlay >/dev/null 2>&1
check "failing run.sh: removal still succeeds" "0" "$?"
check "failing run.sh: overlay gone" "docker-compose.yml" "$(env_get "$ENV" COMPOSE_FILE)"

# --- run.sh is called with the documented arguments ---------------------------
_reset "docker-compose.yml:docker-compose.logs.yml"
printf '#!/bin/sh\necho "$@" > "%s/argv"\n' "$T" >"${T}/run.sh"
logflare_remove_overlay >/dev/null 2>&1
check "run.sh gets: config remove logs" "config remove logs" "$(cat "${T}/argv" 2>/dev/null)"

# --- already removed: the .env is not rewritten -------------------------------
_reset "docker-compose.yml:docker-compose.sentinel-logging.yml"
before="$(cat "$ENV")"
logflare_remove_overlay >/dev/null 2>&1
check "already disabled: removal is a no-op" "$before" "$(cat "$ENV")"

# --- CLI: command options reach the command -----------------------------------
# Not root (or no installation), so each command stops early - what matters is
# that the global parser no longer rejects the option first.
CLI_DIR="${T}/install"
mkdir -p "$CLI_DIR"
for argv in "cleanup --dry-run" "cleanup -n" "restore --scope=db" "nuke --keep-backups" "logflare status"; do
    # shellcheck disable=SC2086
    out="$(SENTINEL_OPS_DIR="$CLI_DIR" bash "${ROOT}/bin/sentinel-ops" $argv </dev/null 2>&1)"
    check "CLI accepts: ${argv}" "0" "$(grep -c -e 'Unknown option' -e 'Unknown command' <<<"$out")"
done
out="$(SENTINEL_OPS_DIR="$CLI_DIR" bash "${ROOT}/bin/sentinel-ops" --bogus status </dev/null 2>&1)"
check "CLI still rejects an unknown option before the command" "1" "$(grep -c 'Unknown option: --bogus' <<<"$out")"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
