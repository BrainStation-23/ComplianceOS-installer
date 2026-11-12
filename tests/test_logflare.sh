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

# --- settings validation ------------------------------------------------------
for v in 0 1 7 30 365; do
    logflare_valid_retention "$v"; check "retention ${v} accepted" "0" "$?"
done
for v in "" -1 07 1.5 abc "7 "; do
    logflare_valid_retention "$v"; check "retention '${v}' rejected" "1" "$?"
done
LOGFLARE_RETENTION_DAYS="";    check "unset retention is off" "0" "$(logflare_retention_days)"
LOGFLARE_RETENTION_DAYS="14";  check "retention read back" "14" "$(logflare_retention_days)"
LOGFLARE_RETENTION_DAYS="x";   check "bad retention falls back to off" "0" "$(logflare_retention_days 2>/dev/null)"
LOGFLARE_BACKEND="";           check "unset backend is local" "local" "$(logflare_backend)"
LOGFLARE_BACKEND="bigquery";   check "backend read back" "bigquery" "$(logflare_backend)"
LOGFLARE_BACKEND="s3";         check "bad backend falls back to local" "local" "$(logflare_backend 2>/dev/null)"

logflare_valid_remote_url "postgresql://u:p%24ss@db.example:5432/logs?sslmode=require"
check "remote URL accepted" "0" "$?"
logflare_valid_remote_url "postgres://u:p@h/db";    check "postgres:// scheme accepted" "0" "$?"
logflare_valid_remote_url "mysql://u:p@h/db";       check "other scheme rejected" "1" "$?"
logflare_valid_remote_url 'postgresql://u:p$x@h/db'; check "\$ in URL rejected (Compose would interpolate it)" "1" "$?"
logflare_valid_remote_url "postgresql://u:p x@h/db"; check "space in URL rejected" "1" "$?"

printf '{"type": "service_account", "project_id": "p"}\n' >"${T}/key.json"
printf '{"type": "authorized_user"}\n' >"${T}/user.json"
logflare_valid_gcloud_key "${T}/key.json";  check "service-account key accepted" "0" "$?"
logflare_valid_gcloud_key "${T}/user.json"; check "other credential rejected" "1" "$?"
logflare_valid_gcloud_key "${T}/missing";   check "missing key rejected" "1" "$?"

# --- backend overlay ----------------------------------------------------------
check "local backend renders no overlay" "" "$(logflare_render_backend_overlay local)"
out="$(logflare_render_backend_overlay remote)"
check "remote: URL comes from supabase/.env" "1" \
    "$(grep -cxF '      POSTGRES_BACKEND_URL: ${LOGFLARE_REMOTE_BACKEND_URL}' <<<"$out")"
check "remote: no secret written into the overlay" "0" "$(grep -c '://' <<<"$out")"
out="$(logflare_render_backend_overlay bigquery)"
check "bigquery: Postgres URL removed, not blanked" "1" \
    "$(grep -cxF '      POSTGRES_BACKEND_URL: !reset null' <<<"$out")"
check "bigquery: key mounted where Logflare reads it" "1" \
    "$(grep -cxF '      - ./gcloud.json:/opt/app/rel/logflare/bin/gcloud.json:ro,z' <<<"$out")"

if docker compose version >/dev/null 2>&1; then
    # Compose itself must agree: the merged config has no Postgres backend.
    printf 'services:\n  analytics:\n    image: x\n    environment:\n      POSTGRES_BACKEND_URL: postgresql://a@db/_supabase\n      POSTGRES_BACKEND_SCHEMA: _analytics\n' >"${T}/base.yml"
    logflare_render_backend_overlay bigquery >"${T}/bq.yml"
    printf 'GOOGLE_PROJECT_ID=p\nGOOGLE_PROJECT_NUMBER=1\n' >"${T}/bq.env"
    merged="$(cd "$T" && docker compose --env-file bq.env -f base.yml -f bq.yml config 2>&1)"
    check "compose: bigquery merge drops POSTGRES_BACKEND_URL" "0" "$(grep -c POSTGRES_BACKEND <<<"$merged")"
    check "compose: bigquery merge sets the project" "1" "$(grep -c 'GOOGLE_PROJECT_ID: p' <<<"$merged")"
fi

LOGFLARE_BACKEND="remote"
_reset "docker-compose.yml:docker-compose.logs.yml:docker-compose.sentinel-logging.yml"
logflare_apply_backend >/dev/null 2>&1
check "remote without a URL: refused" "1" "$?"
env_set "$ENV" LOGFLARE_REMOTE_BACKEND_URL "postgresql://u:p@h/db"
logflare_apply_backend >/dev/null 2>&1
check "remote: overlay listed after upstream's" \
    "docker-compose.yml:docker-compose.logs.yml:docker-compose.sentinel-logging.yml:docker-compose.sentinel-analytics.yml" \
    "$(env_get "$ENV" COMPOSE_FILE)"
check "remote: overlay written" "0" "$( [[ -f "${T}/docker-compose.sentinel-analytics.yml" ]]; printf '%s' "$?")"

before="$(cat "$ENV")"
logflare_apply_backend >/dev/null 2>&1
check "re-apply: .env unchanged" "$before" "$(cat "$ENV")"

# run.sh config add logs puts upstream's overlay back at the end: ours moves after it.
env_set "$ENV" COMPOSE_FILE "docker-compose.yml:docker-compose.sentinel-analytics.yml:docker-compose.logs.yml"
logflare_apply_backend >/dev/null 2>&1
check "overlay moved back after upstream's" \
    "docker-compose.yml:docker-compose.logs.yml:docker-compose.sentinel-analytics.yml" "$(env_get "$ENV" COMPOSE_FILE)"

# Without upstream's overlay ours would define analytics with no image.
env_set "$ENV" COMPOSE_FILE "docker-compose.yml:docker-compose.sentinel-analytics.yml"
logflare_apply_backend >/dev/null 2>&1
check "not listed while Logflare is off" "docker-compose.yml" "$(env_get "$ENV" COMPOSE_FILE)"

env_set "$ENV" COMPOSE_FILE "docker-compose.yml:docker-compose.logs.yml:docker-compose.sentinel-analytics.yml"
logflare_remove_overlay >/dev/null 2>&1
check "disable takes both overlays out" "docker-compose.yml" "$(env_get "$ENV" COMPOSE_FILE)"

LOGFLARE_BACKEND="local"
env_set "$ENV" COMPOSE_FILE "docker-compose.yml:docker-compose.logs.yml:docker-compose.sentinel-analytics.yml"
logflare_apply_backend >/dev/null 2>&1
check "local: overlay unlisted" "docker-compose.yml:docker-compose.logs.yml" "$(env_get "$ENV" COMPOSE_FILE)"
check "local: overlay file removed" "1" "$( [[ -f "${T}/docker-compose.sentinel-analytics.yml" ]]; printf '%s' "$?")"

LOGFLARE_BACKEND="bigquery"
logflare_apply_backend >/dev/null 2>&1
check "bigquery without a key: refused" "1" "$?"

# --- purge SQL ----------------------------------------------------------------
tables=$'log_events_ab12_cd34\nlog_events_x\nlog_events_bad;drop'
sql="$(_logflare_purge_sql all <<<"$tables")"
check "purge all: one TRUNCATE per table" "2" "$(grep -c '^TRUNCATE _analytics\."log_events_' <<<"$sql")"
check "purge all: odd table names are skipped" "0" "$(grep -c 'drop' <<<"$sql")"
check "purge all: nothing deleted row by row" "0" "$(grep -c DELETE <<<"$sql")"
sql="$(_logflare_purge_sql 7 <<<"$tables")"
check "older-than: a DELETE per table" "2" "$(grep -c 'DELETE FROM' <<<"$sql")"
check "older-than: cutoff in UTC, N days back" "1" \
    "$(grep -m1 -cF "\"timestamp\" < (now() AT TIME ZONE 'UTC') - interval '7 days'" <<<"$sql")"
check "older-than: tables vacuumed" "2" "$(grep -c '^VACUUM' <<<"$sql")"
check "older-than: stale table truncated instead" "2" "$(grep -c 'TRUNCATE' <<<"$sql")"

# logflare_purge through a stubbed docker: lists tables, then sends the SQL.
DB_SUPERUSER="supabase_admin"
_db_container() { printf 'cid'; }
_db_pass() { printf 'pw'; }
docker() {
    local sql; sql="$(cat)"
    printf '%s\n' "$*" >>"${T}/docker-argv"
    if grep -q 'FROM pg_tables' <<<"$sql"; then printf 'log_events_a\nlog_events_b\n'; fi
    printf '%s\n' "$sql" >>"${T}/docker-sql"
}
LOGFLARE_BACKEND="local"; rm -f "${T}/docker-argv" "${T}/docker-sql"
logflare_purge all >/dev/null 2>&1
check "purge: runs" "0" "$?"
check "purge: local goes to _supabase as the superuser" "2" \
    "$(grep -c -- '-U supabase_admin -d _supabase' "${T}/docker-argv")"
check "purge: listed tables truncated" "2" "$(grep -c '^TRUNCATE' "${T}/docker-sql")"

LOGFLARE_BACKEND="remote"; rm -f "${T}/docker-argv" "${T}/docker-sql"
env_set "$ENV" LOGFLARE_REMOTE_BACKEND_URL "postgresql://u:secret@h/db"
logflare_purge 3 >/dev/null 2>&1
check "purge: remote runs" "0" "$?"
check "purge: remote URL never on a command line" "0" "$(grep -c secret "${T}/docker-argv")"
check "purge: remote uses the URL from the environment" "2" "$(grep -c -- '-e SO_LOGFLARE_URL' "${T}/docker-argv")"

LOGFLARE_BACKEND="bigquery"
logflare_purge all >/dev/null 2>&1
check "purge: refused for bigquery" "1" "$?"
unset -f docker

# --- retention timer ----------------------------------------------------------
SO_BIN_LINK="/usr/local/bin/sentinel-ops"; INSTALL_DIR="/opt/sentinel-ops"
check "timer service runs prune" "1" \
    "$(_logflare_retention_unit_text service | grep -cxF 'ExecStart=/usr/local/bin/sentinel-ops --dir /opt/sentinel-ops --yes logflare prune')"
check "timer is daily" "1" "$(_logflare_retention_unit_text timer | grep -cx 'OnCalendar=daily')"
LOGFLARE_BACKEND="local";    LOGFLARE_RETENTION_DAYS="7"
logflare_retention_wanted;   check "timer wanted with days set" "0" "$?"
LOGFLARE_RETENTION_DAYS="0"
logflare_retention_wanted;   check "no timer when retention is off" "1" "$?"
LOGFLARE_BACKEND="bigquery"; LOGFLARE_RETENTION_DAYS="7"
logflare_retention_wanted;   check "no timer for bigquery" "1" "$?"
LOGFLARE_BACKEND="local"

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
