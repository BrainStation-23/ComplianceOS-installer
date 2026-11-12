#!/usr/bin/env bash
# Exercise the Postgres/PostgREST sizing overlay: the sizes for a fake host,
# the command it appends to, idempotence, overrides and DB_TUNING=off.
#
# The host (RAM, cores, disk) and Compose are replaced with shell functions,
# so nothing here needs Docker or a live stack.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/supabase.sh"
source "${ROOT}/lib/storage.sh"
source "${ROOT}/lib/tuning.sh"

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
OVERLAY="${T}/${DB_TUNING_OVERLAY}"

# A fake 16 GB / 16-core host with an SSD. MemTotal on such a machine reads a
# few hundred MB short of 16384.
HOST_MB=16006; HOST_CPUS=16; HOST_ROTA=0
_host_memory_mb()       { printf '%s' "$HOST_MB"; }
_host_cpus()            { printf '%s' "$HOST_CPUS"; }
_host_disk_rotational() { printf '%s' "$HOST_ROTA"; }
supabase_db_service()   { printf 'db'; }

# Compose: the stack's config, as `config --format json` prints it. Without
# jq the base command falls back to upstream's, which is the same list.
COMPOSE_JSON='{"services":{"db":{"command":["postgres","-c","config_file=/etc/postgresql/postgresql.conf","-c","log_min_messages=fatal"]},"rest":{},"auth":{}}}'
_db_tuning_compose_json() { printf '%s' "$COMPOSE_JSON"; }

_reset() {
    printf 'COMPOSE_FILE=docker-compose.yml\nJWT_SECRET=x\n' >"$ENV"
    rm -f "$OVERLAY"
    DB_TUNING="auto"; DB_TUNING_MEMORY_MB=""; DB_TUNING_CPUS=""
    HOST_MB=16006; HOST_CPUS=16; HOST_ROTA=0
}

has() { grep -cxF -- "$1" "$OVERLAY"; }

# --- the sizes ------------------------------------------------------------------
_reset
check "16 GB host: MemTotal rounds to 16384 MB" "16384" "$(db_tuning_memory_mb)"
HOST_MB=1900
check "small host: not rounded" "1900" "$(db_tuning_memory_mb)"
_reset

settings="$(db_tuning_postgres_settings 16384 16 0)"
for want in max_connections=200 shared_buffers=4096MB effective_cache_size=12288MB \
            work_mem=32MB maintenance_work_mem=1024MB max_wal_size=4GB min_wal_size=1GB \
            checkpoint_completion_target=0.9 max_worker_processes=24 max_parallel_workers=16 \
            max_parallel_workers_per_gather=4 max_parallel_maintenance_workers=4 \
            random_page_cost=1.1 effective_io_concurrency=200; do
    check "16 GB/16 cores: ${want}" "1" "$(grep -cxF "$want" <<<"$settings")"
done
check "16 cores: PostgREST pool 40" "40" "$(db_tuning_rest_pool 16)"
check "16 GB: /dev/shm 1 GB" "1024" "$(db_tuning_shm_mb 16384)"

small="$(db_tuning_postgres_settings 2048 2 0)"
check "2 GB: shared_buffers 512MB"  "1" "$(grep -cxF shared_buffers=512MB <<<"$small")"
check "2 GB: work_mem 4MB"          "1" "$(grep -cxF work_mem=4MB <<<"$small")"
check "2 GB: maintenance 128MB"     "1" "$(grep -cxF maintenance_work_mem=128MB <<<"$small")"
check "2 GB: max_wal_size 2GB"      "1" "$(grep -cxF max_wal_size=2GB <<<"$small")"
check "2 cores: one worker per gather" "1" "$(grep -cxF max_parallel_workers_per_gather=1 <<<"$small")"
check "2 cores: pool floor 12" "12" "$(db_tuning_rest_pool 2)"
check "2 GB: shm floor 256" "256" "$(db_tuning_shm_mb 2048)"
check "tiny host: shared_buffers floor" "1" "$(grep -cxF shared_buffers=128MB <<<"$(db_tuning_postgres_settings 400 1 0)")"

big="$(db_tuning_postgres_settings 262144 64 0)"
check "256 GB: work_mem capped at 64MB"  "1" "$(grep -cxF work_mem=64MB <<<"$big")"
check "256 GB: maintenance capped at 2GB" "1" "$(grep -cxF maintenance_work_mem=2048MB <<<"$big")"
check "64 cores: pool capped at 100" "100" "$(db_tuning_rest_pool 64)"
check "256 GB: shm capped at 2 GB" "2048" "$(db_tuning_shm_mb 262144)"

hdd="$(db_tuning_postgres_settings 16384 16 1)"
check "spinning disk: random_page_cost 4" "1" "$(grep -cxF random_page_cost=4 <<<"$hdd")"
unknown="$(db_tuning_postgres_settings 16384 16 '')"
check "unknown disk: treated as SSD" "1" "$(grep -cxF random_page_cost=1.1 <<<"$unknown")"

# --- the overlay on the fake 16 GB / 16-core host -----------------------------------
_reset
db_tuning_apply_config >/dev/null 2>&1
check "overlay written" "present" "$([[ -f "$OVERLAY" ]] && printf present || printf absent)"
check "overlay registered" "docker-compose.yml:${DB_TUNING_OVERLAY}" "$(env_get "$ENV" COMPOSE_FILE)"
check "reported registered" "yes" "$(db_tuning_overlay_registered && printf yes || printf no)"
check "db service"   "1" "$(has '  db:')"
check "shm_size"     "1" "$(has "    shm_size: '1024mb'")"
check "upstream command kept: postgres"     "1" "$(has "      - 'postgres'")"
check "upstream command kept: config_file"  "1" "$(has "      - 'config_file=/etc/postgresql/postgresql.conf'")"
check "upstream command kept: log level"    "1" "$(has "      - 'log_min_messages=fatal'")"
check "postgres is the first argument" "      - 'postgres'" "$(grep -m1 -- "^      - " "$OVERLAY")"
check "shared_buffers 4 GB"       "1" "$(has "      - 'shared_buffers=4096MB'")"
check "effective_cache_size 12 GB" "1" "$(has "      - 'effective_cache_size=12288MB'")"
check "work_mem 32 MB"            "1" "$(has "      - 'work_mem=32MB'")"
check "max_connections 200"       "1" "$(has "      - 'max_connections=200'")"
check "every setting is a -c" \
    "$(grep -c "^      - '[a-z_]*=" "$OVERLAY")" "$(grep -c "^      - '-c'$" "$OVERLAY")"
check "PostgREST pool 40"         "1" "$(has "      PGRST_DB_POOL: '40'")"
check "PostgREST acquisition timeout" "1" "$(has "      PGRST_DB_POOL_ACQUISITION_TIMEOUT: '5'")"
check "summary" "shared_buffers 4096MB, work_mem 32MB, PostgREST pool 40" "$(db_tuning_summary)"

# Idempotent: a second run produces the same files, so nothing restarts.
first="$(cat "$OVERLAY")"; first_env="$(cat "$ENV")"
before="$(_db_tuning_fingerprint)"
db_tuning_apply_config >/dev/null 2>&1
check "second run: same overlay" "$first" "$(cat "$OVERLAY")"
check "second run: same .env" "$first_env" "$(cat "$ENV")"
check "second run: same fingerprint" "$before" "$(_db_tuning_fingerprint)"

# Our own -c settings never stack: an upstream command that already sets one
# of them (or a config read back with ours in it) keeps only ours.
if command -v jq >/dev/null 2>&1; then
    COMPOSE_JSON='{"services":{"db":{"command":["postgres","-c","config_file=/etc/postgresql/postgresql.conf","-c","shared_buffers=128MB","-c","log_min_messages=fatal"]},"rest":{}}}'
    db_tuning_apply_config >/dev/null 2>&1
    check "upstream's shared_buffers replaced, not doubled" "1" "$(grep -c "shared_buffers=" "$OVERLAY")"
    check "and upstream's other arguments kept" "1" "$(has "      - 'log_min_messages=fatal'")"
    COMPOSE_JSON='{"services":{"db":{"command":["postgres","-c","config_file=/etc/postgresql/postgresql.conf"]},"auth":{}}}'
    db_tuning_apply_config >/dev/null 2>&1
    check "no rest service: not named" "0" "$(has '  rest:')"
    COMPOSE_JSON='{"services":{"db":{"command":["postgres","-c","config_file=/etc/postgresql/postgresql.conf","-c","log_min_messages=fatal"]},"rest":{},"auth":{}}}'
else
    printf 'skip  base-command parsing (jq not installed)\n'
fi
mapfile -t base < <(_db_tuning_base_command db "$(printf 'shared_buffers\nwork_mem\n')")
check "base command" "postgres -c config_file=/etc/postgresql/postgresql.conf -c log_min_messages=fatal" "${base[*]}"

# A resized host rewrites the overlay and changes the fingerprint.
_reset
db_tuning_apply_config >/dev/null 2>&1
before="$(_db_tuning_fingerprint)"
HOST_MB=32368; HOST_CPUS=32
db_tuning_apply_config >/dev/null 2>&1
check "resized host: shared_buffers 8 GB" "1" "$(has "      - 'shared_buffers=8192MB'")"
check "resized host: fingerprint changes" "changed" \
    "$([[ "$before" != "$(_db_tuning_fingerprint)" ]] && printf changed || printf same)"

# --- overrides -------------------------------------------------------------------
_reset
DB_TUNING_MEMORY_MB="8192"; DB_TUNING_CPUS="4"
db_tuning_apply_config >/dev/null 2>&1
check "memory override" "1" "$(has "      - 'shared_buffers=2048MB'")"
check "cpu override" "1" "$(has "      - 'max_parallel_workers=4'")"
check "cpu override: pool" "1" "$(has "      PGRST_DB_POOL: '16'")"
DB_TUNING_MEMORY_MB="8G"; DB_TUNING_CPUS="many"
check "bad memory override falls back to the host" "16384" "$(db_tuning_memory_mb 2>/dev/null)"
check "bad cpu override falls back to the host" "16" "$(db_tuning_cpus 2>/dev/null)"

# --- alongside the other overlays, and off ---------------------------------------
_reset
env_set "$ENV" COMPOSE_FILE "docker-compose.yml:docker-compose.logs.yml"
storage_apply_config >/dev/null 2>&1
db_tuning_apply_config >/dev/null 2>&1
settled="$(env_get "$ENV" COMPOSE_FILE)"
check "registered after the others" \
    "docker-compose.yml:docker-compose.logs.yml:${STORAGE_OVERLAY}:${DB_TUNING_OVERLAY}" "$settled"
storage_apply_config >/dev/null 2>&1; db_tuning_apply_config >/dev/null 2>&1
check "repeated applies do not reorder" "$settled" "$(env_get "$ENV" COMPOSE_FILE)"

DB_TUNING="off"
db_tuning_apply_config >/dev/null 2>&1
check "off: unregistered, the others kept" \
    "docker-compose.yml:docker-compose.logs.yml:${STORAGE_OVERLAY}" "$(env_get "$ENV" COMPOSE_FILE)"
check "off: reported unregistered" "no" "$(db_tuning_overlay_registered && printf yes || printf no)"
DB_TUNING="auto"
db_tuning_apply_config >/dev/null 2>&1
check "back on: registered again" "yes" "$(db_tuning_overlay_registered && printf yes || printf no)"

# A reset COMPOSE_FILE (the update/repair drift case) is detected and fixed.
env_set "$ENV" COMPOSE_FILE "docker-compose.yml"
check "dropped registration is detected" "no" "$(db_tuning_overlay_registered && printf yes || printf no)"
before="$(_db_tuning_fingerprint)"
db_tuning_apply_config >/dev/null 2>&1
check "re-apply restores it and reports a change" "yes|changed" \
    "$(db_tuning_overlay_registered && printf yes || printf no)|$([[ "$before" != "$(_db_tuning_fingerprint)" ]] && printf changed || printf same)"

# --- the running database ------------------------------------------------------------
_reset
db_tuning_apply_config >/dev/null 2>&1
LIVE_SB=4096; LIVE_WM=32
_db_tuning_live_mb() { case "$1" in shared_buffers) printf '%s' "$LIVE_SB" ;; work_mem) printf '%s' "$LIVE_WM" ;; esac; }
check "live matches" "yes" "$(db_tuning_live_matches && printf yes || printf no)"
out="$(db_tuning_status 2>&1)"
check "status ok" "0" "$(grep -c '!' <<<"$out")"
LIVE_SB=128
check "live on image defaults: no match" "no" "$(db_tuning_live_matches && printf yes || printf no)"
out="$(db_tuning_status 2>&1)"
check "status says it has not restarted" "1" "$(grep -c '128 MB running, 4096 MB configured' <<<"$out")"
LIVE_SB=""
check "unreadable: no match" "no" "$(db_tuning_live_matches && printf yes || printf no)"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
