#!/usr/bin/env bash
# lib/commands/logflare.sh - turn Supabase Analytics (Logflare + vector) on or
# off on an existing installation, without a reinstall.
#
# Disabling keeps the logs already collected (the _analytics schema of the
# _supabase database) and the LOGFLARE_* secrets in supabase/.env, so enabling
# again picks up where it left off. See docs/LOGFLARE.md.
# shellcheck shell=bash

# Containers of the analytics/vector services that are still running. Compose
# cannot be asked once the overlay is gone (the services are no longer part
# of the project), so this goes by the label Compose put on them.
_logflare_leftover_containers() {
    docker ps -q --filter label=com.docker.compose.service=analytics 2>/dev/null
    docker ps -q --filter label=com.docker.compose.service=vector 2>/dev/null
}

_logflare_status() {
    section "Analytics (Logflare)"
    local registered="false"
    logflare_overlay_registered && registered="true"

    if [[ "$ENABLE_LOGFLARE" == "true" ]]; then
        status_line "Configured" "ok" "Enabled"
    else
        status_line "Configured" "warn" "Disabled"
    fi

    if [[ "$registered" == "true" ]]; then
        status_line "Overlay" "" "${LOGFLARE_OVERLAY} in COMPOSE_FILE"
        if logflare_running; then
            if logflare_check; then
                status_line "Service" "ok" "Running"
            else
                status_line "Service" "warn" "Running, health endpoint not answering"
            fi
        else
            status_line "Service" "bad" "Not running"
        fi
    else
        status_line "Overlay" "" "Not registered"
    fi

    local backend
    backend="$(logflare_backend)"
    case "$backend" in
        local)    status_line "Log storage" "" "This server (_supabase.${LOGFLARE_SCHEMA})" ;;
        remote)   status_line "Log storage" "" "Remote Postgres ($(_logflare_remote_host))" ;;
        bigquery) status_line "Log storage" "" "BigQuery ($(env_get "${SUPABASE_DIR}/.env" GOOGLE_PROJECT_ID 2>/dev/null || printf '?'))" ;;
    esac
    if [[ "$backend" != "bigquery" ]]; then
        local bytes
        if bytes="$(logflare_storage_bytes 2>/dev/null)"; then
            status_line "Size" "" "$(human_bytes "$bytes")"
        else
            status_line "Size" "warn" "Unknown (database not reachable)"
        fi
        local days
        days="$(logflare_retention_days)"
        if [[ "$days" == "0" ]]; then
            status_line "Retention" "warn" "Off - logs are kept forever (sentinel-ops logflare retention 7)"
        else
            status_line "Retention" "ok" "${days} days"
        fi
    fi

    # The configuration and what Compose actually runs can disagree after a
    # manual edit; say how to bring them back in line.
    if [[ "$ENABLE_LOGFLARE" == "true" && "$registered" != "true" ]]; then
        printf '\n'
        log_warn "Enabled in the configuration, but the logs overlay is not registered."
        log_warn "Run: sentinel-ops logflare enable   (or: sentinel-ops logflare disable)"
    elif [[ "$ENABLE_LOGFLARE" != "true" && "$registered" == "true" ]]; then
        printf '\n'
        log_warn "Disabled in the configuration, but the logs overlay is still registered."
        log_warn "Run: sentinel-ops logflare disable"
    fi
    return 0
}

_logflare_enable() {
    logflare_overlay_available || \
        die "This Supabase release ships no run.sh, so the logs overlay cannot be enabled."

    update_lock_or_die

    ENABLE_LOGFLARE="true"
    config_save
    logflare_install || die "Could not enable the logs overlay; see the output above."

    # analytics and vector are new services: give them the same log size limit
    # as everything else. `up -d` recreates only what changed.
    if container_logs_apply_config; then
        supabase_restart || log_warn "Could not apply the container log limits to the new services."
    else
        log_warn "Container log limits not updated; re-run: sentinel-ops repair apply"
    fi

    logflare_health_check || die "Logflare did not start; check: sentinel-ops logs logflare"
    logflare_retention_sync || true
    printf '\n'
    log_ok "Analytics (Logflare) enabled."
    return 0
}

_logflare_disable() {
    update_lock_or_die

    ENABLE_LOGFLARE="false"
    config_save

    log_info "Removing the logs overlay..."
    logflare_remove_overlay || die "Could not remove ${LOGFLARE_OVERLAY} from COMPOSE_FILE in ${SUPABASE_DIR}/.env."

    # The container log-limit overlay names every service, analytics and
    # vector included. Left as it is, it would define those two without an
    # image and Compose would refuse to start anything - so regenerate it
    # before the restart.
    container_logs_apply_config || \
        die "Could not regenerate the container log limits; Supabase was not restarted. Run: sentinel-ops repair apply"

    log_info "Stopping analytics and vector..."
    supabase_restart || die "Supabase failed to restart; check: sentinel-ops logs supabase"

    if [[ -n "$(_logflare_leftover_containers)" ]]; then
        log_warn "analytics/vector containers are still running; check: docker ps"
    fi

    printf '\n'
    log_ok "Analytics (Logflare) disabled."
    printf '\nThe logs collected so far are kept (backups already leave them out),\n'
    printf 'and still age out if retention is on. Delete them now with:\n'
    printf '  sentinel-ops logflare purge\n'
    printf 'Studio'"'"'s Logs pages will be empty. Re-enable with: sentinel-ops logflare enable\n\n'
    return 0
}

# The host part of the remote URL, for display: never the credentials.
_logflare_remote_host() {
    local url
    url="$(env_get "${SUPABASE_DIR}/.env" LOGFLARE_REMOTE_BACKEND_URL 2>/dev/null || true)"
    url="${url#*://}"; url="${url##*@}"; url="${url%%\?*}"
    printf '%s' "${url:-not set}"
}

# purge [--older-than DAYS] [--yes]
_logflare_purge() {
    local older="" yes="${SO_ASSUME_YES:-false}"
    while (( $# )); do
        case "$1" in
            --older-than)   older="${2:-}"; shift 2 || shift ;;
            --older-than=*) older="${1#*=}"; shift ;;
            -y|--yes)       yes="true"; shift ;;
            *) log_error "Unknown purge option: $1"
               printf 'Usage: sentinel-ops logflare purge [--older-than DAYS] [--yes]\n'
               return 2 ;;
        esac
    done
    if [[ -n "$older" ]] && { ! logflare_valid_retention "$older" || [[ "$older" == "0" ]]; }; then
        die "--older-than takes a number of days, 1 or more."
    fi
    [[ "$(logflare_backend)" == "bigquery" ]] && \
        die "Logs are in BigQuery; set a table expiration on the dataset in Google Cloud instead."
    _db_container >/dev/null || die "The database must be running; start it with: sentinel-ops update supabase"

    local before what
    before="$(logflare_storage_bytes 2>/dev/null || printf '')"
    if [[ -n "$older" ]]; then what="logs older than ${older} days"; else what="ALL collected logs"; fi
    status_line "Log storage" "" "$(logflare_backend)"
    [[ -n "$before" ]] && status_line "Size now" "" "$(human_bytes "$before")"
    printf '\n'

    if [[ "$yes" != "true" ]]; then
        [[ -t 0 ]] || die "purge needs a terminal to confirm, or --yes."
        confirm "Permanently delete ${what}? They cannot be restored (backups leave them out)." n || {
            log_info "Cancelled; nothing deleted."
            return 0
        }
    fi

    update_lock_or_die
    log_info "Deleting ${what}..."
    logflare_purge "${older:-all}" || die "The purge failed; see ${SO_LOG_FILE:-the log}."
    local after
    after="$(logflare_storage_bytes 2>/dev/null || printf '')"
    if [[ -n "$before" && -n "$after" ]]; then
        log_ok "Deleted ${what}: $(human_bytes "$before") -> $(human_bytes "$after")"
        [[ -n "$older" ]] && log_info "Space freed by an age-based purge is reused by new logs rather than returned to the disk."
    else
        log_ok "Deleted ${what}."
    fi
    return 0
}

# What the retention timer runs. Quiet when there is nothing to do, and
# steps aside for an update rather than failing.
_logflare_prune() {
    local days
    days="$(logflare_retention_days)"
    if [[ "$days" == "0" || "$(logflare_backend)" == "bigquery" ]]; then
        log_info "Log retention is off; nothing to do."
        return 0
    fi
    _db_container >/dev/null 2>&1 || { log_warn "The database is not running; log retention skipped."; return 0; }
    update_lock_acquire || { log_warn "An update is running; log retention skipped until the next run."; return 0; }
    log_info "Deleting logs older than ${days} days..."
    logflare_purge "$days" || { log_error "Log retention failed; see ${SO_LOG_FILE:-the log}."; return 1; }
    log_ok "Log retention applied (${days} days)."
}

# retention [DAYS|off]
_logflare_retention() {
    local days="${1:-}"
    if [[ -z "$days" ]]; then
        if [[ "$(logflare_retention_days)" == "0" ]]; then
            status_line "Retention" "warn" "Off - logs are kept forever"
        else
            status_line "Retention" "ok" "$(logflare_retention_days) days"
        fi
        printf '\nChange with: sentinel-ops logflare retention <days|off>\n'
        return 0
    fi
    [[ "$days" == "off" ]] && days="0"
    logflare_valid_retention "$days" || die "Retention is a number of days, or off."

    LOGFLARE_RETENTION_DAYS="$days"
    config_save
    if [[ "$days" == "0" ]]; then
        logflare_retention_sync || true
        log_ok "Log retention off: collected logs are kept until purged."
        return 0
    fi
    [[ "$(logflare_backend)" == "bigquery" ]] && \
        log_warn "Saved, but logs are in BigQuery: set a table expiration on the dataset instead."
    logflare_retention_sync || log_warn "Saved, but the daily timer could not be installed."
    log_info "Apply it now with: sentinel-ops logflare prune"
    return 0
}

# backend [local|remote|bigquery]
_logflare_backend() {
    local previous
    previous="$(logflare_backend)"
    if [[ -z "${1:-}" && ! -t 0 ]]; then
        status_line "Log storage" "" "$previous"
        printf '\nChange with: sentinel-ops logflare backend <local|remote|bigquery>\n'
        return 0
    fi
    case "${1:-}" in ""|local|remote|bigquery) ;; *) die "Backends: local, remote, bigquery." ;; esac

    update_lock_or_die
    logflare_prompt_backend "${1:-$previous}" || die "Nothing changed."

    if [[ "$LOGFLARE_BACKEND" == "bigquery" ]] && ! logflare_compose_supports_reset; then
        LOGFLARE_BACKEND="$previous"
        die "BigQuery needs Docker Compose 2.24 or later (for the !reset tag). Nothing changed."
    fi
    if [[ "$LOGFLARE_BACKEND" == "remote" ]]; then
        log_info "Checking the remote database..."
        if ! logflare_remote_check "$LOGFLARE_REMOTE_BACKEND_URL"; then
            LOGFLARE_BACKEND="$previous"
            die "Could not connect, or create the ${LOGFLARE_SCHEMA} schema there. Nothing changed."
        fi
        log_ok "Remote database reachable"
    fi

    config_save
    logflare_configure_supabase || die "Could not apply the analytics configuration."
    logflare_retention_sync || true

    if [[ "$ENABLE_LOGFLARE" == "true" ]] && logflare_overlay_registered; then
        log_info "Restarting analytics with the new log storage..."
        supabase_restart || die "Supabase failed to restart; check: sentinel-ops logs supabase"
        logflare_health_check || die "Logflare did not start; check: sentinel-ops logs logflare"
    else
        log_info "Logflare is disabled; the new log storage is used once it is enabled."
    fi

    printf '\n'
    log_ok "Log storage: ${LOGFLARE_BACKEND}"
    if [[ "$LOGFLARE_BACKEND" != "$previous" ]]; then
        log_info "Logs already in the previous storage (${previous}) are not moved or deleted,"
        log_info "and Studio no longer shows them."
        if [[ "$previous" == "local" ]]; then
            log_info "To free that space: switch back to local, run 'logflare purge', then switch again."
        fi
    fi
    return 0
}

cmd_logflare() {
    require_root logflare
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
    supabase_installed || die "Supabase is not installed at ${SUPABASE_DIR}."

    banner "Analytics (Logflare)"
    printf '\n'

    local sub="${1:-status}"
    (( $# )) && shift
    case "$sub" in
        status)    _logflare_status ;;
        enable)    _logflare_enable ;;
        disable)   _logflare_disable ;;
        purge)     _logflare_purge "$@" ;;
        prune)     _logflare_prune ;;
        retention) _logflare_retention "$@" ;;
        backend)   _logflare_backend "$@" ;;
        *)
            log_error "Unknown logflare subcommand: $sub"
            printf 'Valid: status, enable, disable, purge, prune, retention, backend\n'
            return 2
            ;;
    esac
}
