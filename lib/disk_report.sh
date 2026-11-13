#!/usr/bin/env bash
# lib/disk_report.sh - where the disk goes, drawn for a person.
#
# The limits themselves live elsewhere (lib/disk.sh, lib/backup.sh,
# lib/images.sh, lib/container_logs.sh, lib/logflare.sh). This answers the
# questions those limits do not:
#
#   1. How full is the disk, and how much of the used space is Sentinel Ops,
#      how much other Docker workloads, how much the rest of the system?
#   2. Inside Sentinel Ops: database, Storage, backups, logs, images,
#      container logs, Logflare - which one is big?
#   3. What can be reclaimed now, and how much would that free?
#
# Measuring (dr_measure_*) and drawing (dr_render_*) are kept apart: every
# measurement lands in a DR_* global, so the report can be tested without a
# Docker daemon or a database. Reclaiming only calls the existing prune
# functions, with the same keep rules as `cleanup`. See docs/DECISIONS.md #39.
# shellcheck shell=bash

# Every target `disk prune` accepts, in the order `all` runs them.
DR_PRUNE_TARGETS=(backups logs images)

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------

# Docker prints sizes for people ("1.23GB", "512MB", "8.1GB (65%)", "0B").
# Convert one to bytes. Docker's own units are decimal (kB/MB/GB); binary
# units (KiB/MiB/GiB) are accepted too. Anything unreadable is 0.
dr_parse_size() {
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

_dr_sum() { awk '{ s += $1 } END { printf "%.0f\n", s }'; }

_dr_max0() { if (( $1 > 0 )); then printf '%s' "$1"; else printf '0'; fi; }

# Percentage of part in total, rounded down, 0 when total is 0.
_dr_pct() { if (( $2 > 0 )); then printf '%s' $(( $1 * 100 / $2 )); else printf '0'; fi; }

_dr_file_size() { stat -c %s "$1" 2>/dev/null || printf '0'; }

# ---------------------------------------------------------------------------
# Measurement: files under INSTALL_DIR
# ---------------------------------------------------------------------------

DR_INSTALL_TOTAL=0
DR_DB=0; DR_DB_WAL=0; DR_STORAGE=0; DR_FUNCTIONS=0; DR_SUPABASE_OTHER=0
DR_BACKUPS=0; DR_BACKUP_COUNT=0; DR_BACKUPS_PRUNABLE=0; DR_BACKUPS_PRUNABLE_COUNT=0
DR_LOGS=0; DR_LOGS_OLD=0; DR_LOGS_OLD_COUNT=0
DR_APP_CHECKOUT=0; DR_INSTALL_OTHER=0

dr_measure_files() {
    local vol="${SUPABASE_DIR}/volumes" supabase_total known f

    DR_INSTALL_TOTAL="$(disk_used_bytes "$INSTALL_DIR")"
    DR_DB="$(disk_used_bytes "${vol}/db/data")"
    DR_DB_WAL="$(disk_used_bytes "${vol}/db/data/pg_wal")"
    DR_STORAGE="$(disk_used_bytes "${vol}/storage")"
    DR_FUNCTIONS="$(disk_used_bytes "${vol}/functions")"
    supabase_total="$(disk_used_bytes "$SUPABASE_DIR")"
    DR_SUPABASE_OTHER="$(_dr_max0 $(( supabase_total - DR_DB - DR_STORAGE - DR_FUNCTIONS )))"

    # Backups: what retention (count and size) would remove right now.
    DR_BACKUPS="$(disk_used_bytes "$BACKUP_DIR")"
    DR_BACKUP_COUNT="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ' || true)"
    DR_BACKUPS_PRUNABLE=0; DR_BACKUPS_PRUNABLE_COUNT=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        DR_BACKUPS_PRUNABLE=$(( DR_BACKUPS_PRUNABLE + $(disk_used_bytes "$f") ))
        DR_BACKUPS_PRUNABLE_COUNT=$(( DR_BACKUPS_PRUNABLE_COUNT + 1 ))
    done < <(_backup_prune_candidates 2>/dev/null)

    # Installer logs: what LOG_RETENTION_DAYS would remove right now.
    DR_LOGS="$(disk_used_bytes "$LOG_DIR")"
    DR_LOGS_OLD=0; DR_LOGS_OLD_COUNT=0
    while IFS= read -r f; do
        [[ -n "$f" && "$f" != "${SO_LOG_FILE:-}" ]] || continue
        DR_LOGS_OLD=$(( DR_LOGS_OLD + $(_dr_file_size "$f") ))
        DR_LOGS_OLD_COUNT=$(( DR_LOGS_OLD_COUNT + 1 ))
    done < <(_logs_prune_candidates 2>/dev/null)

    DR_APP_CHECKOUT="$(disk_used_bytes "$APP_DIR")"
    known=$(( supabase_total + DR_BACKUPS + DR_LOGS + DR_APP_CHECKOUT ))
    DR_INSTALL_OTHER="$(_dr_max0 $(( DR_INSTALL_TOTAL - known )))"
    return 0
}

# ---------------------------------------------------------------------------
# Measurement: Docker
# ---------------------------------------------------------------------------

DR_DOCKER_OK="false"
DR_DOCKER_ROOT=""
DR_DF_IMAGES=0; DR_DF_CONTAINERS=0; DR_DF_VOLUMES=0
DR_BUILD_CACHE=0; DR_BUILD_CACHE_RECLAIM=0
DR_IMG_APP_KEPT=0; DR_IMG_APP_STALE=0; DR_IMG_APP_STALE_COUNT=0
DR_IMG_SB_KEPT=0; DR_IMG_SB_STALE=0; DR_IMG_SB_STALE_COUNT=0
DR_CTR_RW=0; DR_VOLUMES=0
DR_CTR_LOGS=0; DR_CTR_LOGS_OTHER=0; DR_CTR_LOGS_UNLIMITED=0
# "name|bytes|limit" for each of this stack's containers, largest log first.
DR_CTR_LOG_ROWS=""

# Full ids of this stack's containers, running or stopped, one per line:
# everything in the Supabase compose project, and the frontend.
_dr_our_container_ids() {
    {
        supabase_installed && supabase_compose ps -aq 2>/dev/null
        docker inspect -f '{{.Id}}' "$APP_CONTAINER_NAME" 2>/dev/null
    } | while IFS= read -r id; do
        [[ -n "$id" ]] && docker inspect -f '{{.Id}}' "$id" 2>/dev/null
    done | sort -u || true
}

# The compose project the Supabase stack runs as, read from a live container
# and otherwise derived the way Compose derives it.
_dr_compose_project() {
    local cid p=""
    cid="$(supabase_compose ps -aq 2>/dev/null | head -n1 || true)"
    [[ -n "$cid" ]] && p="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null || true)"
    [[ -n "$p" && "$p" != "<no value>" ]] || \
        p="$(basename "$SUPABASE_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')"
    printf '%s' "$p"
}

# "id size-bytes" for every image of a repository, one line per distinct image.
_dr_repo_images() {
    docker images --no-trunc --format '{{.ID}}|{{.Size}}' "$1" 2>/dev/null \
        | sort -u | while IFS='|' read -r id size; do
            [[ -n "$id" ]] && printf '%s %s\n' "$id" "$(dr_parse_size "$size")"
        done || true
}

# Split a repository's images into kept and stale bytes. Stale is what
# lib/images.sh would remove; an image both kept and stale under different
# tags counts as kept, since removing the stale tag frees nothing.
# Sets _DR_KEPT, _DR_STALE, _DR_STALE_N.  _dr_split_repo <repo> <stale-refs>
_dr_split_repo() {
    local repo="$1" stale_refs="$2" stale_ids="" ref id size
    _DR_KEPT=0; _DR_STALE=0; _DR_STALE_N=0
    while IFS= read -r ref; do
        [[ -n "$ref" ]] && stale_ids+="$(_images_id_of "$ref")"$'\n'
    done <<<"$stale_refs"
    while IFS=' ' read -r id size; do
        [[ -n "$id" ]] || continue
        if grep -qxF -- "$id" <<<"$stale_ids"; then
            _DR_STALE=$(( _DR_STALE + size )); _DR_STALE_N=$(( _DR_STALE_N + 1 ))
        else
            _DR_KEPT=$(( _DR_KEPT + size ))
        fi
    done < <(_dr_repo_images "$repo")
    return 0
}

# A container's log on disk: the live file and the rotated ones beside it.
_dr_log_bytes() {
    local logpath="$1" f total=0
    [[ -n "$logpath" ]] || { printf '0'; return 0; }
    for f in "$logpath" "$logpath".*; do
        [[ -f "$f" ]] && total=$(( total + $(_dr_file_size "$f") ))
    done
    printf '%s' "$total"
}

dr_measure_docker() {
    DR_DOCKER_OK="false"
    docker_daemon_ok || return 0
    DR_DOCKER_OK="true"
    DR_DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"

    # Totals as Docker sees them.
    local type size reclaim
    DR_DF_IMAGES=0; DR_DF_CONTAINERS=0; DR_DF_VOLUMES=0; DR_BUILD_CACHE=0; DR_BUILD_CACHE_RECLAIM=0
    while IFS='|' read -r type size reclaim; do
        case "$type" in
            Images)          DR_DF_IMAGES="$(dr_parse_size "$size")" ;;
            Containers)      DR_DF_CONTAINERS="$(dr_parse_size "$size")" ;;
            "Local Volumes") DR_DF_VOLUMES="$(dr_parse_size "$size")" ;;
            "Build Cache")   DR_BUILD_CACHE="$(dr_parse_size "$size")"
                             DR_BUILD_CACHE_RECLAIM="$(dr_parse_size "$reclaim")" ;;
        esac
    done < <(docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null || true)

    # Application images: the same keep-list as cleanup, plus untagged builds.
    local keep stale dangling
    keep="$(printf '%s\n%s\n%s:latest\n' \
        "$(state_get APP_IMAGE '')" "$(state_get PREVIOUS_APP_IMAGE '')" "$APP_IMAGE_NAME")"
    stale="$(_images_stale "$APP_IMAGE_NAME" "$keep")"
    _dr_split_repo "$APP_IMAGE_NAME" "$stale"
    DR_IMG_APP_KEPT="$_DR_KEPT"; DR_IMG_APP_STALE="$_DR_STALE"; DR_IMG_APP_STALE_COUNT="$_DR_STALE_N"
    dangling="$(docker images --no-trunc --filter dangling=true --filter "label=${APP_IMAGE_LABEL}" \
                    --format '{{.ID}}|{{.Size}}' 2>/dev/null | sort -u || true)"
    while IFS='|' read -r type size; do
        [[ -n "$type" ]] || continue
        DR_IMG_APP_STALE=$(( DR_IMG_APP_STALE + $(dr_parse_size "$size") ))
        DR_IMG_APP_STALE_COUNT=$(( DR_IMG_APP_STALE_COUNT + 1 ))
    done <<<"$dangling"

    # Supabase images: per repository the compose config names.
    DR_IMG_SB_KEPT=0; DR_IMG_SB_STALE=0; DR_IMG_SB_STALE_COUNT=0
    local wanted repo
    if supabase_installed; then
        wanted="$(supabase_compose config --images 2>/dev/null | sort -u || true)"
        while IFS= read -r repo; do
            [[ -n "$repo" && "$repo" != *@* ]] || continue
            _dr_split_repo "$repo" "$(_images_stale "$repo" "$wanted")"
            DR_IMG_SB_KEPT=$(( DR_IMG_SB_KEPT + _DR_KEPT ))
            DR_IMG_SB_STALE=$(( DR_IMG_SB_STALE + _DR_STALE ))
            DR_IMG_SB_STALE_COUNT=$(( DR_IMG_SB_STALE_COUNT + _DR_STALE_N ))
        done < <(while IFS= read -r ref; do [[ -n "$ref" ]] && { _images_repo_of "$ref"; printf '\n'; }; done <<<"$wanted" | sort -u)
    fi

    # Containers: writable layers and log files. Docker's own totals leave the
    # log files out entirely, and they are often the surprise.
    local ours id name logpath maxsize maxfile bytes rows=""
    ours="$(_dr_our_container_ids)"
    DR_CTR_RW=0
    while IFS='|' read -r id size; do
        [[ -n "$id" ]] || continue
        if grep -qxF -- "$id" <<<"$ours"; then
            DR_CTR_RW=$(( DR_CTR_RW + $(dr_parse_size "$size") ))
        fi
    done < <(docker ps -a --size --no-trunc --format '{{.ID}}|{{.Size}}' 2>/dev/null || true)

    DR_CTR_LOGS=0; DR_CTR_LOGS_OTHER=0; DR_CTR_LOGS_UNLIMITED=0
    local all_ids
    all_ids="$(docker ps -aq --no-trunc 2>/dev/null || true)"
    if [[ -n "$all_ids" ]]; then
        # shellcheck disable=SC2086
        while IFS='|' read -r id name logpath maxsize maxfile; do
            [[ -n "$id" ]] || continue
            bytes="$(_dr_log_bytes "$logpath")"
            if grep -qxF -- "$id" <<<"$ours"; then
                DR_CTR_LOGS=$(( DR_CTR_LOGS + bytes ))
                [[ "$maxsize" == "<no value>" ]] && maxsize=""
                [[ "$maxfile" == "<no value>" || -z "$maxfile" ]] && maxfile="1"
                if [[ -n "$maxsize" ]]; then
                    rows+="${name#/}|${bytes}|limit ${maxfile} x ${maxsize}"$'\n'
                else
                    DR_CTR_LOGS_UNLIMITED=$(( DR_CTR_LOGS_UNLIMITED + 1 ))
                    rows+="${name#/}|${bytes}|no limit"$'\n'
                fi
            else
                DR_CTR_LOGS_OTHER=$(( DR_CTR_LOGS_OTHER + bytes ))
            fi
        done < <(docker inspect -f '{{.Id}}|{{.Name}}|{{.LogPath}}|{{index .HostConfig.LogConfig.Config "max-size"}}|{{index .HostConfig.LogConfig.Config "max-file"}}' $all_ids 2>/dev/null || true)
    fi
    DR_CTR_LOG_ROWS="$(printf '%s' "$rows" | sort -t'|' -k2,2nr)"

    # Named volumes of the compose project (most Supabase data is bind-mounted
    # under INSTALL_DIR and already counted there).
    local project vol mp
    DR_VOLUMES=0
    project="$(_dr_compose_project)"
    while IFS= read -r vol; do
        [[ -n "$vol" ]] || continue
        mp="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
        [[ -n "$mp" ]] && DR_VOLUMES=$(( DR_VOLUMES + $(disk_used_bytes "$mp") ))
    done < <(docker volume ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true)
    return 0
}

# ---------------------------------------------------------------------------
# Measurement: inside the database
# ---------------------------------------------------------------------------

DR_DB_OK="false"
DR_DB_DATABASES=""   # "name|bytes" per database, largest first
DR_DB_TABLES=""      # "schema.table|bytes" for the largest tables
DR_ANALYTICS=""      # Logflare's log tables on this server, bytes ("" unknown)

# Run one query as the superuser against a given database. Prints rows as
# "a|b", nothing on any failure.
_dr_sql() {
    local db="$1" sql="$2" cid
    cid="$(supabase_container_id "$(supabase_db_service)" || true)"
    [[ -n "$cid" ]] || return 1
    printf '%s\n' "$sql" | docker exec -i -e PGPASSWORD="$(_db_pass)" "$cid" \
        psql -U "$DB_SUPERUSER" -d "$db" -tAq -F'|' -v ON_ERROR_STOP=1 2>/dev/null
}

dr_measure_database() {
    DR_DB_OK="false"; DR_DB_DATABASES=""; DR_DB_TABLES=""; DR_ANALYTICS=""
    supabase_installed && [[ "$DR_DOCKER_OK" == "true" ]] || return 0
    DR_DB_DATABASES="$(_dr_sql "$(_db_name)" \
        "select datname, pg_database_size(oid) from pg_database where datallowconn order by 2 desc;")" || return 0
    [[ -n "$DR_DB_DATABASES" ]] || return 0
    DR_DB_OK="true"

    DR_DB_TABLES="$(_dr_sql "$(_db_name)" "
        select n.nspname || '.' || c.relname, pg_total_relation_size(c.oid)
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind in ('r', 'm') and n.nspname not in ('pg_catalog', 'information_schema')
          and n.nspname not like 'pg_toast%'
        order by 2 desc limit 10;" || true)"

    # Only when the logs live on this server: a remote Postgres or BigQuery
    # backend takes no space here.
    if [[ "$ENABLE_LOGFLARE" == "true" && "$(logflare_backend 2>/dev/null)" == "local" ]]; then
        DR_ANALYTICS="$(logflare_storage_bytes 2>/dev/null || true)"
    fi
    return 0
}

# What a table is, for the few that are known to grow on their own.
_dr_table_note() {
    case "$1" in
        cron.job_run_details)       printf 'pg_cron run history - never trimmed by default' ;;
        net._http_response)         printf 'pg_net responses' ;;
        auth.audit_log_entries)     printf 'Auth audit log' ;;
        storage.objects)            printf 'file metadata (the files are under Storage)' ;;
        supabase_functions.hooks)   printf 'database webhook history' ;;
        realtime.messages*)         printf 'Realtime messages' ;;
        public.audit_logs*)         printf 'application audit log (left out of backups)' ;;
        public.*)                   printf 'application data' ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Measurement: filesystems and the rest of the host
# ---------------------------------------------------------------------------

# "device size used avail mount" for the filesystem holding a path.
_dr_fs_of() {
    local dev
    dev="$(stat -c %d "$1" 2>/dev/null || true)"
    [[ -n "$dev" ]] || return 1
    df -PB1 "$1" 2>/dev/null | awk -v d="$dev" 'NR == 2 { print d, $2, $3, $4, $6 }'
}

# Size of the systemd journal in bytes, 0 when there is none.
_dr_journal() {
    have_cmd journalctl || { printf '0'; return 0; }
    local s
    s="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | head -n1 || true)"
    # journalctl prints "1.2G" (binary, without the "i").
    case "$s" in
        *K|*KB) s="${s%%K*}KiB" ;; *M|*MB) s="${s%%M*}MiB" ;;
        *G|*GB) s="${s%%G*}GiB" ;; *T|*TB) s="${s%%T*}TiB" ;;
    esac
    dr_parse_size "${s:-0}"
}

DR_HOST_ROWS=""   # "label|bytes" for well-known places outside the stack

dr_measure_host() {
    local j rows=""
    j="$(_dr_journal)"
    (( j > 0 )) && rows+="systemd journal|${j}"$'\n'
    rows+="/var/log|$(disk_used_bytes /var/log)"$'\n'
    rows+="/tmp|$(disk_used_bytes /tmp)"$'\n'
    rows+="/home|$(disk_used_bytes /home)"$'\n'
    DR_HOST_ROWS="$(printf '%s' "$rows" | sort -t'|' -k2,2nr)"
    return 0
}

# ---------------------------------------------------------------------------
# Totals derived from the measurements
# ---------------------------------------------------------------------------

# Images that belong to the stack can be over-counted (builds share base
# layers, and `docker images` reports each image whole), so they are capped
# at Docker's own total for the image store.
dr_ours_images() {
    local n=$(( DR_IMG_APP_KEPT + DR_IMG_APP_STALE + DR_IMG_SB_KEPT + DR_IMG_SB_STALE ))
    if (( DR_DF_IMAGES > 0 && n > DR_DF_IMAGES )); then n="$DR_DF_IMAGES"; fi
    printf '%s' "$n"
}

# Everything Sentinel Ops keeps in Docker's data directory.
dr_ours_docker() {
    printf '%s' $(( $(dr_ours_images) + DR_CTR_RW + DR_CTR_LOGS + DR_VOLUMES ))
}

# Everything else in Docker's data directory: other workloads' images,
# containers, volumes and logs. Build cache is reported on its own because it
# cannot be attributed to a project.
dr_other_docker() {
    local all=$(( DR_DF_IMAGES + DR_DF_CONTAINERS + DR_DF_VOLUMES + DR_CTR_LOGS_OTHER ))
    local ours=$(( $(dr_ours_images) + DR_CTR_RW + DR_VOLUMES ))
    _dr_max0 $(( all - ours ))
}

dr_measure_all() {
    printf '%sMeasuring disk usage (a large database or Storage takes a while)...%s\n' "$C_DIM" "$C_RESET" >&2
    dr_measure_files
    dr_measure_docker
    dr_measure_database
    dr_measure_host
}

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

if [[ "${LC_ALL:-}${LANG:-}" == *[Uu][Tt][Ff]* ]]; then
    DR_BAR_FULL="█"; DR_BAR_EMPTY="░"; DR_TREE_MID="├─"; DR_TREE_END="└─"
else
    DR_BAR_FULL="#"; DR_BAR_EMPTY="."; DR_TREE_MID="|-"; DR_TREE_END="\`-"
fi

# A bar of <width> cells, <part> of <total> filled. Anything above zero shows
# at least one cell, so a small but real share does not look like nothing.
dr_bar() {
    local part="$1" total="$2" width="${3:-24}" filled=0 i out=""
    if (( total > 0 && part > 0 )); then
        filled=$(( part * width / total ))
        (( filled < 1 )) && filled=1
        (( filled > width )) && filled="$width"
    fi
    for (( i = 0; i < width; i++ )); do
        if (( i < filled )); then out+="$DR_BAR_FULL"; else out+="$DR_BAR_EMPTY"; fi
    done
    printf '%s' "$out"
}

# Colour for a fill level: green, yellow from 75%, red from 90%.
_dr_level_colour() {
    if (( $1 >= 90 )); then printf '%s' "$C_RED"
    elif (( $1 >= 75 )); then printf '%s' "$C_YELLOW"
    else printf '%s' "$C_GREEN"; fi
}

# One line of a breakdown:  label  bar  size  share  note
# _dr_row <label> <bytes> <of-total> [note] [colour]
_dr_row() {
    local label="$1" bytes="$2" total="$3" note="${4:-}" colour="${5:-$C_CYAN}"
    printf '  %-28s %s%s%s %11s %4s%%  %s%s%s\n' \
        "$label" "$colour" "$(dr_bar "$bytes" "$total" 20)" "$C_RESET" \
        "$(human_bytes "$bytes")" "$(_dr_pct "$bytes" "$total")" "$C_DIM" "$note" "$C_RESET"
}

# A sub-line with no bar, for detail under a row; the size lines up with the
# row's.
_dr_sub() {
    local branch="$1" label="$2" bytes="$3" note="${4:-}"
    printf '    %s %-24s %31s  %s%s%s\n' "$branch" "$label" "$(human_bytes "$bytes")" "$C_DIM" "$note" "$C_RESET"
}

# Filesystem bar plus the three-way split of what is used on it.
dr_render_filesystems() {
    local install_fs docker_fs dev size used avail mount pct ours other rest colour seen="" line
    install_fs="$(_dr_fs_of "$INSTALL_DIR" || true)"
    docker_fs=""
    [[ "$DR_DOCKER_OK" == "true" && -n "$DR_DOCKER_ROOT" ]] && docker_fs="$(_dr_fs_of "$DR_DOCKER_ROOT" || true)"

    for line in "$install_fs" "$docker_fs"; do
        [[ -n "$line" ]] || continue
        read -r dev size used avail mount <<<"$line"
        [[ " $seen " == *" $dev "* ]] && continue
        seen+=" $dev"

        pct="$(_dr_pct "$used" "$size")"
        colour="$(_dr_level_colour "$pct")"
        section "Filesystem ${mount}"
        printf '  %s%s%s  %s%% used  %s of %s, %s free\n' \
            "$colour" "$(dr_bar "$used" "$size" 40)" "$C_RESET" "$pct" \
            "$(human_bytes "$used")" "$(human_bytes "$size")" "$(human_bytes "$avail")"
        (( pct >= 90 )) && printf '  %s! Less than 10%% free.%s\n' "$C_RED" "$C_RESET"

        # What on this filesystem belongs to whom.
        ours=0; other=0
        [[ "$install_fs" == "$dev "* ]] && ours=$(( ours + DR_INSTALL_TOTAL ))
        if [[ -n "$docker_fs" && "$docker_fs" == "$dev "* ]]; then
            ours=$(( ours + $(dr_ours_docker) ))
            other=$(( $(dr_other_docker) + DR_BUILD_CACHE ))
        fi
        rest="$(_dr_max0 $(( used - ours - other )))"
        printf '\n  Where the used space goes\n'
        _dr_row "Sentinel Ops" "$ours" "$used" "this installation, all of it" "$C_GREEN"
        if [[ -n "$docker_fs" && "$docker_fs" == "$dev "* ]]; then
            _dr_row "Other Docker + build cache" "$other" "$used" "other workloads on this host"
        fi
        _dr_row "Rest of the system" "$rest" "$used" "OS, packages, other files" "$C_DIM"
    done
    return 0
}

dr_render_stack() {
    local ours_docker=0 total
    [[ "$DR_DOCKER_OK" == "true" ]] && ours_docker="$(dr_ours_docker)"
    total=$(( DR_INSTALL_TOTAL + ours_docker ))

    section "Sentinel Ops in detail - $(human_bytes "$total")"
    printf '  %sFiles under %s%s\n' "$C_BOLD" "$INSTALL_DIR" "$C_RESET"
    _dr_row "Database (Postgres)" "$DR_DB" "$total" "supabase/volumes/db"
    if (( DR_DB_WAL > 0 )); then
        _dr_sub "$DR_TREE_END" "write-ahead log (pg_wal)" "$DR_DB_WAL" \
            "$( (( DR_DB_WAL > 2147483648 )) && printf 'large - check replication slots' )"
    fi
    _dr_row "Storage (uploaded files)" "$DR_STORAGE" "$total" "supabase/volumes/storage"
    _dr_row "Local backups" "$DR_BACKUPS" "$total" \
        "${DR_BACKUP_COUNT} kept (limit $(backup_retention_count 2>/dev/null))"
    _dr_row "Installer logs" "$DR_LOGS" "$total" \
        "$( (( DR_LOGS_OLD_COUNT > 0 )) && printf '%s past %s days' "$DR_LOGS_OLD_COUNT" "$(logs_retention_days 2>/dev/null)" )"
    _dr_row "Edge functions" "$DR_FUNCTIONS" "$total"
    _dr_row "Application checkout" "$DR_APP_CHECKOUT" "$total" "app/ (source, git history)"
    _dr_row "Supabase config, other" "$(( DR_SUPABASE_OTHER + DR_INSTALL_OTHER ))" "$total"

    if [[ "$DR_DOCKER_OK" != "true" ]]; then
        printf '\n  %sDocker is not running; images and container logs were not measured.%s\n' "$C_YELLOW" "$C_RESET"
        return 0
    fi
    printf '\n  %sIn Docker (%s)%s\n' "$C_BOLD" "${DR_DOCKER_ROOT:-/var/lib/docker}" "$C_RESET"
    _dr_row "Application images" "$(( DR_IMG_APP_KEPT + DR_IMG_APP_STALE ))" "$total" \
        "$( (( DR_IMG_APP_STALE_COUNT > 0 )) && printf '%s old build(s) removable' "$DR_IMG_APP_STALE_COUNT" )"
    _dr_row "Supabase images" "$(( DR_IMG_SB_KEPT + DR_IMG_SB_STALE ))" "$total" \
        "$( (( DR_IMG_SB_STALE_COUNT > 0 )) && printf '%s superseded removable' "$DR_IMG_SB_STALE_COUNT" )"
    _dr_row "Container logs" "$DR_CTR_LOGS" "$total" \
        "$( (( DR_CTR_LOGS_UNLIMITED > 0 )) && printf '%s container(s) without a limit' "$DR_CTR_LOGS_UNLIMITED" )"
    local name bytes how shown=0 rows count
    rows="$(grep -v '|0|' <<<"$DR_CTR_LOG_ROWS" | head -n 5 || true)"
    count="$(grep -c . <<<"$rows" || true)"
    while IFS='|' read -r name bytes how; do
        [[ -n "$name" ]] || continue
        shown=$(( shown + 1 ))
        if (( shown == count )); then
            _dr_sub "$DR_TREE_END" "$name" "$bytes" "$how"
        else
            _dr_sub "$DR_TREE_MID" "$name" "$bytes" "$how"
        fi
    done <<<"$rows"
    _dr_row "Container layers" "$DR_CTR_RW" "$total" "files written inside containers"
    if (( DR_VOLUMES > 0 )); then
        _dr_row "Docker volumes" "$DR_VOLUMES" "$total" "named volumes of the Supabase project"
    fi
    return 0
}

dr_render_database() {
    [[ "$DR_DB_OK" == "true" ]] || return 0
    local db_total name bytes note
    db_total="$(cut -d'|' -f2 <<<"$DR_DB_DATABASES" | _dr_sum)"
    section "Inside the database - $(human_bytes "$db_total")"
    while IFS='|' read -r name bytes; do
        [[ -n "$name" ]] || continue
        note=""
        if [[ "$name" == "_supabase" ]]; then
            note="Supabase internals"
            [[ -n "$DR_ANALYTICS" ]] && note+="; Logflare logs $(human_bytes "$DR_ANALYTICS")"
        fi
        [[ "$name" == "$(_db_name)" ]] && note="application, Auth, Storage metadata"
        _dr_row "database ${name}" "$bytes" "$db_total" "$note"
    done <<<"$DR_DB_DATABASES"

    [[ -n "$DR_DB_TABLES" ]] || return 0
    printf '\n  Largest tables in %s\n' "$(_db_name)"
    while IFS='|' read -r name bytes; do
        [[ -n "$name" ]] || continue
        printf '    %-44s %11s  %s%s%s\n' "$name" "$(human_bytes "$bytes")" "$C_DIM" "$(_dr_table_note "$name")" "$C_RESET"
    done <<<"$DR_DB_TABLES"
    return 0
}

dr_render_host() {
    [[ -n "$DR_HOST_ROWS" ]] || return 0
    section "Outside Sentinel Ops (for comparison)"
    local label bytes
    while IFS='|' read -r label bytes; do
        [[ -n "$label" ]] || continue
        printf '  %-28s %11s\n' "$label" "$(human_bytes "$bytes")"
    done <<<"$DR_HOST_ROWS"
    printf '  %sThese are not touched by sentinel-ops.%s\n' "$C_DIM" "$C_RESET"
}

# What `disk prune` can do now: "target|label|bytes|note", one per target
# with something to give.
dr_reclaimable_rows() {
    local img=$(( DR_IMG_APP_STALE + DR_IMG_SB_STALE + DR_BUILD_CACHE_RECLAIM ))
    if (( DR_BACKUPS_PRUNABLE > 0 )); then
        printf 'backups|Backups past retention|%s|%s oldest backup(s)\n' "$DR_BACKUPS_PRUNABLE" "$DR_BACKUPS_PRUNABLE_COUNT"
    fi
    if (( DR_LOGS_OLD > 0 )); then
        printf 'logs|Installer logs past %s days|%s|%s file(s)\n' \
            "$(logs_retention_days 2>/dev/null)" "$DR_LOGS_OLD" "$DR_LOGS_OLD_COUNT"
    fi
    if (( img > 0 )); then
        printf 'images|Old images and build cache|%s|up to; layers are shared between images\n' "$img"
    fi
    return 0
}

dr_render_reclaimable() {
    local rows target label bytes note n=0
    rows="$(dr_reclaimable_rows)"
    section "Can be reclaimed"
    if [[ -z "$rows" ]]; then
        printf '  %s%s Nothing past its limit.%s\n' "$C_GREEN" "$SYM_OK" "$C_RESET"
    else
        while IFS='|' read -r target label bytes note; do
            [[ -n "$target" ]] || continue
            n=$(( n + 1 ))
            printf '  %2d. %-38s %11s  %s%s%s\n' "$n" "$label" "$(human_bytes "$bytes")" "$C_DIM" "$note" "$C_RESET"
        done <<<"$rows"
        printf '\n  %sKept always: the database, Storage files, the deployed and rollback images, backups within retention.%s\n' \
            "$C_DIM" "$C_RESET"
    fi

    # Bigger levers that are not `disk prune`'s to pull: each has its own
    # command, with its own confirmation.
    local hints=""
    if [[ -n "$DR_ANALYTICS" ]] && (( DR_ANALYTICS > 1073741824 )); then
        hints+="  Logflare logs take $(human_bytes "$DR_ANALYTICS"): sentinel-ops logflare purge, or logflare retention <days>"$'\n'
    fi
    if (( DR_CTR_LOGS_UNLIMITED > 0 )); then
        hints+="  ${DR_CTR_LOGS_UNLIMITED} container(s) log without a size limit: sentinel-ops repair apply (recreating them also drops their old logs)"$'\n'
    fi
    if (( DR_DB_WAL > 2147483648 )); then
        hints+="  The write-ahead log is $(human_bytes "$DR_DB_WAL"); a replication slot nobody reads holds it back: select slot_name, active from pg_replication_slots;"$'\n'
    fi
    if [[ -n "$hints" ]]; then
        printf '\n  %sAlso worth a look%s\n%s' "$C_BOLD" "$C_RESET" "$hints"
    fi
    return 0
}

dr_render_all() {
    dr_render_filesystems
    dr_render_stack
    dr_render_database
    dr_render_host
    dr_render_reclaimable
    printf '\n'
}

# ---------------------------------------------------------------------------
# Reclaiming - the existing prune functions, one target at a time
# ---------------------------------------------------------------------------

# Validate and expand target names ("all" is every target). Prints them one
# per line, in a fixed order; an unknown name fails.
dr_resolve_targets() {
    local t want=" "
    for t in "$@"; do
        case "$t" in
            all) want+="${DR_PRUNE_TARGETS[*]} " ;;
            backups|logs|images) want+="$t " ;;
            *) log_error "Unknown prune target: ${t}"; return 2 ;;
        esac
    done
    for t in "${DR_PRUNE_TARGETS[@]}"; do
        [[ "$want" == *" $t "* ]] && printf '%s\n' "$t"
    done
    return 0
}

# dr_prune_target <backups|logs|images> [--dry-run]
dr_prune_target() {
    local target="$1" dry="${2:-}"
    case "$target" in
        backups) backup_prune_local "$dry" ;;
        logs)    logs_prune_installer "$dry" ;;
        images)
            if ! docker_daemon_ok; then
                log_warn "Docker is not available; images were not cleaned up."
                return 0
            fi
            if [[ "$dry" == "--dry-run" ]]; then SO_IMAGES_DRY_RUN="true"; else SO_IMAGES_DRY_RUN="false"; fi
            images_prune_app
            if supabase_installed; then images_prune_supabase; fi
            images_prune_build_cache
            ;;
    esac
    return 0
}
