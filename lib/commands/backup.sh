#!/usr/bin/env bash
# lib/commands/backup.sh - create, list, verify and restore full-stack
# backups. See lib/backup.sh for the underlying logic and docs/BACKUPS.md for
# the full layout and 3-2-1 setup.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

cmd_backup() {
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true

    case "${1:-create}" in
        create|"")
            shift || true
            local label="manual" scope="full"
            while (( $# )); do
                case "$1" in
                    --label) label="${2:-manual}"; shift 2 ;;
                    --label=*) label="${1#--label=}"; shift ;;
                    --scope=*) scope="${1#--scope=}"; shift ;;
                    *) log_warn "Ignoring unknown option: $1"; shift ;;
                esac
            done
            case "$scope" in full|db) ;; *) die "Invalid --scope: ${scope} (expected full or db)" ;; esac
            local dir
            dir="$(backup_create "$label" "$scope")" || die "Backup failed."
            printf '\n'
            log_ok "Backup complete: ${dir}"
            ;;
        list|ls)
            section "Backups"
            local d size reason scope found=0
            while IFS='|' read -r d size reason scope; do
                [[ -n "$d" ]] || continue
                found=1
                printf '%-24s %-10s %-5s %s\n' "$(basename "$d")" "$size" "$scope" "$reason"
            done < <(backup_list_entries)
            (( found )) || printf 'No backups yet.\n'
            printf '\n'
            ;;
        verify)
            local target="${2:-}"
            [[ -n "$target" ]] || target="$(backup_latest)"
            [[ -n "$target" ]] || die "No local backup to verify."
            [[ -d "$target" ]] || target="${BACKUP_DIR}/${target}"
            if _backup_checksum_verify "$target"; then
                log_ok "Backup verified: $(basename "$target")"
            else
                die "Backup failed verification: $(basename "$target")"
            fi
            ;;
        size)
            _backup_size_report "${2:-15}"
            ;;
        *)
            log_error "Unknown backup subcommand: $1"
            printf 'Valid: create [--label <text>] [--scope=full|db], list, verify [backup-id], size [n]\n'
            return 2
            ;;
    esac
    return 0
}

# sentinel-ops backup size [n] - the n largest tables of each database, and
# whether a backup takes their data. What to look at before adding to
# BACKUP_EXCLUDE_DATA.
_backup_size_report() {
    local top="$1" cid db name bytes pats=() i mark kept skipped
    [[ "$top" =~ ^[1-9][0-9]*$ ]] || top=15
    cid="$(_db_container)" || die "The database is not running."
    section "Database size by table"
    if [[ "${BACKUP_INCLUDE_LOG_DATA:-false}" == "true" ]]; then
        log_info "BACKUP_INCLUDE_LOG_DATA=true: backups take every table's data."
    fi
    while IFS= read -r db; do
        [[ -n "$db" ]] || continue
        mapfile -t pats < <(_backup_exclude_patterns "$db")
        i=0 kept=0 skipped=0
        printf '\n%s\n' "$db"
        while IFS='|' read -r name bytes; do
            [[ "$bytes" =~ ^[0-9]+$ ]] || continue
            if _backup_matches_any "$name" "${pats[@]}"; then
                mark="schema only"; skipped=$(( skipped + bytes ))
            else
                mark="backed up";   kept=$(( kept + bytes ))
            fi
            (( i++ < top )) && printf '  %-56s %10s  %s\n' "$name" "$(human_bytes "$bytes")" "$mark"
        done < <(_backup_table_sizes "$cid" "$db")
        printf '  %-56s %10s\n' "total backed up"           "$(human_bytes "$kept")"
        printf '  %-56s %10s\n' "total left out (schema only)" "$(human_bytes "$skipped")"
    done < <(_backup_databases "$cid")
    printf '\nSizes are as Postgres stores them; the compressed dump is much smaller.\n'
    printf 'Leave more table data out with BACKUP_EXCLUDE_DATA in %s.\n\n' "$CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

# sentinel-ops restore [target] [--scope=db|full] [--from=local|secondary|offsite] [--snapshot=<id|latest>]
cmd_restore() {
    require_root restore
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true

    local target="" scope="db" from="local" snapshot="latest"
    while (( $# )); do
        case "$1" in
            --scope=*)    scope="${1#--scope=}"; shift ;;
            --from=*)     from="${1#--from=}"; shift ;;
            --snapshot=*) snapshot="${1#--snapshot=}"; shift ;;
            --*) log_warn "Ignoring unknown option: $1"; shift ;;
            *) target="$1"; shift ;;
        esac
    done

    case "$scope" in db|full) ;; *) die "Invalid --scope: ${scope} (expected db or full)" ;; esac

    case "$from" in
        local)
            [[ -n "$target" ]] || target="$(backup_latest)"
            [[ -n "$target" ]] || die "No backup to restore."
            # Accept either a full path or just the timestamp directory name.
            [[ -d "$target" ]] || target="${BACKUP_DIR}/${target}"
            _restore_apply "$target" "$scope"
            ;;
        secondary|offsite)
            local staging
            staging="$(mktemp -d)"
            log_info "Restoring snapshot '${snapshot}' from ${from}..."
            if restic_restore "$from" "$snapshot" "$staging"; then
                # restic restores the archived directory under the staging
                # root, one level down (its own path from when it was backed
                # up); find the directory that actually holds the dump.
                local restored
                restored="$(find "$staging" -mindepth 1 \( -name database.sql.gz -o -name database.sql \) -printf '%h\n' 2>/dev/null | head -n1)"
                [[ -n "$restored" ]] || die "Restic restore did not produce a recognisable backup directory."
                _restore_apply "$restored" "$scope"
            else
                die "Could not restore snapshot '${snapshot}' from ${from}."
            fi
            rm -rf "$staging"
            ;;
        *)
            die "Invalid --from: ${from} (expected local, secondary or offsite)"
            ;;
    esac
    return 0
}
