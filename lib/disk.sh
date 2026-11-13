#!/usr/bin/env bash
# lib/disk.sh - free space, and the installer's own logs.
#
# Everything an installation writes to disk is bounded somewhere: images by
# lib/images.sh, backups by retention in lib/backup.sh, container logs by
# lib/container_logs.sh, and the installer's own run logs here. This file
# also holds the free-space checks that stop a backup or an unattended update
# from being the thing that fills the disk. See docs/DECISIONS.md #34.
# shellcheck shell=bash

# Non-secret config, persisted in installer.env.
LOG_RETENTION_DAYS="30"
AUTO_UPDATE_MIN_FREE_GB="5"

DISK_GIB=1073741824

# Bytes free / in total on the filesystem holding <path>; nothing when df
# cannot say. df -P keeps each filesystem on one line whatever its name.
disk_free_bytes() {
    local kb
    kb="$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }')" || true
    [[ "$kb" =~ ^[0-9]+$ ]] && printf '%s' "$(( kb * 1024 ))"
    return 0
}

disk_size_bytes() {
    local kb
    kb="$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $2 }')" || true
    [[ "$kb" =~ ^[0-9]+$ ]] && printf '%s' "$(( kb * 1024 ))"
    return 0
}

# Bytes <path> takes on disk (0 when it does not exist).
disk_used_bytes() {
    local kb
    kb="$(du -sk "$1" 2>/dev/null | cut -f1)" || true
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    printf '%s' "$(( kb * 1024 ))"
}

# ---------------------------------------------------------------------------
# Installer logs
# ---------------------------------------------------------------------------

# LOG_RETENTION_DAYS as a whole number of days; 0 keeps every log. A
# hand-edited value that is not a number falls back to the default.
logs_retention_days() {
    if [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        printf '%s' "$LOG_RETENTION_DAYS"
    else
        log_warn "LOG_RETENTION_DAYS='${LOG_RETENTION_DAYS}' is not a number of days; using 30." >&2
        printf '30'
    fi
}

# Installer logs in LOG_DIR older than the retention, oldest first.
_logs_prune_candidates() {
    local days
    days="$(logs_retention_days)"
    (( days > 0 )) || return 0
    [[ -d "$LOG_DIR" ]] || return 0
    find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -mtime "+${days}" 2>/dev/null | LC_ALL=C sort
}

# Remove installer logs past LOG_RETENTION_DAYS. The log of the run in
# progress is never one of them: it was written to moments ago.
# logs_prune_installer [--dry-run]
logs_prune_installer() {
    local dry="${1:-}" f n=0 days
    days="$(logs_retention_days)"
    if (( days == 0 )); then
        log_info "Installer logs: kept (LOG_RETENTION_DAYS=0)."
        return 0
    fi
    while IFS= read -r f; do
        [[ -n "$f" && "$f" != "${SO_LOG_FILE:-}" ]] || continue
        if [[ "$dry" == "--dry-run" ]]; then
            printf '  would remove %s\n' "$f" >&2
        else
            rm -f "$f" || continue
        fi
        n=$((n + 1))
    done < <(_logs_prune_candidates)
    if [[ "$dry" == "--dry-run" ]]; then
        log_ok "Installer logs: would remove ${n} older than ${days} days"
    else
        log_ok "Installer logs: removed ${n} older than ${days} days"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Free-space checks
# ---------------------------------------------------------------------------

# AUTO_UPDATE_MIN_FREE_GB in bytes; 0 turns the check off.
autoupdate_min_free_bytes() {
    local gb="$AUTO_UPDATE_MIN_FREE_GB"
    if [[ ! "$gb" =~ ^[0-9]+$ ]]; then
        log_warn "AUTO_UPDATE_MIN_FREE_GB='${gb}' is not a number of GB; using 5." >&2
        gb=5
    fi
    printf '%s' "$(( gb * DISK_GIB ))"
}

# The directories an update writes to: the installation (backups, logs) and
# Docker's data root (the new image).
_disk_update_paths() {
    printf '%s\n' "$INSTALL_DIR"
    docker info -f '{{.DockerRootDir}}' 2>/dev/null || true
}

# True when every filesystem an update writes to has AUTO_UPDATE_MIN_FREE_GB
# free. When it does not, prints "<free> free on <path>" for the fullest one.
# A filesystem df cannot read is not held against the update.
disk_room_for_update() {
    local want path free
    want="$(autoupdate_min_free_bytes)"
    (( want > 0 )) || return 0
    while IFS= read -r path; do
        [[ -n "$path" && -d "$path" ]] || continue
        free="$(disk_free_bytes "$path")"
        [[ -n "$free" ]] || continue
        if (( free < want )); then
            printf '%s free on %s' "$(human_bytes "$free")" "$path"
            return 1
        fi
    done < <(_disk_update_paths)
    return 0
}

# Status line for what the installation itself holds on disk.
disk_install_status() {
    status_line "Installer data" "" \
        "backups $(human_bytes "$(disk_used_bytes "$BACKUP_DIR")"), logs $(human_bytes "$(disk_used_bytes "$LOG_DIR")") - see: sentinel-ops disk"
}
