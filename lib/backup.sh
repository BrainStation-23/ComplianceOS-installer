#!/usr/bin/env bash
# lib/backup.sh - full-stack backups: Postgres, Storage, edge functions and
# enough config to rebuild the install, plus local retention and the shared
# restore implementation.
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
    # pg_dumpall captures roles and every database, which is what a restore of
    # a Supabase stack actually needs.
    if ! docker exec -e PGPASSWORD="$(_db_pass)" "$cid" \
            pg_dumpall -U "$(_db_user)" --clean --if-exists >"${dir}/database.sql" 2>>"${SO_LOG_FILE:-/dev/null}"; then
        log_error "Database dump failed." >&2
        rm -rf "$dir"
        return 1
    fi

    # A failed archive fails the whole backup. Keeping it would leave a
    # truncated file that checksums.txt then vouches for (on a full disk,
    # exactly the backup someone reaches for).
    if [[ "$scope" == "full" && -d "${SUPABASE_DIR}/volumes/storage" ]]; then
        log_info "Archiving Storage..." >&2
        _backup_archive "$dir" storage.tar.gz -C "${SUPABASE_DIR}/volumes" storage || return 1
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
# Free space - refuse a backup that would fill the disk
# ---------------------------------------------------------------------------

# Rough size of a new backup: the databases as Postgres stores them (a plain
# dump is usually smaller, never much larger) plus Storage when included.
# _backup_estimate_bytes <full|db> <db-container>
_backup_estimate_bytes() {
    local scope="$1" cid="$2" db
    db="$(docker exec -e PGPASSWORD="$(_db_pass)" "$cid" \
        psql -U "$(_db_user)" -d "$(_db_name)" -tAc \
        'SELECT sum(pg_database_size(datname))::bigint FROM pg_database' 2>/dev/null | tr -d '[:space:]')" || true
    [[ "$db" =~ ^[0-9]+$ ]] || db=0
    if [[ "$scope" == "full" && -d "${SUPABASE_DIR}/volumes/storage" ]]; then
        db=$(( db + $(disk_used_bytes "${SUPABASE_DIR}/volumes/storage") ))
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
        printf 'size_bytes=%s\n'        "$(stat -c%s "${dir}/database.sql" 2>/dev/null || printf '0')"
    } >"${dir}/metadata.txt"
}

# Write a sha256sum-compatible checksums.txt for every backup file present.
_backup_checksum_write() {
    local dir="$1" f hash
    : >"${dir}/checksums.txt"
    for f in database.sql "${BACKUP_ARCHIVE_FILES[@]}"; do
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
    local dir="$1" scope="${2:-db}"

    [[ -f "${dir}/database.sql" ]] || { log_error "No database.sql in ${dir}"; return 1; }
    _backup_checksum_verify "$dir" || die "Backup integrity check failed; refusing to restore from ${dir}."

    banner "Restore"
    printf '\n'
    cat "${dir}/metadata.txt" 2>/dev/null || true
    printf '\n'
    log_warn "This REPLACES the current database contents."
    [[ "$scope" == "full" ]] && log_warn "Scope 'full' also replaces Storage files and edge functions."
    confirm "Restore ${scope} from $(basename "$dir")?" n || { log_info "Cancelled."; return 0; }

    # Take a safety copy first: a restore that goes wrong should still be
    # recoverable. Of what this restore replaces, and no more.
    log_info "Creating a safety backup of the current state..."
    backup_create "pre-restore" "$scope" >/dev/null || log_warn "Could not create a safety backup."

    supabase_check_postgres || die "The database is not running."

    log_info "Restoring the database..."
    local cid
    cid="$(_db_container)" || return 1
    if ! docker exec -i -e PGPASSWORD="$(_db_pass)" "$cid" \
            psql -U "$(_db_user)" -d "$(_db_name)" -q \
            <"${dir}/database.sql" >>"${SO_LOG_FILE:-/dev/null}" 2>&1; then
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
