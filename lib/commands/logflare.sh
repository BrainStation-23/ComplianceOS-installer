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
    printf '\nThe logs collected so far are kept in the _analytics schema of the\n'
    printf '_supabase database (backups already leave them out). Studio'"'"'s Logs\n'
    printf 'pages will be empty. Re-enable with: sentinel-ops logflare enable\n\n'
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

    case "${1:-status}" in
        status)  _logflare_status ;;
        enable)  _logflare_enable ;;
        disable) _logflare_disable ;;
        *)
            log_error "Unknown logflare subcommand: $1"
            printf 'Valid: status, enable, disable\n'
            return 2
            ;;
    esac
}
