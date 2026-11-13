#!/usr/bin/env bash
# lib/disk.sh - where the disk goes, and what can safely be given back.
#
# `sentinel-ops disk` answers three questions:
#
#   1. How full is the disk, and how much of that is Sentinel Ops, how much is
#      other Docker workloads, and how much is the rest of the system?
#   2. Inside Sentinel Ops: database, Storage files, backups, logs, images,
#      container logs - which one is big?
#   3. What can be reclaimed safely, and how much would that free?
#
# Measuring (disk_measure_*) and drawing (disk_render_*) are kept apart: every
# measurement lands in a DISK_* global, so the report can be tested without a
# Docker daemon or a database. Pruning (disk_prune_*) reuses lib/images.sh for
# images and lib/backup.sh for backup retention; the only new removals are
# old installer logs and the JSON log files of this stack's own containers.
# See docs/DECISIONS.md #34.
# shellcheck shell=bash

# Non-secret config, persisted in installer.env: installer logs older than
# this many days are what `disk prune logs` removes.
LOG_RETENTION_DAYS="30"

# Set by `disk prune --dry-run`: report, remove nothing. Shared with
# lib/images.sh so one flag covers every target.
SO_DISK_DRY_RUN="false"

# Every target `disk prune` accepts, in the order `all` runs them.
# container-logs is deliberately not part of `all`: it throws away the only
# record of what a service printed, so it has to be asked for by name.
DISK_PRUNE_TARGETS=(images logs backups)
DISK_PRUNE_TARGETS_EXPLICIT=(container-logs)

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------

# Docker prints sizes for people ("1.23GB", "512MB", "8.1GB (65%)", "0B").
# Convert one to bytes. Docker's own units are decimal (kB/MB/GB); binary
# units (KiB/MiB/GiB) are accepted too. Anything unreadable is 0.
disk_parse_size() {
    awk -v s="$1" 'BEGIN {
        sub(/^[[:space:]]+/, "", s); sub(/[[:space:]].*$/, "", s)
        if (match(s, /^[0-9]+(\.[0-9]+)?/) == 0) { print 0; exit }
        n = substr(s, 1, RLENGTH); u = substr(s, RLENGTH + 1)
        m["B"] = 1; m[""] = 1
        m["kB"] = 1e3; m["KB"] = 1e3; m["MB"] = 1e6; m["GB"] = 1e9; m["TB"] = 1e12
        m["KiB"] = 1024; m["MiB"] = 1048576; m["GiB"] = 1073741824; m["TiB"] = 1099511627776
        if (!(u in m)) { print 0; exit }
        printf "%.0f\n", n * m[u]
    }'
}

# Bytes on disk under a path, 0 when it does not exist or cannot be read.
_disk_du() {
    local p="$1" n
    [[ -e "$p" ]] || { printf '0'; return 0; }
    n="$(du -sb "$p" 2>/dev/null | cut -f1 || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# Sum stdin, one integer per line.
_disk_sum() { awk '{ s += $1 } END { printf "%.0f\n", s }'; }

_disk_max0() { (( $1 > 0 )) && printf '%s' "$1" || printf '0'; }

# Percentage of part in total, rounded down, 0 when total is 0.
_disk_pct() { (( $2 > 0 )) && printf '%s' $(( $1 * 100 / $2 )) || printf '0'; }

# ---------------------------------------------------------------------------
# Measurement: files under INSTALL_DIR
# ---------------------------------------------------------------------------

DISK_INSTALL_TOTAL=0
DISK_DB=0; DISK_DB_WAL=0; DISK_STORAGE=0; DISK_FUNCTIONS=0; DISK_SUPABASE_OTHER=0
DISK_BACKUPS=0; DISK_BACKUP_COUNT=0; DISK_BACKUPS_EXCESS=0; DISK_BACKUPS_EXCESS_COUNT=0
DISK_LOGS=0; DISK_LOGS_OLD=0; DISK_LOGS_OLD_COUNT=0
DISK_APP_CHECKOUT=0; DISK_INSTALL_OTHER=0

# Backup directories past BACKUP_RETENTION_COUNT, oldest first - exactly the
# ones backup_prune_local would remove.
_disk_backups_excess() {
    local count
    count="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)"
    (( count > BACKUP_RETENTION_COUNT )) || return 0
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort \
        | head -n "$(( count - BACKUP_RETENTION_COUNT ))" || true
}

# Installer logs older than LOG_RETENTION_DAYS, never the one this run writes.
_disk_logs_old() {
    local days="$LOG_RETENTION_DAYS"
    [[ "$days" =~ ^[0-9]+$ ]] || days=30
    find "$LOG_DIR" -type f -name '*.log' -mtime "+${days}" 2>/dev/null \
        | while IFS= read -r f; do
            [[ "$f" == "${SO_LOG_FILE:-}" ]] || printf '%s\n' "$f"
        done || true
}

disk_measure_files() {
    local vol="${SUPABASE_DIR}/volumes" supabase_total known f

    DISK_INSTALL_TOTAL="$(_disk_du "$INSTALL_DIR")"
    DISK_DB="$(_disk_du "${vol}/db/data")"
    DISK_DB_WAL="$(_disk_du "${vol}/db/data/pg_wal")"
    DISK_STORAGE="$(_disk_du "${vol}/storage")"
    DISK_FUNCTIONS="$(_disk_du "${vol}/functions")"
    supabase_total="$(_disk_du "$SUPABASE_DIR")"
    DISK_SUPABASE_OTHER="$(_disk_max0 $(( supabase_total - DISK_DB - DISK_STORAGE - DISK_FUNCTIONS )))"

    DISK_BACKUPS="$(_disk_du "$BACKUP_DIR")"
    DISK_BACKUP_COUNT="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ' || true)"
    DISK_BACKUPS_EXCESS=0; DISK_BACKUPS_EXCESS_COUNT=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        DISK_BACKUPS_EXCESS=$(( DISK_BACKUPS_EXCESS + $(_disk_du "$f") ))
        DISK_BACKUPS_EXCESS_COUNT=$(( DISK_BACKUPS_EXCESS_COUNT + 1 ))
    done < <(_disk_backups_excess)

    DISK_LOGS="$(_disk_du "$LOG_DIR")"
    DISK_LOGS_OLD=0; DISK_LOGS_OLD_COUNT=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        DISK_LOGS_OLD=$(( DISK_LOGS_OLD + $(stat -c %s "$f" 2>/dev/null || printf 0) ))
        DISK_LOGS_OLD_COUNT=$(( DISK_LOGS_OLD_COUNT + 1 ))
    done < <(_disk_logs_old)

    DISK_APP_CHECKOUT="$(_disk_du "$APP_DIR")"
    known=$(( supabase_total + DISK_BACKUPS + DISK_LOGS + DISK_APP_CHECKOUT ))
    DISK_INSTALL_OTHER="$(_disk_max0 $(( DISK_INSTALL_TOTAL - known )))"
}

# ---------------------------------------------------------------------------
# Measurement: Docker
# ---------------------------------------------------------------------------

DISK_DOCKER_OK="false"
DISK_DOCKER_ROOT=""
DISK_DF_IMAGES=0; DISK_DF_CONTAINERS=0; DISK_DF_VOLUMES=0
DISK_BUILD_CACHE=0; DISK_BUILD_CACHE_RECLAIM=0
DISK_IMG_APP_KEPT=0; DISK_IMG_APP_STALE=0; DISK_IMG_APP_STALE_COUNT=0
DISK_IMG_SB_KEPT=0; DISK_IMG_SB_STALE=0; DISK_IMG_SB_STALE_COUNT=0
DISK_CTR_RW=0; DISK_VOLUMES=0
DISK_CTR_LOGS=0; DISK_CTR_LOGS_OTHER=0; DISK_CTR_LOGS_UNROTATED=0
# "name|bytes|rotation" for each of this stack's containers, largest log first.
DISK_CTR_LOG_ROWS=""

# Full ids of this stack's containers, running or stopped, one per line:
# everything in the Supabase compose project, and the frontend.
_disk_our_container_ids() {
    {
        supabase_installed && supabase_compose ps -aq 2>/dev/null
        docker inspect -f '{{.Id}}' "$APP_CONTAINER_NAME" 2>/dev/null
    } | while IFS= read -r id; do
        [[ -n "$id" ]] && docker inspect -f '{{.Id}}' "$id" 2>/dev/null
    done | sort -u || true
}

# The compose project the Supabase stack runs as, read from a live container
# and otherwise derived the way Compose derives it.
_disk_compose_project() {
    local cid p=""
    cid="$(supabase_compose ps -aq 2>/dev/null | head -n1 || true)"
    [[ -n "$cid" ]] && p="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null || true)"
    [[ -n "$p" && "$p" != "<no value>" ]] || \
        p="$(basename "$SUPABASE_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')"
    printf '%s' "$p"
}

# "id size-bytes" for every image of a repository, one line per distinct image.
_disk_repo_images() {
    docker images --no-trunc --format '{{.ID}}|{{.Size}}' "$1" 2>/dev/null \
        | sort -u | while IFS='|' read -r id size; do
            [[ -n "$id" ]] && printf '%s %s\n' "$id" "$(disk_parse_size "$size")"
        done || true
}

# Split a repository's images into kept and stale bytes. Stale is what
# lib/images.sh would remove; an image both kept and stale under different
# tags counts as kept, since removing the stale tag frees nothing.
# Sets _DISK_KEPT, _DISK_STALE, _DISK_STALE_N.  _disk_split_repo <repo> <stale-refs>
_disk_split_repo() {
    local repo="$1" stale_refs="$2" stale_ids="" ref id size
    _DISK_KEPT=0; _DISK_STALE=0; _DISK_STALE_N=0
    while IFS= read -r ref; do
        [[ -n "$ref" ]] && stale_ids+="$(_images_id_of "$ref")"$'\n'
    done <<<"$stale_refs"
    while IFS=' ' read -r id size; do
        [[ -n "$id" ]] || continue
        if grep -qxF -- "$id" <<<"$stale_ids"; then
            _DISK_STALE=$(( _DISK_STALE + size )); _DISK_STALE_N=$(( _DISK_STALE_N + 1 ))
        else
            _DISK_KEPT=$(( _DISK_KEPT + size ))
        fi
    done < <(_disk_repo_images "$repo")
}

disk_measure_docker() {
    DISK_DOCKER_OK="false"
    docker_daemon_ok || return 0
    DISK_DOCKER_OK="true"
    DISK_DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"

    # Totals as Docker sees them.
    local type size reclaim
    DISK_DF_IMAGES=0; DISK_DF_CONTAINERS=0; DISK_DF_VOLUMES=0; DISK_BUILD_CACHE=0; DISK_BUILD_CACHE_RECLAIM=0
    while IFS='|' read -r type size reclaim; do
        case "$type" in
            Images)          DISK_DF_IMAGES="$(disk_parse_size "$size")" ;;
            Containers)      DISK_DF_CONTAINERS="$(disk_parse_size "$size")" ;;
            "Local Volumes") DISK_DF_VOLUMES="$(disk_parse_size "$size")" ;;
            "Build Cache")   DISK_BUILD_CACHE="$(disk_parse_size "$size")"
                             DISK_BUILD_CACHE_RECLAIM="$(disk_parse_size "$reclaim")" ;;
        esac
    done < <(docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null || true)

    # Application images: the same keep-list as cleanup, plus untagged builds.
    local keep stale dangling
    keep="$(printf '%s\n%s\n%s:latest\n' \
        "$(state_get APP_IMAGE '')" "$(state_get PREVIOUS_APP_IMAGE '')" "$APP_IMAGE_NAME")"
    stale="$(_images_stale "$APP_IMAGE_NAME" "$keep")"
    _disk_split_repo "$APP_IMAGE_NAME" "$stale"
    DISK_IMG_APP_KEPT="$_DISK_KEPT"; DISK_IMG_APP_STALE="$_DISK_STALE"; DISK_IMG_APP_STALE_COUNT="$_DISK_STALE_N"
    dangling="$(docker images --no-trunc --filter dangling=true --filter "label=${APP_IMAGE_LABEL}" \
                    --format '{{.ID}}|{{.Size}}' 2>/dev/null | sort -u || true)"
    while IFS='|' read -r type size; do
        [[ -n "$type" ]] || continue
        DISK_IMG_APP_STALE=$(( DISK_IMG_APP_STALE + $(disk_parse_size "$size") ))
        DISK_IMG_APP_STALE_COUNT=$(( DISK_IMG_APP_STALE_COUNT + 1 ))
    done <<<"$dangling"

    # Supabase images: per repository the compose config names.
    DISK_IMG_SB_KEPT=0; DISK_IMG_SB_STALE=0; DISK_IMG_SB_STALE_COUNT=0
    local wanted repo
    if supabase_installed; then
        wanted="$(supabase_compose config --images 2>/dev/null | sort -u || true)"
        while IFS= read -r repo; do
            [[ -n "$repo" && "$repo" != *@* ]] || continue
            _disk_split_repo "$repo" "$(_images_stale "$repo" "$wanted")"
            DISK_IMG_SB_KEPT=$(( DISK_IMG_SB_KEPT + _DISK_KEPT ))
            DISK_IMG_SB_STALE=$(( DISK_IMG_SB_STALE + _DISK_STALE ))
            DISK_IMG_SB_STALE_COUNT=$(( DISK_IMG_SB_STALE_COUNT + _DISK_STALE_N ))
        done < <(while IFS= read -r ref; do [[ -n "$ref" ]] && { _images_repo_of "$ref"; printf '\n'; }; done <<<"$wanted" | sort -u)
    fi

    # Containers: writable layers and log files. Docker's own totals leave the
    # log files out entirely, and they are often the surprise.
    local ours id name logpath driver maxsize bytes rows=""
    ours="$(_disk_our_container_ids)"
    DISK_CTR_RW=0
    while IFS='|' read -r id size; do
        [[ -n "$id" ]] || continue
        grep -qxF -- "$id" <<<"$ours" && DISK_CTR_RW=$(( DISK_CTR_RW + $(disk_parse_size "$size") ))
    done < <(docker ps -a --size --no-trunc --format '{{.ID}}|{{.Size}}' 2>/dev/null || true)

    DISK_CTR_LOGS=0; DISK_CTR_LOGS_OTHER=0; DISK_CTR_LOGS_UNROTATED=0
    local all_ids
    all_ids="$(docker ps -aq --no-trunc 2>/dev/null || true)"
    if [[ -n "$all_ids" ]]; then
        # shellcheck disable=SC2086
        while IFS='|' read -r id name logpath driver maxsize; do
            [[ -n "$id" ]] || continue
            bytes=0
            [[ -n "$logpath" && -f "$logpath" ]] && bytes="$(stat -c %s "$logpath" 2>/dev/null || printf 0)"
            if grep -qxF -- "$id" <<<"$ours"; then
                DISK_CTR_LOGS=$(( DISK_CTR_LOGS + bytes ))
                [[ "$maxsize" == "<no value>" ]] && maxsize=""
                if [[ "$driver" == "json-file" && -z "$maxsize" ]]; then
                    DISK_CTR_LOGS_UNROTATED=$(( DISK_CTR_LOGS_UNROTATED + 1 ))
                    rows+="${name#/}|${bytes}|not rotated"$'\n'
                elif [[ -n "$maxsize" ]]; then
                    rows+="${name#/}|${bytes}|rotated at ${maxsize}"$'\n'
                else
                    rows+="${name#/}|${bytes}|${driver} driver"$'\n'
                fi
            else
                DISK_CTR_LOGS_OTHER=$(( DISK_CTR_LOGS_OTHER + bytes ))
            fi
        done < <(docker inspect -f '{{.Id}}|{{.Name}}|{{.LogPath}}|{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}' $all_ids 2>/dev/null || true)
    fi
    DISK_CTR_LOG_ROWS="$(printf '%s' "$rows" | sort -t'|' -k2,2nr)"

    # Named volumes of the compose project (most Supabase data is bind-mounted
    # under INSTALL_DIR and already counted there).
    local project vol mp
    DISK_VOLUMES=0
    project="$(_disk_compose_project)"
    while IFS= read -r vol; do
        [[ -n "$vol" ]] || continue
        mp="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
        [[ -n "$mp" ]] && DISK_VOLUMES=$(( DISK_VOLUMES + $(_disk_du "$mp") ))
    done < <(docker volume ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true)
    return 0
}

# ---------------------------------------------------------------------------
# Measurement: inside the database
# ---------------------------------------------------------------------------

DISK_DB_OK="false"
DISK_DB_DATABASES=""   # "name|bytes" per database, largest first
DISK_DB_TABLES=""      # "schema.table|bytes" for the largest tables
DISK_DB_ANALYTICS=0    # Logflare's event tables (_supabase._analytics)

# Run one query as the superuser against a given database. Prints rows as
# "a|b", nothing on any failure.
_disk_sql() {
    local db="$1" sql="$2" cid
    cid="$(supabase_container_id "$(supabase_db_service)" || true)"
    [[ -n "$cid" ]] || return 1
    printf '%s\n' "$sql" | docker exec -i -e PGPASSWORD="$(_db_pass)" "$cid" \
        psql -U "$DB_SUPERUSER" -d "$db" -tAq -F'|' -v ON_ERROR_STOP=1 2>/dev/null
}

disk_measure_database() {
    DISK_DB_OK="false"; DISK_DB_DATABASES=""; DISK_DB_TABLES=""; DISK_DB_ANALYTICS=0
    supabase_installed && [[ "$DISK_DOCKER_OK" == "true" ]] || return 0
    DISK_DB_DATABASES="$(_disk_sql "$(_db_name)" \
        "select datname, pg_database_size(oid) from pg_database where datallowconn order by 2 desc;")" || return 0
    [[ -n "$DISK_DB_DATABASES" ]] || return 0
    DISK_DB_OK="true"

    DISK_DB_TABLES="$(_disk_sql "$(_db_name)" "
        select n.nspname || '.' || c.relname, pg_total_relation_size(c.oid)
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind in ('r', 'm') and n.nspname not in ('pg_catalog', 'information_schema')
          and n.nspname not like 'pg_toast%'
        order by 2 desc limit 10;" || true)"

    # Self-hosted Logflare keeps its events in the _supabase database.
    if grep -q '^_supabase|' <<<"$DISK_DB_DATABASES"; then
        DISK_DB_ANALYTICS="$(_disk_sql _supabase "
            select coalesce(sum(pg_total_relation_size(c.oid)), 0)
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = '_analytics' and c.relkind = 'r';" || true)"
        [[ "$DISK_DB_ANALYTICS" =~ ^[0-9]+$ ]] || DISK_DB_ANALYTICS=0
    fi
    return 0
}

# What a table is, for the few that are known to grow on their own.
_disk_table_note() {
    case "$1" in
        cron.job_run_details)       printf 'pg_cron run history - never trimmed by default' ;;
        net._http_response)         printf 'pg_net responses' ;;
        auth.audit_log_entries)     printf 'Auth audit log' ;;
        storage.objects)            printf 'file metadata (the files are under Storage)' ;;
        supabase_functions.hooks)   printf 'database webhook history' ;;
        realtime.messages*)         printf 'Realtime messages' ;;
        public.*)                   printf 'application data' ;;
    esac
}

# ---------------------------------------------------------------------------
# Measurement: filesystems and the rest of the host
# ---------------------------------------------------------------------------

# "device size used avail mount" for the filesystem holding a path.
_disk_fs_of() {
    local dev
    dev="$(stat -c %d "$1" 2>/dev/null || true)"
    [[ -n "$dev" ]] || return 1
    df -PB1 "$1" 2>/dev/null | awk -v d="$dev" 'NR == 2 { print d, $2, $3, $4, $6 }'
}

# Size of the systemd journal in bytes, 0 when there is none.
_disk_journal() {
    have_cmd journalctl || { printf '0'; return 0; }
    local s
    s="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | head -n1 || true)"
    # journalctl prints "1.2G" (binary, no "i"); express it as GiB etc.
    case "$s" in
        *K|*KB) s="${s%%K*}KiB" ;; *M|*MB) s="${s%%M*}MiB" ;;
        *G|*GB) s="${s%%G*}GiB" ;; *T|*TB) s="${s%%T*}TiB" ;;
    esac
    disk_parse_size "${s:-0}"
}

DISK_HOST_ROWS=""   # "label|bytes" for well-known places outside the stack

disk_measure_host() {
    DISK_HOST_ROWS=""
    local j
    j="$(_disk_journal)"
    (( j > 0 )) && DISK_HOST_ROWS+="systemd journal|${j}"$'\n'
    DISK_HOST_ROWS+="/var/log|$(_disk_du /var/log)"$'\n'
    DISK_HOST_ROWS+="/tmp|$(_disk_du /tmp)"$'\n'
    DISK_HOST_ROWS+="/home|$(_disk_du /home)"$'\n'
    DISK_HOST_ROWS="$(printf '%s' "$DISK_HOST_ROWS" | sort -t'|' -k2,2nr)"
}

# ---------------------------------------------------------------------------
# Totals derived from the measurements
# ---------------------------------------------------------------------------

# Images that belong to the stack can be over-counted (builds share base
# layers, and `docker images` reports each image whole), so they are capped
# at Docker's own total for the image store.
disk_ours_images() {
    local n=$(( DISK_IMG_APP_KEPT + DISK_IMG_APP_STALE + DISK_IMG_SB_KEPT + DISK_IMG_SB_STALE ))
    (( DISK_DF_IMAGES > 0 && n > DISK_DF_IMAGES )) && n="$DISK_DF_IMAGES"
    printf '%s' "$n"
}

# Everything Sentinel Ops keeps in Docker's data directory.
disk_ours_docker() {
    printf '%s' $(( $(disk_ours_images) + DISK_CTR_RW + DISK_CTR_LOGS + DISK_VOLUMES ))
}

# Everything else in Docker's data directory: other workloads' images,
# containers, volumes and logs. Build cache is reported on its own because it
# cannot be attributed to a project.
disk_other_docker() {
    local all=$(( DISK_DF_IMAGES + DISK_DF_CONTAINERS + DISK_DF_VOLUMES + DISK_CTR_LOGS_OTHER ))
    local ours=$(( $(disk_ours_images) + DISK_CTR_RW + DISK_VOLUMES ))
    _disk_max0 $(( all - ours ))
}

# What `disk prune all` would give back, roughly. Image figures are an upper
# bound because of shared layers.
disk_reclaimable_total() {
    printf '%s' $(( DISK_IMG_APP_STALE + DISK_IMG_SB_STALE + DISK_BUILD_CACHE_RECLAIM \
                    + DISK_LOGS_OLD + DISK_BACKUPS_EXCESS ))
}

disk_measure_all() {
    printf '%sMeasuring disk usage (large Storage or database volumes take a while)...%s\n' "$C_DIM" "$C_RESET" >&2
    disk_measure_files
    disk_measure_docker
    disk_measure_database
    disk_measure_host
}

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

if [[ "${LC_ALL:-}${LANG:-}" == *[Uu][Tt][Ff]* ]]; then
    DISK_BAR_FULL="█"; DISK_BAR_EMPTY="░"; DISK_TREE_MID="├─"; DISK_TREE_END="└─"
else
    DISK_BAR_FULL="#"; DISK_BAR_EMPTY="."; DISK_TREE_MID="|-"; DISK_TREE_END="\`-"
fi

# A bar of <width> cells, <part> of <total> filled. Anything above zero shows
# at least one cell, so a small but real share does not look like nothing.
disk_bar() {
    local part="$1" total="$2" width="${3:-24}" filled=0 i out=""
    if (( total > 0 && part > 0 )); then
        filled=$(( part * width / total ))
        (( filled < 1 )) && filled=1
        (( filled > width )) && filled="$width"
    fi
    for (( i = 0; i < width; i++ )); do
        if (( i < filled )); then out+="$DISK_BAR_FULL"; else out+="$DISK_BAR_EMPTY"; fi
    done
    printf '%s' "$out"
}

# Colour for a fill level: green, yellow from 75%, red from 90%.
_disk_level_colour() {
    if (( $1 >= 90 )); then printf '%s' "$C_RED"
    elif (( $1 >= 75 )); then printf '%s' "$C_YELLOW"
    else printf '%s' "$C_GREEN"; fi
}

# One line of a breakdown:  label  bar  size  share  note
# _disk_row <label> <bytes> <of-total> [note] [colour]
_disk_row() {
    local label="$1" bytes="$2" total="$3" note="${4:-}" colour="${5:-$C_CYAN}"
    printf '  %-28s %s%s%s %11s %4s%%  %s%s%s\n' \
        "$label" "$colour" "$(disk_bar "$bytes" "$total" 20)" "$C_RESET" \
        "$(human_bytes "$bytes")" "$(_disk_pct "$bytes" "$total")" "$C_DIM" "$note" "$C_RESET"
}

# A sub-line with no bar, for detail under a row.
_disk_sub() {
    local branch="$1" label="$2" bytes="$3" note="${4:-}"
    printf '    %s %-24s %31s  %s%s%s\n' "$branch" "$label" "$(human_bytes "$bytes")" "$C_DIM" "$note" "$C_RESET"
}

# Filesystem bar plus the three-way split of what is used on it.
disk_render_filesystems() {
    local install_fs docker_fs dev size used avail mount pct ours other rest colour seen=""
    install_fs="$(_disk_fs_of "$INSTALL_DIR" || true)"
    docker_fs=""
    [[ "$DISK_DOCKER_OK" == "true" && -n "$DISK_DOCKER_ROOT" ]] && docker_fs="$(_disk_fs_of "$DISK_DOCKER_ROOT" || true)"

    local line
    for line in "$install_fs" "$docker_fs"; do
        [[ -n "$line" ]] || continue
        read -r dev size used avail mount <<<"$line"
        [[ " $seen " == *" $dev "* ]] && continue
        seen+=" $dev"

        pct="$(_disk_pct "$used" "$size")"
        colour="$(_disk_level_colour "$pct")"
        section "Filesystem ${mount}"
        printf '  %s%s%s  %s%% used  %s of %s, %s free\n' \
            "$colour" "$(disk_bar "$used" "$size" 40)" "$C_RESET" "$pct" \
            "$(human_bytes "$used")" "$(human_bytes "$size")" "$(human_bytes "$avail")"
        (( pct >= 90 )) && printf '  %s! Less than 10%% free.%s\n' "$C_RED" "$C_RESET"

        # What on this filesystem belongs to whom.
        ours=0; other=0
        [[ "$install_fs" == "$dev "* ]] && ours=$(( ours + DISK_INSTALL_TOTAL ))
        if [[ -n "$docker_fs" && "$docker_fs" == "$dev "* ]]; then
            ours=$(( ours + $(disk_ours_docker) ))
            other=$(( $(disk_other_docker) + DISK_BUILD_CACHE ))
        fi
        rest="$(_disk_max0 $(( used - ours - other )))"
        printf '\n  Where the used space goes\n'
        _disk_row "Sentinel Ops" "$ours" "$used" "this installation, all of it" "$C_GREEN"
        if [[ -n "$docker_fs" && "$docker_fs" == "$dev "* ]]; then
            _disk_row "Other Docker + build cache" "$other" "$used" "other workloads on this host"
        fi
        _disk_row "Rest of the system" "$rest" "$used" "OS, packages, other files" "$C_DIM"
    done
    return 0
}

disk_render_stack() {
    local ours_docker=0 total
    [[ "$DISK_DOCKER_OK" == "true" ]] && ours_docker="$(disk_ours_docker)"
    total=$(( DISK_INSTALL_TOTAL + ours_docker ))

    section "Sentinel Ops in detail - $(human_bytes "$total")"
    printf '  %sFiles under %s%s\n' "$C_BOLD" "$INSTALL_DIR" "$C_RESET"
    _disk_row "Database (Postgres)" "$DISK_DB" "$total" "supabase/volumes/db"
    (( DISK_DB_WAL > 0 )) && _disk_sub "$DISK_TREE_END" "write-ahead log (pg_wal)" "$DISK_DB_WAL" \
        "$( (( DISK_DB_WAL > 2147483648 )) && printf 'large - check replication slots' )"
    _disk_row "Storage (uploaded files)" "$DISK_STORAGE" "$total" "supabase/volumes/storage"
    _disk_row "Local backups" "$DISK_BACKUPS" "$total" \
        "${DISK_BACKUP_COUNT} kept, limit ${BACKUP_RETENTION_COUNT}"
    _disk_row "Installer logs" "$DISK_LOGS" "$total" \
        "$( (( DISK_LOGS_OLD_COUNT > 0 )) && printf '%s older than %s days' "$DISK_LOGS_OLD_COUNT" "$LOG_RETENTION_DAYS" )"
    _disk_row "Edge functions" "$DISK_FUNCTIONS" "$total"
    _disk_row "Application checkout" "$DISK_APP_CHECKOUT" "$total" "app/ (source, git history)"
    _disk_row "Supabase config, other" "$(( DISK_SUPABASE_OTHER + DISK_INSTALL_OTHER ))" "$total"

    if [[ "$DISK_DOCKER_OK" == "true" ]]; then
        printf '\n  %sIn Docker (%s)%s\n' "$C_BOLD" "${DISK_DOCKER_ROOT:-/var/lib/docker}" "$C_RESET"
        _disk_row "Application images" "$(( DISK_IMG_APP_KEPT + DISK_IMG_APP_STALE ))" "$total" \
            "$( (( DISK_IMG_APP_STALE_COUNT > 0 )) && printf '%s old build(s) removable' "$DISK_IMG_APP_STALE_COUNT" )"
        _disk_row "Supabase images" "$(( DISK_IMG_SB_KEPT + DISK_IMG_SB_STALE ))" "$total" \
            "$( (( DISK_IMG_SB_STALE_COUNT > 0 )) && printf '%s superseded removable' "$DISK_IMG_SB_STALE_COUNT" )"
        _disk_row "Container logs" "$DISK_CTR_LOGS" "$total" \
            "$( (( DISK_CTR_LOGS_UNROTATED > 0 )) && printf '%s container(s) not rotated' "$DISK_CTR_LOGS_UNROTATED" )"
        local name bytes how shown=0 rows
        rows="$(grep -v '|0|' <<<"$DISK_CTR_LOG_ROWS" | head -n 5 || true)"
        while IFS='|' read -r name bytes how; do
            [[ -n "$name" ]] || continue
            shown=$(( shown + 1 ))
            _disk_sub "$( (( shown == $(grep -c . <<<"$rows") )) && printf '%s' "$DISK_TREE_END" || printf '%s' "$DISK_TREE_MID" )" \
                "$name" "$bytes" "$how"
        done <<<"$rows"
        _disk_row "Container layers" "$DISK_CTR_RW" "$total" "files written inside containers"
        (( DISK_VOLUMES > 0 )) && _disk_row "Docker volumes" "$DISK_VOLUMES" "$total" "named volumes of the Supabase project"
    else
        printf '\n  %sDocker is not running; images and container logs were not measured.%s\n' "$C_YELLOW" "$C_RESET"
    fi
    return 0
}

disk_render_database() {
    [[ "$DISK_DB_OK" == "true" ]] || return 0
    local db_total name bytes note
    db_total="$(cut -d'|' -f2 <<<"$DISK_DB_DATABASES" | _disk_sum)"
    section "Inside the database - $(human_bytes "$db_total")"
    while IFS='|' read -r name bytes; do
        [[ -n "$name" ]] || continue
        note=""
        [[ "$name" == "_supabase" ]] && note="Supabase internals: Logflare $(human_bytes "$DISK_DB_ANALYTICS")"
        [[ "$name" == "$(_db_name)" ]] && note="application, Auth, Storage metadata"
        _disk_row "database ${name}" "$bytes" "$db_total" "$note"
    done <<<"$DISK_DB_DATABASES"

    [[ -n "$DISK_DB_TABLES" ]] || return 0
    printf '\n  Largest tables in %s\n' "$(_db_name)"
    while IFS='|' read -r name bytes; do
        [[ -n "$name" ]] || continue
        printf '    %-44s %11s  %s%s%s\n' "$name" "$(human_bytes "$bytes")" "$C_DIM" "$(_disk_table_note "$name")" "$C_RESET"
    done <<<"$DISK_DB_TABLES"
    return 0
}

disk_render_host() {
    [[ -n "$DISK_HOST_ROWS" ]] || return 0
    section "Outside Sentinel Ops (for comparison)"
    local label bytes
    while IFS='|' read -r label bytes; do
        [[ -n "$label" ]] || continue
        printf '  %-28s %11s\n' "$label" "$(human_bytes "$bytes")"
    done <<<"$DISK_HOST_ROWS"
    printf '  %sThese are not touched by sentinel-ops.%s\n' "$C_DIM" "$C_RESET"
}

# The numbered list the interactive prompt offers, and the summary otherwise.
# Prints "target|label|bytes|note" for every target with something to give.
disk_reclaimable_rows() {
    local img=$(( DISK_IMG_APP_STALE + DISK_IMG_SB_STALE + DISK_BUILD_CACHE_RECLAIM ))
    (( img > 0 )) && printf 'images|Old images and build cache|%s|up to; layers are shared between images\n' "$img"
    (( DISK_LOGS_OLD > 0 )) && printf 'logs|Installer logs older than %s days|%s|%s file(s)\n' \
        "$LOG_RETENTION_DAYS" "$DISK_LOGS_OLD" "$DISK_LOGS_OLD_COUNT"
    (( DISK_BACKUPS_EXCESS > 0 )) && printf 'backups|Backups beyond the retention limit|%s|%s oldest backup(s)\n' \
        "$DISK_BACKUPS_EXCESS" "$DISK_BACKUPS_EXCESS_COUNT"
    (( DISK_CTR_LOGS > 0 )) && printf 'container-logs|Container log files (empties them)|%s|log history is lost\n' "$DISK_CTR_LOGS"
    return 0
}

disk_render_reclaimable() {
    local rows target label bytes note n=0
    rows="$(disk_reclaimable_rows)"
    section "Can be reclaimed"
    if [[ -z "$rows" ]]; then
        printf '  %s%s Nothing to clean up.%s\n' "$C_GREEN" "$SYM_OK" "$C_RESET"
        return 0
    fi
    while IFS='|' read -r target label bytes note; do
        [[ -n "$target" ]] || continue
        n=$(( n + 1 ))
        printf '  %2d. %-38s %11s  %s%s%s\n' "$n" "$label" "$(human_bytes "$bytes")" "$C_DIM" "$note" "$C_RESET"
    done <<<"$rows"
    printf '\n  %sKept always: the database, Storage files, the deployed and rollback images, the newest %s backups.%s\n' \
        "$C_DIM" "$BACKUP_RETENTION_COUNT" "$C_RESET"
}

disk_render_advice() {
    local said=""
    if (( DISK_CTR_LOGS_UNROTATED > 0 )); then
        section "Worth fixing"
        said="yes"
        printf '  %s container(s) log without rotation, so their log files grow until the disk is full.\n' "$DISK_CTR_LOGS_UNROTATED"
        printf '  Set a default in /etc/docker/daemon.json, then restart Docker and recreate the stack:\n'
        printf '    %s{"log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}}%s\n' "$C_DIM" "$C_RESET"
    fi
    if (( DISK_DB_WAL > 2147483648 )); then
        [[ -n "$said" ]] || section "Worth fixing"
        printf '  The write-ahead log is %s. A replication slot nobody reads holds it back:\n' "$(human_bytes "$DISK_DB_WAL")"
        printf '    %sselect slot_name, active from pg_replication_slots;%s\n' "$C_DIM" "$C_RESET"
    fi
    return 0
}

disk_render_all() {
    disk_render_filesystems
    disk_render_stack
    disk_render_database
    disk_render_host
    disk_render_reclaimable
    disk_render_advice
    printf '\n'
}

# ---------------------------------------------------------------------------
# Pruning
# ---------------------------------------------------------------------------

_disk_verb() { if [[ "$SO_DISK_DRY_RUN" == "true" ]]; then printf 'would remove'; else printf 'removed'; fi; }

disk_prune_images() {
    SO_IMAGES_DRY_RUN="$SO_DISK_DRY_RUN"
    images_prune_app
    supabase_installed && images_prune_supabase
    images_prune_build_cache
    return 0
}

disk_prune_logs() {
    local f n=0 bytes=0 size
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        size="$(stat -c %s "$f" 2>/dev/null || printf 0)"
        if [[ "$SO_DISK_DRY_RUN" == "true" ]]; then
            printf '  would remove %s\n' "$f" >&2
        elif ! rm -f -- "$f"; then
            log_warn "Could not remove ${f}."
            continue
        fi
        n=$(( n + 1 )); bytes=$(( bytes + size ))
    done < <(_disk_logs_old)
    log_ok "Installer logs: $(_disk_verb) ${n} file(s) older than ${LOG_RETENTION_DAYS} days ($(human_bytes "$bytes"))"
    return 0
}

disk_prune_backups() {
    local excess n
    excess="$(_disk_backups_excess)"
    n="$(grep -c . <<<"$excess" || true)"
    if [[ "$SO_DISK_DRY_RUN" == "true" ]]; then
        [[ -n "$excess" ]] && sed 's/^/  would remove /' <<<"$excess" >&2
    else
        backup_prune_local
    fi
    log_ok "Backups: $(_disk_verb) ${n} beyond the newest ${BACKUP_RETENTION_COUNT}"
    return 0
}

# Empty the JSON log file of each of this stack's containers. truncate, not
# rm: Docker keeps the file open and would go on writing to a deleted inode.
disk_prune_container_logs() {
    local id name logpath driver n=0 bytes=0 size
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        IFS='|' read -r name logpath driver < <(docker inspect -f '{{.Name}}|{{.LogPath}}|{{.HostConfig.LogConfig.Type}}' "$id" 2>/dev/null) || continue
        [[ "$driver" == "json-file" && -n "$logpath" && -f "$logpath" ]] || continue
        size="$(stat -c %s "$logpath" 2>/dev/null || printf 0)"
        (( size > 0 )) || continue
        if [[ "$SO_DISK_DRY_RUN" == "true" ]]; then
            printf '  would empty the log of %s (%s)\n' "${name#/}" "$(human_bytes "$size")" >&2
        elif ! truncate -s 0 -- "$logpath"; then
            log_warn "Could not empty the log of ${name#/}."
            continue
        fi
        n=$(( n + 1 )); bytes=$(( bytes + size ))
    done < <(_disk_our_container_ids)
    if [[ "$SO_DISK_DRY_RUN" == "true" ]]; then
        log_ok "Container logs: would empty ${n} file(s) ($(human_bytes "$bytes"))"
    else
        log_ok "Container logs: emptied ${n} file(s) ($(human_bytes "$bytes"))"
    fi
    return 0
}

# Validate and expand target names. "all" means every routine target; an
# unknown name fails. Prints the targets one per line, in a fixed order.
disk_resolve_targets() {
    local t want=" "
    for t in "$@"; do
        case "$t" in
            all) want+="${DISK_PRUNE_TARGETS[*]} " ;;
            images|logs|backups|container-logs) want+="$t " ;;
            *) log_error "Unknown prune target: ${t}"; return 2 ;;
        esac
    done
    for t in "${DISK_PRUNE_TARGETS[@]}" "${DISK_PRUNE_TARGETS_EXPLICIT[@]}"; do
        [[ "$want" == *" $t "* ]] && printf '%s\n' "$t"
    done
    return 0
}

disk_prune_target() {
    case "$1" in
        images)         disk_prune_images ;;
        logs)           disk_prune_logs ;;
        backups)        disk_prune_backups ;;
        container-logs) disk_prune_container_logs ;;
    esac
}
