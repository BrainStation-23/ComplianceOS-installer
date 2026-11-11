#!/usr/bin/env bash
# lib/backup.sh - full-stack backups: Postgres (less its log data), Storage,
# edge functions and enough config to rebuild the install, plus local
# retention and the shared restore implementation.
#
# Each backup is a single directory per cycle (see backup_create()) so
# that restic (lib/restic.sh) can back up exactly that directory for the
# offsite/secondary copies, and a restic-sourced restore reproduces the
# identical shape a local restore already reads - one restore implementation
# regardless of source. See docs/BACKUPS.md.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Local backup creation
# ---------------------------------------------------------------------------

# Files a full-stack backup directory can contain, in the order a restore
# applies them (database always; the rest only for scope=full).
BACKUP_ARCHIVE_FILES=(storage.tar.gz functions.tar.gz config.tar.gz)

# Free space a backup must leave behind, on top of its own estimated size:
# filling the disk to the last byte takes the database down with it.
BACKUP_FREE_SPACE_RESERVE_BYTES=1073741824

# The database dump. Backups from before the dump was compressed and filtered
# hold database.sql instead; restore reads either (_backup_db_file).
BACKUP_DB_FILE="database.sql.gz"
BACKUP_DB_FILE_LEGACY="database.sql"

# Tables whose *data* a backup leaves out, as "<database>:<schema>.<table>"
# with pg_dump-style * wildcards. Their definitions are still dumped, so a
# restore recreates them empty. Everything here is logs, telemetry or state
# the application rebuilds on its own - never business data, users, secrets
# or audit trails (user_activity_logs, command_audit_logs, *_change_audit stay
# in: for a compliance product they are evidence). See docs/DECISIONS.md #35, #36.
#
# This is deliberately not the application's backup_table_registry: that is
# the allowlist of the in-app JSONL export, which leaves out auth, vault, MDM
# CAs and recovery keys for security reasons - exactly what a disaster
# recovery copy must have.
BACKUP_EXCLUDE_DATA_DEFAULT=(
    # Logflare's log store (docs/LOGFLARE.md): every container's log lines.
    '_supabase:_analytics.*'
    # Supabase housekeeping that grows without bound.
    'postgres:auth.audit_log_entries'
    'postgres:net._http_response'
    'postgres:cron.job_run_details'
    'postgres:pgmq.a_*'
    'postgres:realtime.messages*'
    # Application tables its own backup registry marks derived, rolling or
    # transient (sentinel-ops supabase/migrations, backup_table_registry).
    'postgres:public.agent_power_windows'
    'postgres:public.agent_awake_hours'
    'postgres:public.dlp_file_health_samples'
    'postgres:public.dlp_event_merges'
    'postgres:public.yara_event_receipts'
    'postgres:public.yara_agent_event_counters'
    'postgres:public.compliance_check_results'
    'postgres:public.compliance_agent_results'
    'postgres:public.compliance_org_check_results'
    'postgres:public.compliance_eval_pending'
    'postgres:public.storage_sweep_runs'
    'postgres:public.software_catalog_enrich_runs'
    'postgres:public.integration_sync_runs'
    # Agent log ingest, despite the name: daily partitions audit_logs_y*m*d*
    # plus audit_logs_default, which the app itself drops after 7 days. The *
    # is needed: pg_dump writes each partition's data separately, so leaving
    # out only the parent would still dump every row (PG15 has no
    # --exclude-table-data-and-children).
    'postgres:public.audit_logs*'
)

# The in-app backups' bucket. Those backups are already copies (to their own
# destinations); archiving them again inside every full installer backup only
# doubles their size. A path in the Storage volume: <tenant>/<ns>/<bucket>.
BACKUP_STORAGE_EXCLUDE_BUCKETS=(backups)

# backup_create <label> [full|db]
#
# Dump the database, archive Storage/functions/secrets, checksum and record
# what was running at the time. Prints the backup directory on stdout.
#
# A "db" backup leaves Storage out. It is what runs before every application
# update: those only change the database, functions and frontend, and Storage
# holds installer binaries of up to 4 GiB each - copying all of it again on
# every (unattended) update is what filled disks. See docs/DECISIONS.md #34.
backup_create() {
    local label="${1:-manual}" scope="${2:-full}"
    local cid stamp dir

    case "$scope" in full|db) ;; *) log_error "Unknown backup scope: ${scope}" >&2; return 1 ;; esac

    if ! cid="$(_db_container)"; then
        log_error "Cannot back up: the database is not running."
        return 1
    fi

    # Apply the current retention first: a limit lowered since the last
    # backup frees its space before this one is measured against it.
    backup_prune_local
    _backup_check_room "$scope" "$cid" || return 1

    stamp="$(timestamp)"
    dir="${BACKUP_DIR}/${stamp}"
    mkdir -p "$dir"

    log_info "Backing up the database to ${dir}..." >&2
    if ! _backup_dump_with_progress "$cid" "${dir}/${BACKUP_DB_FILE}"; then
        log_error "Database dump failed." >&2
        rm -rf "$dir"
        return 1
    fi

    # A failed archive fails the whole backup. Keeping it would leave a
    # truncated file that checksums.txt then vouches for (on a full disk,
    # exactly the backup someone reaches for).
    if [[ "$scope" == "full" && -d "${SUPABASE_DIR}/volumes/storage" ]]; then
        log_info "Archiving Storage..." >&2
        local storage_args=()
        mapfile -t storage_args < <(_backup_storage_exclude_args)
        _backup_archive "$dir" storage.tar.gz "${storage_args[@]}" -C "${SUPABASE_DIR}/volumes" storage || return 1
    fi
    if [[ -d "${SUPABASE_DIR}/volumes/functions" ]]; then
        log_info "Archiving edge functions..." >&2
        _backup_archive "$dir" functions.tar.gz -C "${SUPABASE_DIR}/volumes" functions || return 1
    fi

    # config.tar.gz holds supabase/.env (JWT_SECRET, POSTGRES_PASSWORD, API
    # keys), installer.env and the deploy key - everything a fresh box needs
    # besides this directory itself to reconstitute the install. Locked down
    # immediately since tar has no atomic "create with these permissions".
    if [[ -f "${SUPABASE_DIR}/.env" ]]; then
        local config_args=(-C "$SUPABASE_DIR" .env)
        [[ -f "${CONFIG_DIR}/installer.env" ]] && config_args+=(-C "$CONFIG_DIR" installer.env)
        [[ -f "${CONFIG_DIR}/deploy_key" ]] && config_args+=(-C "$CONFIG_DIR" deploy_key)
        _backup_archive "$dir" config.tar.gz "${config_args[@]}" || return 1
        chmod 600 "${dir}/config.tar.gz"
    fi

    _backup_metadata_write "$dir" "$label" "$scope"
    _backup_checksum_write "$dir"

    chmod 700 "$dir" 2>/dev/null || true
    log_ok "Backup created: ${dir} (${scope}, $(human_bytes "$(disk_used_bytes "$dir")"))" >&2

    backup_prune_local
    printf '%s' "$dir"
    return 0
}

# _backup_archive <dir> <archive> <tar args...> - on failure the whole backup
# directory goes, and the caller fails the backup.
_backup_archive() {
    local dir="$1" name="$2"
    shift 2
    if tar -czf "${dir}/${name}" "$@" 2>>"${SO_LOG_FILE:-/dev/null}"; then
        return 0
    fi
    log_error "Could not write ${name}; the backup was discarded. Is the disk full? (df -h ${BACKUP_DIR})" >&2
    rm -rf "$dir"
    return 1
}

# ---------------------------------------------------------------------------
# The database dump - roles, then each database with log data left out
# ---------------------------------------------------------------------------

# Every "<database>:<pattern>" whose data a backup leaves out, one per line:
# the built-in list plus BACKUP_EXCLUDE_DATA, or nothing at all when
# BACKUP_INCLUDE_LOG_DATA is true.
backup_exclude_data_entries() {
    [[ "${BACKUP_INCLUDE_LOG_DATA:-false}" == "true" ]] && return 0
    local entry extra=()
    read -r -a extra <<<"${BACKUP_EXCLUDE_DATA:-}"
    for entry in "${BACKUP_EXCLUDE_DATA_DEFAULT[@]}" "${extra[@]}"; do
        [[ -n "$entry" ]] || continue
        if [[ "$entry" != ?*:?*.?* ]]; then
            log_warn "Ignoring BACKUP_EXCLUDE_DATA entry '${entry}': expected <database>:<schema>.<table>." >&2
            continue
        fi
        printf '%s\n' "$entry"
    done
}

# The patterns for one database, one per line.
# _backup_exclude_patterns <database>
_backup_exclude_patterns() {
    local db="$1" entry
    while IFS= read -r entry; do
        [[ "${entry%%:*}" == "$db" ]] && printf '%s\n' "${entry#*:}"
    done < <(backup_exclude_data_entries)
    return 0
}

# pg_dump flags for one database, one per line.
_backup_exclude_args() {
    local pat
    while IFS= read -r pat; do
        [[ -n "$pat" ]] && printf -- '--exclude-table-data=%s\n' "$pat"
    done < <(_backup_exclude_patterns "$1")
    return 0
}

# Whether <schema.table> in <database> is on the exclusion list. pg_dump's *
# and bash's glob * agree for these patterns, so this predicts what pg_dump
# leaves out without asking it.
# _backup_table_excluded <database> <schema.table>
_backup_table_excluded() {
    local pats=()
    mapfile -t pats < <(_backup_exclude_patterns "$1")
    _backup_matches_any "$2" "${pats[@]}"
}

# _backup_matches_any <schema.table> <pattern>...
_backup_matches_any() {
    local table="$1" pat
    shift
    for pat in "$@"; do
        # shellcheck disable=SC2053 # the pattern is meant to glob
        [[ -n "$pat" && "$table" == $pat ]] && return 0
    done
    return 1
}

# The databases a dump covers: every one that takes connections.
_backup_databases() {
    docker exec -e PGPASSWORD="$(_db_pass)" "$1" \
        psql -U "$(_db_user)" -d "$(_db_name)" -tAc \
        'SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname' \
        2>>"${SO_LOG_FILE:-/dev/null}" | tr -d '\r'
}

# _backup_dump_stream <db-container>
#
# Write one plain SQL script to stdout that psql replays into a running
# stack: roles first (pg_dumpall --globals-only), then each database's
# pg_dump after a \connect to it. This is what pg_dumpall produced before,
# except that pg_dumpall cannot leave table data out - and the log tables
# were most of every backup.
#
# No --create: Supabase creates its databases itself, and dropping
# _supabase while Logflare is connected to it would fail the restore.
#
# With BACKUP_PROGRESS_DIR set (_backup_dump_with_progress), pg_dump runs
# --verbose into ${BACKUP_PROGRESS_DIR}/pg_dump.log, and the database being
# dumped is written to ${BACKUP_PROGRESS_DIR}/database.
_backup_dump_stream() {
    local cid="$1" db dbs=() args=() n=0 err="${SO_LOG_FILE:-/dev/null}" verbose=()
    mapfile -t dbs < <(_backup_databases "$cid")
    if (( ${#dbs[@]} == 0 )); then
        log_error "Could not list the databases to back up." >&2
        return 1
    fi
    if [[ -n "${BACKUP_PROGRESS_DIR:-}" ]]; then
        err="${BACKUP_PROGRESS_DIR}/pg_dump.log"
        verbose=(--verbose)
    fi
    docker exec -e PGPASSWORD="$(_db_pass)" "$cid" \
        pg_dumpall -U "$(_db_user)" --globals-only --clean --if-exists \
        2>>"$err" || return 1
    for db in "${dbs[@]}"; do
        [[ -n "$db" ]] || continue
        n=$(( n + 1 ))
        [[ -n "${BACKUP_PROGRESS_DIR:-}" ]] && printf '%s (%d/%d)\n' "$db" "$n" "${#dbs[@]}" >"${BACKUP_PROGRESS_DIR}/database"
        mapfile -t args < <(_backup_exclude_args "$db")
        printf '\n\\connect "%s"\n\n' "$db"
        docker exec -e PGPASSWORD="$(_db_pass)" "$cid" \
            pg_dump -U "$(_db_user)" -d "$db" --clean --if-exists "${verbose[@]}" "${args[@]}" \
            2>>"$err" || return 1
    done
}

# ---------------------------------------------------------------------------
# Progress while dumping
#
# A large database takes minutes to dump, and the dump used to print nothing
# until it finished, so an update looked stuck. While it runs this shows how
# much has been dumped (of about how much), how much is on disk, the rate,
# the elapsed time and the table being dumped: on a terminal as one line
# redrawn in place, otherwise (logs, scheduled backups, auto-update) as a log
# line every BACKUP_PROGRESS_INTERVAL seconds. Everything goes to stderr:
# callers read the backup directory from stdout.
# ---------------------------------------------------------------------------

BACKUP_PROGRESS_INTERVAL="${BACKUP_PROGRESS_INTERVAL:-30}"

# Whether this dd reports bytes copied (GNU coreutils' status=progress).
_backup_dd_progress_supported() {
    dd if=/dev/null of=/dev/null status=progress 2>/dev/null
}

# stdin to stdout, unchanged, with the bytes copied so far reported into $1.
_backup_count_bytes() {
    if _backup_dd_progress_supported; then
        dd bs=1M status=progress 2>"$1"
    else
        cat
    fi
}

# Bytes copied so far, from _backup_count_bytes' report; empty when unknown.
_backup_counted_bytes() {
    [[ -s "$1" ]] || return 0
    tr '\r' '\n' <"$1" | grep -oE '^[0-9]+ bytes' | tail -n 1 | cut -d' ' -f1 || true
}

# The table pg_dump is writing now, from its --verbose output.
_backup_current_table() {
    [[ -s "$1" ]] || return 0
    grep -oE 'dumping contents of table "[^"]+"' "$1" | tail -n 1 \
        | sed -E 's/dumping contents of table "([^"]+)"/\1/' || true
}

# Table data the dump will write, roughly: the size of every table's data
# (indexes aren't dumped) in every database, less the tables left out.
_backup_data_estimate() {
    local cid="$1" db name bytes total=0 pats=()
    while IFS= read -r db; do
        [[ -n "$db" ]] || continue
        mapfile -t pats < <(_backup_exclude_patterns "$db")
        while IFS='|' read -r name bytes; do
            [[ "$bytes" =~ ^[0-9]+$ ]] || continue
            (( ${#pats[@]} )) && _backup_matches_any "$name" "${pats[@]}" && continue
            total=$(( total + bytes ))
        done < <(docker exec -e PGPASSWORD="$(_db_pass)" "$cid" \
                    psql -U "$(_db_user)" -d "$db" -tAF'|' -c \
                    "SELECT n.nspname || '.' || c.relname, pg_table_size(c.oid)
                       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE c.relkind IN ('r', 'm')" 2>>"${SO_LOG_FILE:-/dev/null}" | tr -d '\r')
    done < <(_backup_databases "$cid")
    printf '%s' "$total"
}

_backup_duration() {
    local s="$1"
    if (( s >= 3600 )); then printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
    elif (( s >= 60 )); then printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    else printf '%ds' "$s"; fi
}

# One progress line. _backup_progress_line <dumped> <estimate> <written> <seconds> <database> <table>
_backup_progress_line() {
    local dumped="$1" estimate="$2" written="$3" secs="$4" db="$5" table="$6" line pct
    if [[ "$dumped" =~ ^[0-9]+$ ]]; then
        line="$(human_bytes "$dumped") dumped"
        if [[ "$estimate" =~ ^[0-9]+$ ]] && (( estimate > 0 )); then
            pct=$(( dumped * 100 / estimate ))
            (( pct > 99 )) && pct=99
            line+=" of about $(human_bytes "$estimate") (${pct}%)"
        fi
        line+=", $(human_bytes "$written") written"
        (( secs > 0 )) && line+=", $(human_bytes $(( dumped / secs )))/s"
    else
        line="$(human_bytes "$written") written"
    fi
    line+=", $(_backup_duration "$secs")"
    [[ -n "$db" ]] && line+=" - ${db}"
    [[ -n "$table" ]] && line+=": ${table}"
    printf '%s' "$line"
}

# _backup_dump_with_progress <db-container> <output .sql.gz>
_backup_dump_with_progress() {
    local cid="$1" out="$2" work estimate pid rc=0 start=$SECONDS secs last=0 tty="false" line
    work="$(mktemp -d)" || return 1
    estimate="$(_backup_data_estimate "$cid" 2>/dev/null)" || estimate=""
    # BACKUP_PROGRESS_TTY=true|false overrides the terminal check (tests).
    case "${BACKUP_PROGRESS_TTY:-auto}" in
        true|false) tty="$BACKUP_PROGRESS_TTY" ;;
        *) [[ -t 2 ]] && tty="true" ;;
    esac

    ( set -o pipefail
      BACKUP_PROGRESS_DIR="$work" _backup_dump_stream "$cid" \
          | _backup_count_bytes "${work}/bytes" \
          | _backup_gzip >"$out" ) &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        secs=$(( SECONDS - start ))
        if [[ "$tty" == "true" ]]; then
            (( secs % 2 == 0 )) || continue
        elif (( secs - last < BACKUP_PROGRESS_INTERVAL )); then
            continue
        fi
        last=$secs
        line="$(_backup_progress_line "$(_backup_counted_bytes "${work}/bytes")" "$estimate" \
            "$(stat -c%s "$out" 2>/dev/null || printf '0')" "$secs" \
            "$(cat "${work}/database" 2>/dev/null || true)" "$(_backup_current_table "${work}/pg_dump.log")")"
        if [[ "$tty" == "true" ]]; then
            printf '\r\033[K        %s' "$line" >&2
        else
            log_info "  ${line}" >&2
        fi
    done
    wait "$pid" || rc=$?
    [[ "$tty" == "true" ]] && printf '\r\033[K' >&2

    # pg_dump's --verbose output stays out of the log; its warnings and
    # errors don't.
    [[ -s "${work}/pg_dump.log" && -n "${SO_LOG_FILE:-}" ]] && \
        grep -iE 'error|warning|fatal|detail|hint' "${work}/pg_dump.log" 2>/dev/null >>"$SO_LOG_FILE" || true
    if (( rc != 0 )); then
        grep -iE 'error|fatal' "${work}/pg_dump.log" 2>/dev/null | tail -n 5 | sed 's/^/        /' >&2 || true
    else
        secs=$(( SECONDS - start ))
        log_info "  Dumped $(human_bytes "$(_backup_counted_bytes "${work}/bytes" | grep . || stat -c%s "$out")") in $(_backup_duration "$secs") ($(human_bytes "$(stat -c%s "$out" 2>/dev/null || printf '0')") compressed)" >&2
    fi
    rm -rf "$work"
    return "$rc"
}

# gzip from stdin to stdout. --rsyncable keeps unchanged stretches of the
# dump byte-identical after compression, so restic still deduplicates
# across snapshots; older gzips without it fall back to plain gzip.
_backup_gzip() {
    if gzip --rsyncable -c </dev/null >/dev/null 2>&1; then
        gzip --rsyncable -c
    else
        gzip -c
    fi
}

# The dump file in a backup directory, either format; nothing if none.
_backup_db_file() {
    local dir="$1" f
    for f in "$BACKUP_DB_FILE" "$BACKUP_DB_FILE_LEGACY"; do
        [[ -f "${dir}/${f}" ]] && { printf '%s' "${dir}/${f}"; return 0; }
    done
    return 1
}

# Feed a backup's dump to stdout, uncompressed.
_backup_db_cat() {
    case "$1" in
        *.gz) gzip -dc "$1" ;;
        *)    cat "$1" ;;
    esac
}

# tar options leaving BACKUP_STORAGE_EXCLUDE_BUCKETS out of storage.tar.gz,
# one per line. Anchored and without * crossing a /, so only the bucket
# directory itself matches - not an object that happens to be called
# "backups" somewhere inside another bucket.
_backup_storage_exclude_args() {
    local bucket
    (( ${#BACKUP_STORAGE_EXCLUDE_BUCKETS[@]} )) || return 0
    printf '%s\n' --anchored --no-wildcards-match-slash
    for bucket in "${BACKUP_STORAGE_EXCLUDE_BUCKETS[@]}"; do
        printf -- '--exclude=storage/*/*/%s\n' "$bucket"
    done
}

# Bytes in the Storage volume a full backup leaves out.
_backup_storage_excluded_bytes() {
    local root="${SUPABASE_DIR}/volumes/storage" bucket d total=0
    for bucket in "${BACKUP_STORAGE_EXCLUDE_BUCKETS[@]}"; do
        for d in "$root"/*/*/"$bucket"; do
            [[ -d "$d" ]] && total=$(( total + $(disk_used_bytes "$d") ))
        done
    done
    printf '%s' "$total"
}

# "<schema.table>|<bytes>" for every table in a database, largest first.
# _backup_table_sizes <db-container> <database>
_backup_table_sizes() {
    docker exec -e PGPASSWORD="$(_db_pass)" "$1" \
        psql -U "$(_db_user)" -d "$2" -tAF'|' -c \
        "SELECT n.nspname || '.' || c.relname, pg_total_relation_size(c.oid)
           FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relkind IN ('r', 'm')
          ORDER BY 2 DESC" 2>>"${SO_LOG_FILE:-/dev/null}" | tr -d '\r'
}

# Bytes of table data in one database that the dump leaves out.
_backup_excluded_db_bytes() {
    local cid="$1" db="$2" name bytes total=0 pats=()
    mapfile -t pats < <(_backup_exclude_patterns "$db")
    (( ${#pats[@]} )) || { printf '0'; return 0; }
    while IFS='|' read -r name bytes; do
        [[ "$bytes" =~ ^[0-9]+$ ]] || continue
        _backup_matches_any "$name" "${pats[@]}" && total=$(( total + bytes ))
    done < <(_backup_table_sizes "$cid" "$db")
    printf '%s' "$total"
}

# ---------------------------------------------------------------------------
# Free space - refuse a backup that would fill the disk
# ---------------------------------------------------------------------------

# Rough size of a new backup: the databases as Postgres stores them, less the
# table data the dump leaves out, plus Storage (less its excluded buckets)
# when included. A compressed dump comes out well under this, so the
# free-space check it feeds stays on the safe side.
# _backup_estimate_bytes <full|db> <db-container>
_backup_estimate_bytes() {
    local scope="$1" cid="$2" db excluded=0 d
    db="$(docker exec -e PGPASSWORD="$(_db_pass)" "$cid" \
        psql -U "$(_db_user)" -d "$(_db_name)" -tAc \
        'SELECT sum(pg_database_size(datname))::bigint FROM pg_database' 2>/dev/null | tr -d '[:space:]')" || true
    [[ "$db" =~ ^[0-9]+$ ]] || db=0
    while IFS= read -r d; do
        [[ -n "$d" ]] && excluded=$(( excluded + $(_backup_excluded_db_bytes "$cid" "$d") ))
    done < <(backup_exclude_data_entries | cut -d: -f1 | LC_ALL=C sort -u)
    db=$(( db > excluded ? db - excluded : 0 ))
    if [[ "$scope" == "full" && -d "${SUPABASE_DIR}/volumes/storage" ]]; then
        local storage
        storage=$(( $(disk_used_bytes "${SUPABASE_DIR}/volumes/storage") - $(_backup_storage_excluded_bytes) ))
        (( storage > 0 )) && db=$(( db + storage ))
    fi
    printf '%s' "$db"
}

# _backup_fits <estimated-bytes> <free-bytes>: room for the backup plus 10%
# and BACKUP_FREE_SPACE_RESERVE_BYTES left over.
_backup_fits() {
    local need="$1" free="$2"
    (( free >= need + need / 10 + BACKUP_FREE_SPACE_RESERVE_BYTES ))
}

_backup_check_room() {
    local scope="$1" cid="$2" need free
    free="$(disk_free_bytes "$BACKUP_DIR")"
    # A filesystem df cannot read is not a reason to refuse a backup.
    [[ -n "$free" ]] || return 0
    need="$(_backup_estimate_bytes "$scope" "$cid")"
    _backup_fits "$need" "$free" && return 0
    log_error "Not enough free space for a ${scope} backup: it needs about $(human_bytes "$need") plus $(human_bytes "$BACKUP_FREE_SPACE_RESERVE_BYTES") spare, and ${BACKUP_DIR} has $(human_bytes "$free") free." >&2
    log_error "Free space with: sentinel-ops cleanup (or lower BACKUP_RETENTION_COUNT / BACKUP_RETENTION_MAX_GB in config/installer.env)." >&2
    return 1
}

# ---------------------------------------------------------------------------
# Metadata and checksums - pure, file-only, no Docker
# ---------------------------------------------------------------------------

_backup_metadata_write() {
    local dir="$1" label="$2" scope="${3:-full}"
    {
        printf 'timestamp=%s\n'         "$(date -Is 2>/dev/null || date)"
        printf 'reason=%s\n'            "$label"
        printf 'scope=%s\n'             "$scope"
        printf 'installer_version=%s\n' "$SO_INSTALLER_VERSION"
        printf 'supabase_version=%s\n'  "$(supabase_current_version)"
        printf 'app_commit=%s\n'        "$(state_get APP_COMMIT unknown)"
        printf 'app_branch=%s\n'        "$APP_BRANCH"
        printf 'app_image=%s\n'         "$(state_get APP_IMAGE unknown)"
        printf 'size_bytes=%s\n'        "$(stat -c%s "$(_backup_db_file "$dir")" 2>/dev/null || printf '0')"
        # What the dump left out, so a restore can say which tables come back
        # empty. Absent on backups from before exclusions existed.
        printf 'excluded_data=%s\n'     "$(backup_exclude_data_entries 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
        [[ "$scope" == "full" ]] && \
            printf 'excluded_storage_buckets=%s\n' "${BACKUP_STORAGE_EXCLUDE_BUCKETS[*]}"
    } >"${dir}/metadata.txt"
}

# Write a sha256sum-compatible checksums.txt for every backup file present.
_backup_checksum_write() {
    local dir="$1" f hash
    : >"${dir}/checksums.txt"
    for f in "$BACKUP_DB_FILE" "$BACKUP_DB_FILE_LEGACY" "${BACKUP_ARCHIVE_FILES[@]}"; do
        [[ -f "${dir}/${f}" ]] || continue
        hash="$(file_sha256 "${dir}/${f}")" || continue
        printf '%s  %s\n' "$hash" "$f" >>"${dir}/checksums.txt"
    done
}

# Recompute every checksum in dir/checksums.txt and compare. Prints the first
# mismatching/missing file and returns non-zero on any failure.
_backup_checksum_verify() {
    local dir="$1" line hash file actual
    [[ -f "${dir}/checksums.txt" ]] || { log_error "No checksums.txt in ${dir}"; return 1; }
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        hash="${line%%  *}"
        file="${line#*  }"
        if [[ ! -f "${dir}/${file}" ]]; then
            log_error "Backup file missing: ${dir}/${file}"
            return 1
        fi
        actual="$(file_sha256 "${dir}/${file}")"
        if [[ "$actual" != "$hash" ]]; then
            log_error "Checksum mismatch for ${dir}/${file}"
            return 1
        fi
    done <"${dir}/checksums.txt"
    return 0
}

# ---------------------------------------------------------------------------
# Retention and listing - pure filesystem logic
# ---------------------------------------------------------------------------

# "full" or "db". Backups from before scopes existed were all full.
backup_scope() {
    local scope
    scope="$(env_get "${1}/metadata.txt" scope 2>/dev/null || true)"
    [[ "$scope" == "db" ]] && printf 'db' || printf 'full'
}

# BACKUP_RETENTION_COUNT as a positive count; a hand-edited value that is not
# one falls back to the default rather than reaching shell arithmetic.
backup_retention_count() {
    if [[ "$BACKUP_RETENTION_COUNT" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s' "$BACKUP_RETENTION_COUNT"
    else
        log_warn "BACKUP_RETENTION_COUNT='${BACKUP_RETENTION_COUNT}' is not a positive number; using 10." >&2
        printf '10'
    fi
}

# The most local backups may take in total, in bytes; nothing when there is
# no limit. BACKUP_RETENTION_MAX_GB is a number of GiB, 0 for no limit, or
# "auto" for a fifth of the filesystem the backups live on.
backup_retention_max_bytes() {
    local gb="$BACKUP_RETENTION_MAX_GB" size
    if [[ "$gb" =~ ^[0-9]+$ ]]; then
        (( gb > 0 )) && printf '%s' "$(( gb * DISK_GIB ))"
        return 0
    fi
    [[ -z "$gb" || "$gb" == "auto" ]] || \
        log_warn "BACKUP_RETENTION_MAX_GB='${gb}' is not a number of GB, 0 or auto; using auto." >&2
    size="$(disk_size_bytes "$BACKUP_DIR")"
    [[ -n "$size" ]] && printf '%s' "$(( size / 5 ))"
    return 0
}

# Print the backups retention removes, oldest first:
#
#   1. everything past the newest BACKUP_RETENTION_COUNT;
#   2. then, oldest first, until the rest fit in the size limit.
#
# The newest backup and the newest full backup are never removed - the
# latter is the only local copy of Storage, and a run of database-only
# backups before updates must not push it out. So the count can be exceeded
# by one, and the size limit by those two.
_backup_prune_candidates() {
    local dirs=() sizes=() i count limit cap total=0 newest_full=-1
    mapfile -t dirs < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)
    count="${#dirs[@]}"
    (( count > 0 )) || return 0
    limit="$(backup_retention_count)"
    cap="$(backup_retention_max_bytes)"

    for (( i = count - 1; i >= 0; i-- )); do
        if [[ "$(backup_scope "${dirs[i]}")" == "full" ]]; then
            newest_full="$i"; break
        fi
    done

    local -a doomed=()
    for (( i = 0; i < count; i++ )); do
        doomed[i]=0
        (( i == count - 1 || i == newest_full )) && continue
        (( i < count - limit )) && doomed[i]=1
    done

    if [[ -n "$cap" ]]; then
        for (( i = 0; i < count; i++ )); do
            sizes[i]="$(disk_used_bytes "${dirs[i]}")"
            (( doomed[i] )) || total=$(( total + sizes[i] ))
        done
        for (( i = 0; i < count && total > cap; i++ )); do
            (( doomed[i] || i == count - 1 || i == newest_full )) && continue
            doomed[i]=1
            total=$(( total - sizes[i] ))
        done
    fi

    for (( i = 0; i < count; i++ )); do
        (( doomed[i] )) && printf '%s\n' "${dirs[i]}"
    done
    return 0
}

# Apply local retention (see _backup_prune_candidates). Logs to stderr:
# backup_create's stdout is the new backup's path.
# backup_prune_local [--dry-run]
backup_prune_local() {
    local dry="${1:-}" old n=0 freed=0 size
    while IFS= read -r old; do
        [[ -n "$old" ]] || continue
        size="$(disk_used_bytes "$old")"
        if [[ "$dry" == "--dry-run" ]]; then
            printf '  would remove backup %s (%s)\n' "$(basename "$old")" "$(human_bytes "$size")" >&2
        else
            log_debug "pruning old backup ${old}"
            rm -rf "$old" || continue
        fi
        n=$((n + 1))
        freed=$((freed + size))
    done < <(_backup_prune_candidates)
    if [[ "$dry" == "--dry-run" ]]; then
        log_ok "Backups: would remove ${n} old backup(s), $(human_bytes "$freed")" >&2
    elif (( n > 0 )); then
        log_ok "Backups: removed ${n} old backup(s), $(human_bytes "$freed") freed" >&2
    fi
    return 0
}

backup_latest() {
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | tail -n1
}

# Print "dir|size|reason|scope" for every local backup, newest first. The
# size is the whole backup's, Storage included.
backup_list_entries() {
    local d
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort -r \
        | while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            printf '%s|%s|%s|%s\n' \
                "$d" \
                "$(human_bytes "$(disk_used_bytes "$d")")" \
                "$(env_get "${d}/metadata.txt" reason 2>/dev/null || printf '-')" \
                "$(backup_scope "$d")"
        done
}

# ---------------------------------------------------------------------------
# Restore - the single implementation shared by local and restic-sourced
# restores (see cmd_restore in lib/commands/backup.sh)
# ---------------------------------------------------------------------------

# _restore_apply <dir> <scope: db|full>
#
# <dir> holds a backup in the layout backup_create_full() produces - either a
# local backup directory directly, or a staging directory restic just
# restored a snapshot into. Either way this is the only code that touches the
# live database/volumes/secrets during a restore.
_restore_apply() {
    local dir="$1" scope="${2:-db}" dump excluded buckets

    dump="$(_backup_db_file "$dir")" || { log_error "No database dump in ${dir}"; return 1; }
    _backup_checksum_verify "$dir" || die "Backup integrity check failed; refusing to restore from ${dir}."

    banner "Restore"
    printf '\n'
    cat "${dir}/metadata.txt" 2>/dev/null || true
    printf '\n'
    log_warn "This REPLACES the current database contents."
    excluded="$(env_get "${dir}/metadata.txt" excluded_data 2>/dev/null || true)"
    [[ -n "$excluded" ]] && \
        log_info "Log and telemetry tables were backed up without their data and come back empty: ${excluded}"
    [[ "$scope" == "full" ]] && log_warn "Scope 'full' also replaces Storage files and edge functions."
    buckets="$(env_get "${dir}/metadata.txt" excluded_storage_buckets 2>/dev/null || true)"
    [[ "$scope" == "full" && -n "$buckets" ]] && \
        log_warn "Storage bucket(s) not in this backup: ${buckets}. In-app backups are restored from their own copy destinations; their files here are left as they are."
    confirm "Restore ${scope} from $(basename "$dir")?" n || { log_info "Cancelled."; return 0; }

    # Take a safety copy first: a restore that goes wrong should still be
    # recoverable. Of what this restore replaces, and no more.
    log_info "Creating a safety backup of the current state..."
    backup_create "pre-restore" "$scope" >/dev/null || log_warn "Could not create a safety backup."

    supabase_check_postgres || die "The database is not running."

    log_info "Restoring the database..."
    local cid
    cid="$(_db_container)" || return 1
    # The dump \connects to each database in turn; it starts from this one.
    if ! ( set -o pipefail
           _backup_db_cat "$dump" | docker exec -i -e PGPASSWORD="$(_db_pass)" "$cid" \
               psql -U "$(_db_user)" -d "$(_db_name)" -q \
               >>"${SO_LOG_FILE:-/dev/null}" 2>&1 ); then
        die "Restore failed. See ${SO_LOG_FILE:-the log}."
    fi
    log_ok "Database restored from $(basename "$dir")"

    if [[ "$scope" == "full" ]]; then
        if [[ -f "${dir}/storage.tar.gz" ]]; then
            log_info "Restoring Storage files..."
            tar -xzf "${dir}/storage.tar.gz" -C "${SUPABASE_DIR}/volumes" \
                || log_warn "Could not restore the Storage volume."
        elif [[ "$(backup_scope "$dir")" == "db" ]]; then
            log_warn "$(basename "$dir") is a database-only backup; Storage files are left as they are."
        fi
        if [[ -f "${dir}/functions.tar.gz" ]]; then
            log_info "Restoring edge functions..."
            tar -xzf "${dir}/functions.tar.gz" -C "${SUPABASE_DIR}/volumes" \
                || log_warn "Could not restore the functions volume."
        fi
        if [[ -f "${dir}/config.tar.gz" ]]; then
            printf '\n'
            log_warn "config.tar.gz holds supabase/.env, installer.env and the deploy key."
            log_warn "Restoring it overwrites JWT_SECRET/POSTGRES_PASSWORD/API keys currently in use"
            log_warn "and invalidates every session and issued token."
            if confirm "Also restore supabase/.env and installer config from this backup?" n; then
                tar -xzf "${dir}/config.tar.gz" -C "$SUPABASE_DIR" .env 2>/dev/null
                tar -xzf "${dir}/config.tar.gz" -C "$CONFIG_DIR" installer.env 2>/dev/null
                tar -xzf "${dir}/config.tar.gz" -C "$CONFIG_DIR" deploy_key 2>/dev/null
                chmod 600 "${SUPABASE_DIR}/.env" "${CONFIG_DIR}/deploy_key" 2>/dev/null || true
                log_ok "Config restored. Re-run 'sentinel-ops update app' if SUPABASE_URL/keys changed."
            else
                log_info "Config left untouched."
            fi
        fi
    fi

    log_info "Restarting Supabase so every service reconnects..."
    supabase_restart || log_warn "Could not restart Supabase automatically."
    supabase_health_check 180 || log_warn "Supabase is not fully healthy after the restore."
    return 0
}
