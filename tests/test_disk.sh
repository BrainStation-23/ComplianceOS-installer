#!/usr/bin/env bash
# Exercise the disk-space guards: installer log retention, the free-space
# check before an auto-update, and the container log limits (the overlay and
# the `docker run` arguments). Docker and Compose are replaced with shell
# functions, so nothing here needs a daemon.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/disk.sh"
source "${ROOT}/lib/container_logs.sh"

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
config_set_paths "${T}/root"
config_make_dirs
SO_LOG_FILE=""
G=1073741824

# --- installer logs ----------------------------------------------------------
_build_logs() {
    rm -f "${LOG_DIR}"/*
    touch -d '40 days ago' "${LOG_DIR}/update-app-old.log"
    touch -d '31 days ago' "${LOG_DIR}/cleanup-old.log"
    touch -d '2 days ago'  "${LOG_DIR}/update-app-new.log"
    touch -d '40 days ago' "${LOG_DIR}/not-a-log.txt"
}
_left() { find "$LOG_DIR" -type f | LC_ALL=C sort | xargs -rn1 basename | tr '\n' ' ' | sed 's/ $//'; }

LOG_RETENTION_DAYS=30
_build_logs
logs_prune_installer >/dev/null 2>&1
check "logs past the retention go, recent ones and other files stay" \
    "not-a-log.txt update-app-new.log" "$(_left)"

_build_logs
logs_prune_installer --dry-run >/dev/null 2>&1
check "a dry run removes nothing" "4" "$(_left | wc -w | tr -d ' ')"

_build_logs
SO_LOG_FILE="${LOG_DIR}/cleanup-old.log"
logs_prune_installer >/dev/null 2>&1
check "the log of the run in progress is never removed" \
    "cleanup-old.log not-a-log.txt update-app-new.log" "$(_left)"
SO_LOG_FILE=""

LOG_RETENTION_DAYS=0
_build_logs
logs_prune_installer >/dev/null 2>&1
check "0 keeps every log" "4" "$(_left | wc -w | tr -d ' ')"

LOG_RETENTION_DAYS="a month"
check "a non-numeric retention falls back to 30" "30" "$(logs_retention_days 2>/dev/null)"
LOG_RETENTION_DAYS=30

# --- room for an auto-update -------------------------------------------------
FREE=""
disk_free_bytes() { printf '%s' "$FREE"; }
_disk_update_paths() { printf '%s\n' "$INSTALL_DIR"; }

AUTO_UPDATE_MIN_FREE_GB=5
FREE=$((20*G))
disk_room_for_update >/dev/null
check "plenty free: update" "0" "$?"
FREE=$((2*G))
short="$(disk_room_for_update)"
check "too little free: no update" "1" "$?"
check "and says how much is free where" "2.0 GiB free on ${INSTALL_DIR}" "$short"
FREE=""
disk_room_for_update >/dev/null
check "an unreadable filesystem does not block the update" "0" "$?"
AUTO_UPDATE_MIN_FREE_GB=0; FREE=1
disk_room_for_update >/dev/null
check "0 turns the check off" "0" "$?"
AUTO_UPDATE_MIN_FREE_GB=5

# --- container log limits: docker run --------------------------------------
check "docker run arguments" \
    "--log-driver json-file --log-opt max-size=50m --log-opt max-file=3" \
    "$(container_log_run_args | tr '\n' ' ' | sed 's/ $//')"
CONTAINER_LOG_MAX_SIZE="50 MB"; CONTAINER_LOG_MAX_FILES="0"
check "invalid values fall back to the defaults" \
    "--log-driver json-file --log-opt max-size=50m --log-opt max-file=3" \
    "$(container_log_run_args 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
CONTAINER_LOG_MAX_SIZE="10m"; CONTAINER_LOG_MAX_FILES="5"

# --- container log limits: the Compose overlay -----------------------------
overlay="$(printf 'db\nkong\n\n' | container_logs_render_overlay)"
check "one entry per service" "2" "$(grep -c '^    logging:' <<<"$overlay")"
check "the configured size"   "2" "$(grep -c "max-size: '10m'" <<<"$overlay")"
check "the configured count"  "2" "$(grep -c "max-file: '5'" <<<"$overlay")"
check "json-file, which vector can still read" "2" "$(grep -c 'driver: json-file' <<<"$overlay")"

# Compose reads the service list with every overlay but this one.
mkdir -p "$SUPABASE_DIR"
printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.logs.yml:%s\n' "$CONTAINER_LOGS_OVERLAY" >"${SUPABASE_DIR}/.env"
COMPOSE_ARGS="${T}/compose-args"; SERVICES=$'db\nanalytics\nkong\ndb'
fake_compose() { printf '%s\n' "$@" >"$COMPOSE_ARGS"; printf '%s\n' "$SERVICES"; }
DOCKER_COMPOSE_CMD=(fake_compose)
check "services come back sorted and unique" "analytics db kong" "$(_container_logs_services | tr '\n' ' ' | sed 's/ $//')"
check "the overlay itself is left out of the files Compose reads" "0" "$(grep -c -- "$CONTAINER_LOGS_OVERLAY" "$COMPOSE_ARGS")"
check "the other overlays are not" "1" "$(grep -cx -- 'docker-compose.logs.yml' "$COMPOSE_ARGS")"

printf 'COMPOSE_FILE=docker-compose.yml\n' >"${SUPABASE_DIR}/.env"
container_logs_apply_config >/dev/null 2>&1
check "apply writes the overlay"   "3" "$(grep -c '^    logging:' "${SUPABASE_DIR}/${CONTAINER_LOGS_OVERLAY}")"
check "and registers it"           "docker-compose.yml:${CONTAINER_LOGS_OVERLAY}" "$(env_get "${SUPABASE_DIR}/.env" COMPOSE_FILE)"
container_logs_overlay_registered
check "registered reads as such"   "0" "$?"

before="$(_container_logs_fingerprint)"
container_logs_apply_config >/dev/null 2>&1
check "a re-apply with nothing new changes nothing" "$before" "$(_container_logs_fingerprint)"

SERVICES=""
container_logs_apply_config >/dev/null 2>&1
check "no services from Compose: apply fails" "1" "$?"
check "and leaves the existing overlay alone" "$before" "$(_container_logs_fingerprint)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
