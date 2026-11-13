#!/usr/bin/env bash
# Exercise the disk report's measurements and the prune targets.
#
# Files are measured for real in a temporary install tree; docker is a shell
# function over a fixture, so nothing here needs a Docker daemon.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/frontend.sh"
source "${ROOT}/lib/images.sh"
source "${ROOT}/lib/backup.sh"
source "${ROOT}/lib/disk.sh"

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
config_set_paths "${T}/opt"
SO_LOG_FILE=""

# --- Units ------------------------------------------------------------------------
check "size: decimal GB"        "1230000000" "$(disk_parse_size 1.23GB)"
check "size: kB"                "12500"      "$(disk_parse_size 12.5kB)"
check "size: bytes"             "0"          "$(disk_parse_size 0B)"
check "size: binary MiB"        "1048576"    "$(disk_parse_size 1MiB)"
check "size: reclaimable form"  "8100000000" "$(disk_parse_size '8.1GB (65%)')"
check "size: ps --size form"    "12300"      "$(disk_parse_size '12.3kB (virtual 1.2GB)')"
check "size: garbage is 0"      "0"          "$(disk_parse_size 'N/A')"

DISK_BAR_FULL="#"; DISK_BAR_EMPTY="."
check "bar: half"               "#####....." "$(disk_bar 50 100 10)"
check "bar: tiny share shows"   "#........." "$(disk_bar 1 1000 10)"
check "bar: nothing"            ".........." "$(disk_bar 0 100 10)"
check "bar: no total"           ".........." "$(disk_bar 5 0 10)"
check "bar: over full is full"  "##########" "$(disk_bar 200 100 10)"
check "pct"                     "25"         "$(_disk_pct 1 4)"

# --- Targets ------------------------------------------------------------------------
check "all = routine targets"   "images logs backups" "$(disk_resolve_targets all | tr '\n' ' ' | sed 's/ $//')"
check "container-logs by name"  "logs container-logs" "$(disk_resolve_targets container-logs logs | tr '\n' ' ' | sed 's/ $//')"
check "duplicates collapse"     "images"              "$(disk_resolve_targets images images)"
disk_resolve_targets bogus >/dev/null 2>&1
check "unknown target fails"    "2" "$?"

# --- Files under INSTALL_DIR -----------------------------------------------------------
mkdir -p "${SUPABASE_DIR}/volumes/db/data/pg_wal" "${SUPABASE_DIR}/volumes/storage/stub" \
         "${SUPABASE_DIR}/volumes/functions" "$APP_DIR" "$LOG_DIR" "$BACKUP_DIR" "$CONFIG_DIR"
head -c 300000 /dev/zero >"${SUPABASE_DIR}/volumes/db/data/base"
head -c 100000 /dev/zero >"${SUPABASE_DIR}/volumes/db/data/pg_wal/000001"
head -c 200000 /dev/zero >"${SUPABASE_DIR}/volumes/storage/stub/file"
for d in 2026-01-01-000000 2026-01-02-000000 2026-01-03-000000 2026-01-04-000000; do
    mkdir -p "${BACKUP_DIR}/${d}"
    head -c 10000 /dev/zero >"${BACKUP_DIR}/${d}/database.sql"
done
head -c 5000 /dev/zero >"${LOG_DIR}/update-app-old.log"
head -c 7000 /dev/zero >"${LOG_DIR}/install-old.log"
head -c 1000 /dev/zero >"${LOG_DIR}/update-app-new.log"
touch -d '60 days ago' "${LOG_DIR}/update-app-old.log" "${LOG_DIR}/install-old.log"
BACKUP_RETENTION_COUNT=2; LOG_RETENTION_DAYS=30

disk_measure_files
check "database counted"           "1" "$(( DISK_DB >= 400000 ))"
check "wal counted within database" "1" "$(( DISK_DB_WAL >= 100000 && DISK_DB_WAL < DISK_DB ))"
check "storage counted"            "1" "$(( DISK_STORAGE >= 200000 ))"
check "backup count"               "4" "$DISK_BACKUP_COUNT"
check "backups past retention"     "2" "$DISK_BACKUPS_EXCESS_COUNT"
check "old logs counted"           "2" "$DISK_LOGS_OLD_COUNT"
check "old log bytes"              "12000" "$DISK_LOGS_OLD"
check "parts never exceed total"   "1" "$(( DISK_DB + DISK_STORAGE + DISK_BACKUPS + DISK_LOGS <= DISK_INSTALL_TOTAL ))"

# The log this run writes is never offered, however old.
SO_LOG_FILE="${LOG_DIR}/install-old.log"
check "current log never pruned"   "${LOG_DIR}/update-app-old.log" "$(_disk_logs_old)"
SO_LOG_FILE=""

SO_DISK_DRY_RUN="true"
disk_prune_logs >/dev/null 2>&1
check "dry run keeps old logs"     "3" "$(find "$LOG_DIR" -name '*.log' | wc -l | tr -d ' ')"
disk_prune_backups >/dev/null 2>&1
check "dry run keeps backups"      "4" "$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
SO_DISK_DRY_RUN="false"
disk_prune_logs >/dev/null 2>&1
check "old logs removed, new kept" "update-app-new.log" "$(cd "$LOG_DIR" && ls)"
disk_prune_backups >/dev/null 2>&1
check "oldest backups removed"     "2026-01-03-000000 2026-01-04-000000" "$(cd "$BACKUP_DIR" && ls | tr '\n' ' ' | sed 's/ $//')"

# --- Docker ---------------------------------------------------------------------------------
# A fixture shaped like `docker images`, `ps --size`, `inspect` and `system df`.
CTRS="${T}/containers"; mkdir -p "$CTRS"
head -c 4000 /dev/zero >"${CTRS}/db.log"
head -c 6000 /dev/zero >"${CTRS}/app.log"
head -c 9000 /dev/zero >"${CTRS}/other.log"
supabase_installed() { return 0; }
supabase_compose() {
    case "$1 ${2:-}" in
        "ps -aq")          printf 'sb-db\n' ;;
        "config --images") printf 'supabase/postgres:15.8\n' ;;
    esac
}
declare -A STATE=([APP_IMAGE]="sentinel-ops:new" [PREVIOUS_APP_IMAGE]="sentinel-ops:prev")
state_get() { printf '%s' "${STATE[$1]:-${2:-}}"; }
docker_daemon_ok() { return 0; }
docker() {
    case "$1" in
        info)   printf '%s' "${T}/docker" ;;
        system) printf 'Images|5GB|2GB (40%%)\nContainers|10MB|0B\nLocal Volumes|1GB|0B\nBuild Cache|3GB|1GB\n' ;;
        images)
            local repo="${*: -1}"
            if [[ " $* " == *" dangling=true "* ]]; then
                printf 'sha256:dang|100MB\n'; return 0
            fi
            case "$repo" in
                sentinel-ops)
                    if [[ "$*" == *'{{.ID}}|{{.Size}}'* ]]; then
                        printf 'sha256:new|500MB\nsha256:prev|500MB\nsha256:old|400MB\n'
                    else
                        printf 'sentinel-ops:new sha256:new\nsentinel-ops:latest sha256:new\nsentinel-ops:prev sha256:prev\nsentinel-ops:old sha256:old\n'
                    fi ;;
                supabase/postgres)
                    if [[ "$*" == *'{{.ID}}|{{.Size}}'* ]]; then
                        printf 'sha256:pg158|1GB\nsha256:pg157|1GB\n'
                    else
                        printf 'supabase/postgres:15.8 sha256:pg158\nsupabase/postgres:15.7 sha256:pg157\n'
                    fi ;;
            esac ;;
        image)  # image inspect -f '{{.Id}}' <ref>
            case "${*: -1}" in
                sentinel-ops:new|sentinel-ops:latest) printf 'sha256:new' ;;
                sentinel-ops:prev) printf 'sha256:prev' ;;
                sentinel-ops:old)  printf 'sha256:old' ;;
                supabase/postgres:15.8) printf 'sha256:pg158' ;;
                supabase/postgres:15.7) printf 'sha256:pg157' ;;
            esac ;;
        ps)
            if [[ " $* " == *" --size "* ]]; then
                printf 'id-db|2MB (virtual 1GB)\nid-app|3MB (virtual 500MB)\nid-other|50MB (virtual 9GB)\n'
            elif [[ " $* " == *" -aq "* ]]; then
                printf 'id-db\nid-app\nid-other\n'
            fi ;;
        inspect)
            local fmt="$3"; shift 3
            local id
            for id in "$@"; do
                case "$fmt" in
                    '{{.Id}}')
                        case "$id" in sb-db|id-db) printf 'id-db\n' ;; sentinel-ops-frontend|id-app) printf 'id-app\n' ;; *) return 1 ;; esac ;;
                    '{{.Image}}') : ;;
                    '{{index .Config.Labels "com.docker.compose.project"}}') printf 'supabase\n' ;;
                    '{{.Name}}|{{.LogPath}}|{{.HostConfig.LogConfig.Type}}')
                        case "$id" in
                            id-db)  printf '/supabase-db|%s/db.log|json-file\n' "$CTRS" ;;
                            id-app) printf '/sentinel-ops-frontend|%s/app.log|json-file\n' "$CTRS" ;;
                        esac ;;
                    *)  case "$id" in
                            id-db)    printf 'id-db|/supabase-db|%s/db.log|json-file|<no value>\n' "$CTRS" ;;
                            id-app)   printf 'id-app|/sentinel-ops-frontend|%s/app.log|json-file|50m\n' "$CTRS" ;;
                            id-other) printf 'id-other|/zoraxy|%s/other.log|json-file|<no value>\n' "$CTRS" ;;
                        esac ;;
                esac
            done ;;
        volume) : ;;
    esac
    return 0
}

disk_measure_docker
check "docker measured"              "true"       "$DISK_DOCKER_OK"
check "df images total"              "5000000000" "$DISK_DF_IMAGES"
check "build cache reclaimable"      "1000000000" "$DISK_BUILD_CACHE_RECLAIM"
check "app: deployed+rollback kept"  "1000000000" "$DISK_IMG_APP_KEPT"
check "app: old build + dangling"    "500000000"  "$DISK_IMG_APP_STALE"
check "app: stale count"             "2"          "$DISK_IMG_APP_STALE_COUNT"
check "supabase: current kept"       "1000000000" "$DISK_IMG_SB_KEPT"
check "supabase: superseded stale"   "1000000000" "$DISK_IMG_SB_STALE"
check "our container layers only"    "5000000"    "$DISK_CTR_RW"
check "our container logs only"      "10000"      "$DISK_CTR_LOGS"
check "other workloads' logs"        "9000"       "$DISK_CTR_LOGS_OTHER"
check "unrotated: ours, not others"  "1"          "$DISK_CTR_LOGS_UNROTATED"
check "largest log listed first"     "sentinel-ops-frontend" "$(head -n1 <<<"$DISK_CTR_LOG_ROWS" | cut -d'|' -f1)"
check "rotation shown"               "not rotated" "$(grep '^supabase-db|' <<<"$DISK_CTR_LOG_ROWS" | cut -d'|' -f3)"

check "ours images not capped"       "3500000000" "$(disk_ours_images)"
check "other docker = rest of df"    "$(( 5000000000 + 10000000 + 1000000000 + 9000 - 3500000000 - 5000000 ))" "$(disk_other_docker)"
DISK_DF_IMAGES=1000
check "ours images capped at df"     "1000"       "$(disk_ours_images)"
check "other docker never negative"  "1"          "$(( $(disk_other_docker) >= 0 ))"
DISK_DF_IMAGES=5000000000

disk_measure_files   # after the prunes above
rows="$(disk_reclaimable_rows)"
check "reclaimable: images row"      "images|2500000000" "$(grep '^images|' <<<"$rows" | cut -d'|' -f1,3)"
check "reclaimable: no logs left"    "0" "$(grep -c '^logs|' <<<"$rows")"
check "reclaimable: container logs"  "container-logs|10000" "$(grep '^container-logs|' <<<"$rows" | cut -d'|' -f1,3)"

# Container logs: only ours, emptied in place, never deleted.
SO_DISK_DRY_RUN="true"
disk_prune_container_logs >/dev/null 2>&1
check "dry run leaves container logs" "4000" "$(stat -c %s "${CTRS}/db.log")"
SO_DISK_DRY_RUN="false"
disk_prune_container_logs >/dev/null 2>&1
check "our logs emptied"             "0 0" "$(stat -c %s "${CTRS}/db.log") $(stat -c %s "${CTRS}/app.log")"
check "other workload's log kept"    "9000" "$(stat -c %s "${CTRS}/other.log")"

# The whole report draws without a database or a real Docker.
DISK_DB_OK="true"
DISK_DB_DATABASES=$'postgres|900000\n_supabase|600000'
DISK_DB_TABLES=$'cron.job_run_details|500000\npublic.events|200000'
DISK_DB_ANALYTICS=550000
out="$(disk_render_all 2>&1)"
check "report: Sentinel Ops share"   "1" "$(grep -c 'Sentinel Ops  ' <<<"$out")"
check "report: names pg_cron history" "1" "$(grep -c 'pg_cron run history' <<<"$out")"
check "report: Logflare size"        "1" "$(grep -c 'Logflare 537.1 KiB' <<<"$out")"
check "report: rotation advice"      "1" "$(grep -c 'max-size' <<<"$out")"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
