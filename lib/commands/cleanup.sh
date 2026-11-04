#!/usr/bin/env bash
# lib/commands/cleanup.sh - free the disk space the installation owns, on
# demand: superseded Docker images, local backups past retention and old
# installer logs.
#
# `update app` and `update supabase` already do all of this after every
# successful run (lib/images.sh, lib/backup.sh, lib/disk.sh). This is for an
# installation that built up images and backups before that existed, for an
# operator who just lowered a limit, and for a dry run to see what would go.
# shellcheck shell=bash

cmd_cleanup() {
    require_root cleanup
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true

    local dry=""
    case "${1:-}" in
        ""|run)       SO_IMAGES_DRY_RUN="false" ;;
        --dry-run|-n) SO_IMAGES_DRY_RUN="true"; dry="--dry-run" ;;
        *)
            log_error "Unknown cleanup option: $1"
            printf 'Usage: sentinel-ops cleanup [--dry-run]\n'
            return 2
            ;;
    esac

    # An update half way through a build, a deployment or a backup must not
    # have its images or backups removed from under it.
    update_lock_or_die
    SO_LOG_FILE="${LOG_DIR}/cleanup-$(timestamp).log"

    banner "Clean up disk space"
    printf '\n'
    [[ -n "$dry" ]] && log_info "Dry run: nothing will be removed."
    local free_before
    free_before="$(disk_free_bytes "$INSTALL_DIR")"
    [[ -n "$free_before" ]] && status_line "Free before" "" "$(human_bytes "$free_before")"
    printf '\n'

    # Backups and logs need no Docker; a host whose daemon is down is often
    # the one that ran out of space.
    backup_prune_local "$dry"
    logs_prune_installer "$dry"

    if docker_daemon_ok; then
        status_line "Images before" "" "$(images_disk_usage)"
        images_prune_app
        if supabase_installed; then
            images_prune_supabase
        fi
        images_prune_build_cache
    else
        log_warn "Docker is not available; images were not cleaned up."
    fi

    if [[ -z "$dry" ]]; then
        printf '\n'
        docker_daemon_ok && status_line "Images now" "" "$(images_disk_usage)"
        local free_after
        free_after="$(disk_free_bytes "$INSTALL_DIR")"
        [[ -n "$free_after" ]] && status_line "Free now" "" "$(human_bytes "$free_after")"
    fi
    printf '\n'
    return 0
}
