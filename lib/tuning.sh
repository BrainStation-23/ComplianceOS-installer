#!/usr/bin/env bash
# lib/tuning.sh - size Postgres and PostgREST for the host they run on.
#
# Upstream's compose file starts Postgres with the image's defaults
# (shared_buffers 128 MB, work_mem 4 MB, no parallelism tuning, Docker's 64 MB
# /dev/shm) and PostgREST with its default pool, whatever the host has. The
# sizes here are computed from the host's RAM and cores and written to a
# generated Compose overlay registered in COMPOSE_FILE - the same mechanism as
# the storage, auth and logging overlays (docs/DECISIONS.md #28, #32, #34) - so
# `update supabase` never reverts them. See docs/DECISIONS.md #38.
#
# Postgres gets its settings as `-c` arguments appended to upstream's own
# command, read from Compose, so upstream's arguments (its config_file, its
# log level) are kept. A `-c` on the command line wins over postgresql.conf.
# shellcheck shell=bash

DB_TUNING_OVERLAY="docker-compose.sentinel-db-tuning.yml"

# Upstream's db command, used when Compose cannot be asked for it.
DB_TUNING_FALLBACK_COMMAND=(postgres -c config_file=/etc/postgresql/postgresql.conf -c log_min_messages=fatal)

# Non-secret config, persisted in installer.env. DB_TUNING=off removes the
# overlay. The two sizes override what is detected, for a host the database
# shares with something else; empty means detect.
DB_TUNING="auto"
DB_TUNING_MEMORY_MB=""
DB_TUNING_CPUS=""

_db_tuning_overlay_path() { printf '%s/%s' "$SUPABASE_DIR" "$DB_TUNING_OVERLAY"; }

db_tuning_enabled() { [[ "${DB_TUNING:-auto}" != "off" && "${DB_TUNING:-auto}" != "false" ]]; }

# ---------------------------------------------------------------------------
# The host
# ---------------------------------------------------------------------------

# Total RAM in MB, from /proc/meminfo.
_host_memory_mb() {
    local kb
    kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
    [[ "$kb" =~ ^[0-9]+$ ]] || return 1
    printf '%s' $(( kb / 1024 ))
}

_host_cpus() {
    local n
    n="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$n"
}

# Is the disk under SUPABASE_DIR rotational? Prints 1 or 0, nothing when it
# cannot tell (an overlay or network filesystem, no lsblk).
_host_disk_rotational() {
    local src rota
    src="$(df --output=source "$SUPABASE_DIR" 2>/dev/null | tail -n1)"
    [[ "$src" == /dev/* ]] || return 0
    rota="$(lsblk -ndo ROTA "$src" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    [[ "$rota" == "0" || "$rota" == "1" ]] && printf '%s' "$rota"
    return 0
}

# The RAM the sizes are computed from, in MB. MemTotal on a "16 GB" machine
# reads a few hundred MB short (the kernel keeps some), so it is rounded to the
# nearest GiB, and a 16 GB host gets shared_buffers of 4 GB rather than 3.9.
db_tuning_memory_mb() {
    local mb
    if [[ "$DB_TUNING_MEMORY_MB" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s' "$DB_TUNING_MEMORY_MB"; return 0
    fi
    [[ -n "$DB_TUNING_MEMORY_MB" ]] && \
        log_warn "DB_TUNING_MEMORY_MB='${DB_TUNING_MEMORY_MB}' is not a number of MB; detecting the host's RAM." >&2
    mb="$(_host_memory_mb)" || return 1
    if (( mb >= 2048 )); then
        mb=$(( (mb + 512) / 1024 * 1024 ))
    fi
    printf '%s' "$mb"
}

db_tuning_cpus() {
    if [[ "$DB_TUNING_CPUS" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s' "$DB_TUNING_CPUS"; return 0
    fi
    [[ -n "$DB_TUNING_CPUS" ]] && \
        log_warn "DB_TUNING_CPUS='${DB_TUNING_CPUS}' is not a core count; detecting the host's cores." >&2
    _host_cpus
}

_clamp() {
    local v="$1" lo="$2" hi="$3"
    (( v < lo )) && v="$lo"
    (( v > hi )) && v="$hi"
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# The sizes
# ---------------------------------------------------------------------------

# The Postgres settings for a host, as name=value lines in a fixed order.
# db_tuning_postgres_settings <memory-mb> <cpus> <rotational: 1|0|"">
db_tuning_postgres_settings() {
    local mem="$1" cpus="$2" rota="$3" per_gather
    per_gather="$(_clamp $(( cpus / 4 )) 1 4)"
    printf 'max_connections=200\n'
    printf 'shared_buffers=%sMB\n'        $(( mem / 4 > 128 ? mem / 4 : 128 ))
    printf 'effective_cache_size=%sMB\n'  $(( mem * 3 / 4 ))
    printf 'work_mem=%sMB\n'              "$(_clamp $(( mem / 512 )) 4 64)"
    printf 'maintenance_work_mem=%sMB\n'  "$(_clamp $(( mem / 16 )) 64 2048)"
    if (( mem >= 8192 )); then
        printf 'max_wal_size=4GB\n'
        printf 'min_wal_size=1GB\n'
    else
        printf 'max_wal_size=2GB\n'
    fi
    printf 'checkpoint_completion_target=0.9\n'
    # Background workers also run pg_cron, pg_net and logical replication, so
    # there is room for those on top of the parallel query workers.
    printf 'max_worker_processes=%s\n'            $(( cpus + 8 ))
    printf 'max_parallel_workers=%s\n'            "$cpus"
    printf 'max_parallel_workers_per_gather=%s\n' "$per_gather"
    printf 'max_parallel_maintenance_workers=%s\n' "$per_gather"
    # Only a disk that says it spins keeps the spinning-disk costs; cloud and
    # virtual disks that cannot tell are almost always SSD-backed.
    if [[ "$rota" == "1" ]]; then
        printf 'random_page_cost=4\n'
        printf 'effective_io_concurrency=2\n'
    else
        printf 'random_page_cost=1.1\n'
        printf 'effective_io_concurrency=200\n'
    fi
}

# Docker's 64 MB /dev/shm is too small for parallel query, which allocates its
# shared memory there. db_tuning_shm_mb <memory-mb>
db_tuning_shm_mb() { _clamp $(( $1 / 16 )) 256 2048; }

# PostgREST's pool: twice the cores plus headroom, well inside max_connections
# (200), which auth, storage, realtime and the pooler share.
db_tuning_rest_pool() { _clamp $(( $1 * 2 + 8 )) 10 100; }

# How long a request waits for a pooled connection before PostgREST answers
# 504. The default (10s) lets a backlog of blocked agent calls pile up.
DB_TUNING_REST_ACQUISITION_TIMEOUT="5"

# ---------------------------------------------------------------------------
# The overlay
# ---------------------------------------------------------------------------

# COMPOSE_FILE as -f arguments, without this overlay, one per line.
_db_tuning_compose_files() {
    local current entry listed=()
    current="$(env_get "${SUPABASE_DIR}/.env" COMPOSE_FILE 2>/dev/null || true)"
    [[ -n "$current" ]] || current="docker-compose.yml"
    IFS=':' read -r -a listed <<<"$current"
    for entry in "${listed[@]}"; do
        [[ -z "$entry" || "$entry" == "$DB_TUNING_OVERLAY" ]] && continue
        printf '%s\n' -f "$entry"
    done
}

# The stack's Compose config as JSON, read without this overlay so that what
# comes back is upstream's command, not ours.
_db_tuning_compose_json() {
    local files=()
    mapfile -t files < <(_db_tuning_compose_files)
    (cd "$SUPABASE_DIR" && "${DOCKER_COMPOSE_CMD[@]}" --env-file "${SUPABASE_DIR}/.env" \
        "${files[@]}" config --format json 2>>"${SO_LOG_FILE:-/dev/null}")
}

# Upstream's command for the db service, one argument per line, with every
# `-c` this file sets taken out (so ours are the only ones, and re-running
# never stacks them). Falls back to the command upstream has shipped for years.
# _db_tuning_base_command <service> <managed names, one per line>
_db_tuning_base_command() {
    local service="$1" managed="$2" json args=() out=() i name
    json="$(_db_tuning_compose_json 2>/dev/null)" || json=""
    if [[ -n "$json" ]] && command -v jq >/dev/null 2>&1; then
        mapfile -t args < <(jq -r --arg s "$service" \
            '.services[$s].command | if type == "array" then .[] elif type == "string" then . else empty end' \
            <<<"$json" 2>/dev/null)
    fi
    # A string command would need shell word splitting to take apart safely;
    # upstream uses a list, so anything else falls back.
    if (( ${#args[@]} < 2 )); then
        args=("${DB_TUNING_FALLBACK_COMMAND[@]}")
    fi

    for (( i = 0; i < ${#args[@]}; i++ )); do
        if [[ "${args[i]}" == "-c" ]] && (( i + 1 < ${#args[@]} )); then
            name="${args[i+1]%%=*}"
            if grep -qxF "$name" <<<"$managed"; then
                i=$(( i + 1 )); continue
            fi
            out+=("-c" "${args[i+1]}"); i=$(( i + 1 )); continue
        fi
        out+=("${args[i]}")
    done
    printf '%s\n' "${out[@]}"
}

# The services in the stack, one per line ("" when Compose cannot be asked).
_db_tuning_services() {
    local json
    json="$(_db_tuning_compose_json 2>/dev/null)" || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -r '.services | keys[]' <<<"$json" 2>/dev/null
}

_yaml_quote() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }

# Print the overlay for the detected (or configured) host.
db_tuning_render_overlay() {
    local mem cpus rota db_service settings managed base=() arg services
    mem="$(db_tuning_memory_mb)" || { log_error "Could not read the host's RAM." >&2; return 1; }
    cpus="$(db_tuning_cpus)"     || { log_error "Could not read the host's core count." >&2; return 1; }
    rota="$(_host_disk_rotational)"
    db_service="$(supabase_db_service)"
    settings="$(db_tuning_postgres_settings "$mem" "$cpus" "$rota")"
    managed="$(sed 's/=.*//' <<<"$settings")"
    mapfile -t base < <(_db_tuning_base_command "$db_service" "$managed")
    services="$(_db_tuning_services 2>/dev/null || true)"

    printf '# Generated by sentinel-ops (lib/tuning.sh) for %s MB RAM and %s cores.\n' "$mem" "$cpus"
    printf '# Do not edit: it is rewritten on every install, `update supabase` and\n'
    printf '# `repair apply` run. Set DB_TUNING, DB_TUNING_MEMORY_MB and\n'
    printf '# DB_TUNING_CPUS in config/installer.env instead.\n'
    printf 'services:\n'
    printf '  %s:\n' "$db_service"
    printf "    shm_size: '%smb'\n" "$(db_tuning_shm_mb "$mem")"
    printf '    command:\n'
    for arg in "${base[@]}"; do
        printf '      - %s\n' "$(_yaml_quote "$arg")"
    done
    while IFS= read -r arg; do
        [[ -n "$arg" ]] || continue
        printf '      - %s\n' "'-c'"
        printf '      - %s\n' "$(_yaml_quote "$arg")"
    done <<<"$settings"
    # Only name `rest` when the stack has it: an overlay naming a service
    # upstream does not have makes Compose refuse the whole config. When the
    # services cannot be listed, upstream's name is assumed.
    if [[ -z "$services" ]] || grep -qx rest <<<"$services"; then
        printf '  rest:\n'
        printf '    environment:\n'
        printf "      PGRST_DB_POOL: '%s'\n" "$(db_tuning_rest_pool "$cpus")"
        printf "      PGRST_DB_POOL_ACQUISITION_TIMEOUT: '%s'\n" "$DB_TUNING_REST_ACQUISITION_TIMEOUT"
    fi
}

# Everything db_tuning_apply_config can change, as one string - lets a caller
# tell whether a re-apply changed anything (and so needs Postgres restarted).
_db_tuning_fingerprint() {
    printf '%s|%s' \
        "$(env_get "${SUPABASE_DIR}/.env" COMPOSE_FILE 2>/dev/null || true)" \
        "$(cat "$(_db_tuning_overlay_path)" 2>/dev/null || true)"
}

# Write the overlay from the current host and register it, or unregister it
# when DB_TUNING=off. Safe on every install, update and repair: the file is
# only rewritten when its content changes, so an unchanged host restarts
# nothing.
db_tuning_apply_config() {
    local env_file="${SUPABASE_DIR}/.env" overlay tmp
    [[ -f "$env_file" ]] || { log_error "Missing ${env_file}"; return 1; }
    overlay="$(_db_tuning_overlay_path)"

    if ! db_tuning_enabled; then
        compose_file_register "$env_file" "$DB_TUNING_OVERLAY" false
        log_ok "Database sizing off (DB_TUNING=${DB_TUNING}); Postgres runs with the image defaults"
        return 0
    fi

    tmp="$(mktemp)"
    if ! db_tuning_render_overlay >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! cmp -s "$tmp" "$overlay" 2>/dev/null; then
        cat "$tmp" >"$overlay"
    fi
    rm -f "$tmp"
    compose_file_register "$env_file" "$DB_TUNING_OVERLAY" present
    log_ok "Database sized for $(db_tuning_memory_mb) MB RAM and $(db_tuning_cpus) cores ($(db_tuning_summary))"
    return 0
}

# One line: the headline values in the overlay on disk.
db_tuning_summary() {
    local overlay
    overlay="$(_db_tuning_overlay_path)"
    [[ -f "$overlay" ]] || { printf 'no overlay'; return 1; }
    printf 'shared_buffers %s, work_mem %s, PostgREST pool %s' \
        "$(_db_tuning_overlay_value shared_buffers)" \
        "$(_db_tuning_overlay_value work_mem)" \
        "$(sed -nE "s/^ +PGRST_DB_POOL: '([0-9]+)'$/\1/p" "$overlay")"
}

# A setting's value as the overlay on disk has it. _db_tuning_overlay_value <name>
_db_tuning_overlay_value() {
    sed -nE "s/^ +- '$1=([^']*)'$/\1/p" "$(_db_tuning_overlay_path)" 2>/dev/null | head -n1
}

# True when the overlay is on disk and listed in COMPOSE_FILE.
db_tuning_overlay_registered() {
    local current
    [[ -f "$(_db_tuning_overlay_path)" ]] || return 1
    current="$(env_get "${SUPABASE_DIR}/.env" COMPOSE_FILE 2>/dev/null || true)"
    [[ ":${current}:" == *":${DB_TUNING_OVERLAY}:"* ]]
}

# Recreate Postgres and PostgREST so they start with the overlay. Postgres
# restarts once; its data is on a volume and is not touched. Forced, because
# a container Compose thinks is current can still be running older values
# (callers only get here when it is not). --no-deps keeps it to these two.
db_tuning_restart() {
    local services
    services="$(supabase_db_service)"
    supabase_compose config --services 2>/dev/null | grep -qx rest && services="${services} rest"
    run_logged "recreate ${services}" bash -c \
        "$(_supabase_compose_cmd) up -d --no-deps --force-recreate ${services}"
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# A setting as the running Postgres has it, in MB for a memory setting.
_db_tuning_live_mb() {
    db_query "SELECT pg_size_bytes(current_setting('$1')) / 1048576;"
}

# True when the running Postgres has the shared_buffers the overlay sets, i.e.
# it has restarted since the overlay last changed. False when it cannot tell.
db_tuning_live_matches() {
    local want have
    want="$(_db_tuning_overlay_value shared_buffers)"; want="${want%MB}"
    have="$(_db_tuning_live_mb shared_buffers 2>/dev/null || true)"
    [[ -n "$want" && "$have" == "$want" ]]
}

# Status lines comparing the running database with the overlay.
db_tuning_status() {
    local want have name
    if ! db_tuning_enabled; then
        status_line "Sizing" "warn" "Off (DB_TUNING=${DB_TUNING}); Postgres runs with the image defaults"
        return 0
    fi
    if ! db_tuning_overlay_registered; then
        status_line "Sizing" "warn" "Overlay missing; Postgres runs with the image defaults. Run: sentinel-ops repair apply"
        return 0
    fi
    for name in shared_buffers work_mem; do
        want="$(_db_tuning_overlay_value "$name")"; want="${want%MB}"
        have="$(_db_tuning_live_mb "$name" 2>/dev/null || true)"
        if [[ -z "$have" ]]; then
            status_line "$name" "warn" "Could not be read from the database"
        elif [[ "$have" != "$want" ]]; then
            status_line "$name" "warn" "${have} MB running, ${want} MB configured - Postgres has not restarted since. Run: sentinel-ops repair apply"
        else
            status_line "$name" "ok" "${have} MB"
        fi
    done
    return 0
}
