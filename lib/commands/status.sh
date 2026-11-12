#!/usr/bin/env bash
# lib/commands/status.sh - the first diagnostic to run when something is wrong.
# shellcheck shell=bash

# Probe once and render the result, rather than running each (network-bound)
# check twice to derive the state and the label separately.
_status_probe() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        status_line "$label" "ok" "Healthy"
    else
        status_line "$label" "bad" "Unhealthy"
    fi
}

_status_system() {
    section "System"
    detect_os 2>/dev/null || true
    status_line "OS" "" "${OS_NAME:-unknown}"

    if docker_binary_ok; then
        if docker_daemon_ok; then
            status_line "Docker" "ok" "Running"
        else
            status_line "Docker" "bad" "Installed, daemon not responding"
        fi
    else
        status_line "Docker" "bad" "Not installed"
    fi

    if detect_compose; then
        status_line "Docker Compose" "ok" "Available"
    else
        status_line "Docker Compose" "bad" "Unavailable"
    fi
    docker_daemon_ok 2>/dev/null && images_disk_status
    installation_exists && disk_install_status

    status_line "Installer" "" "$(state_get INSTALLER_VERSION "$SO_INSTALLER_VERSION")"
    status_line "Install dir" "" "$INSTALL_DIR"
    return 0
}

_status_supabase() {
    section "Supabase"
    if ! supabase_installed; then
        status_line "Status" "bad" "Not installed"
        return 0
    fi
    status_line "Version" "" "$(supabase_current_version)"

    # Without a running daemon every probe below would just time out.
    if ! docker_daemon_ok; then
        status_line "Services" "bad" "Docker unavailable"
        return 0
    fi

    _status_probe "PostgreSQL" supabase_check_postgres
    _status_probe "API"        supabase_check_api
    _status_probe "Auth"       supabase_check_auth
    _status_probe "Studio"     supabase_check_studio
    status_line "Migrations" "" "$(migrations_applied_count) applied"
    storage_status
    return 0
}

_status_logflare() {
    section "Logflare"
    if [[ "$ENABLE_LOGFLARE" != "true" ]]; then
        status_line "Status" "warn" "Disabled"
        return 0
    fi
    if logflare_running; then
        if logflare_check; then
            status_line "Status" "ok" "Running"
        else
            status_line "Status" "warn" "Running, health endpoint not answering"
        fi
    else
        status_line "Status" "bad" "Not running"
    fi
    status_line "Log storage" "" "$(logflare_backend)"
    if [[ "$(logflare_backend)" != "bigquery" ]]; then
        local days bytes
        days="$(logflare_retention_days)"
        if bytes="$(logflare_storage_bytes 2>/dev/null)"; then
            status_line "Size" "" "$(human_bytes "$bytes")"
        fi
        if [[ "$days" == "0" ]]; then
            status_line "Retention" "warn" "Off (sentinel-ops logflare retention 7)"
        else
            status_line "Retention" "ok" "${days} days"
        fi
    fi
    return 0
}

_status_app() {
    section "Sentinel Ops"
    if ! repo_is_cloned; then
        status_line "Repository" "bad" "Not cloned"
        return 0
    fi
    status_line "Git branch" "" "$(state_get APP_BRANCH "$APP_BRANCH")"
    status_line "Git commit" "" "$(repo_short_commit)"
    status_line "Image" "" "$(state_get APP_IMAGE 'none')"
    if [[ "$AUTO_UPDATE_ENABLED" == "true" ]]; then
        status_line "Auto-update" "ok" "$(state_get AUTO_UPDATE_LAST_RESULT 'enabled, not run yet') - see: sentinel-ops auto-update status"
    else
        status_line "Auto-update" "" "Off - see: sentinel-ops auto-update enable"
    fi

    if container_running "$APP_CONTAINER_NAME"; then
        status_line "Frontend" "ok" "Running"
    elif container_exists "$APP_CONTAINER_NAME"; then
        status_line "Frontend" "bad" "Stopped"
    else
        status_line "Frontend" "bad" "No container"
    fi

    if frontend_check_http "$APP_PORT"; then
        status_line "HTTP health" "ok" "Healthy"
    else
        status_line "HTTP health" "bad" "Not responding on port ${APP_PORT}"
    fi
    return 0
}

_status_backups() {
    section "Backups"
    local latest count
    latest="$(backup_latest)"
    if [[ -n "$latest" ]]; then
        status_line "Latest local backup" "ok" \
            "$(basename "$latest") ($(env_get "${latest}/metadata.txt" reason 2>/dev/null || printf '-'))"
    else
        status_line "Latest local backup" "bad" "None yet - see: sentinel-ops backup create"
    fi
    count="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    local cap cap_text="no size limit"
    cap="$(backup_retention_max_bytes 2>/dev/null)"
    [[ -n "$cap" ]] && cap_text="$(human_bytes "$cap")"
    status_line "Local retention" "" \
        "${count} kept, $(human_bytes "$(disk_used_bytes "$BACKUP_DIR")") (limit $(backup_retention_count 2>/dev/null), ${cap_text})"

    local role last_backup last_check
    for role in secondary offsite; do
        local enabled_var
        enabled_var="$(_restic_config_var "$role" ENABLED)"
        [[ "${!enabled_var}" == "true" ]] || continue
        last_backup="$(state_get "$(_restic_config_var "$role" LAST_BACKUP_AT)" never)"
        last_check="$(state_get "$(_restic_config_var "$role" LAST_CHECK_AT)" never)"
        status_line "$(_remote_role_label "$role")" "$([[ "$last_backup" == "never" ]] && printf warn || printf ok)" \
            "last replicated ${last_backup}, last checked ${last_check}"
    done
    if [[ "$RESTIC_SECONDARY_ENABLED" != "true" && "$RESTIC_OFFSITE_ENABLED" != "true" ]]; then
        status_line "3-2-1" "warn" "No secondary/offsite copy configured - see: sentinel-ops remote status"
    fi

    if [[ "$BACKUP_SCHEDULE_ENABLED" == "true" ]]; then
        status_line "Schedule" "ok" "Enabled (${BACKUP_SCHEDULE_CALENDAR}) - see: sentinel-ops schedule status"
    else
        status_line "Schedule" "warn" "Not scheduled - see: sentinel-ops schedule enable"
    fi
    return 0
}

_status_urls() {
    section "URLs"
    if [[ "$SITE_URL" == https://* ]]; then
        status_line "Mode" "ok" "Domain - see: sentinel-ops domain status"
    elif [[ "$APP_BIND" == "0.0.0.0" ]]; then
        status_line "Mode" "warn" "LAN access, no TLS - see: sentinel-ops network status"
    else
        status_line "Mode" "ok" "Loopback only"
    fi
    status_line "Application" "" "$SITE_URL"
    status_line "Supabase" "" "$SUPABASE_PUBLIC_URL"
    # These are what your reverse proxy should point at.
    status_line "Frontend upstream" "" "${APP_BIND:-127.0.0.1}:${APP_PORT}"
    status_line "Supabase upstream" "" "127.0.0.1:$(supabase_kong_port)"
    if [[ "$APP_BIND" == "0.0.0.0" ]]; then
        status_line "LAN access" "warn" "Frontend bound to 0.0.0.0 - see: sentinel-ops network"
    fi
    return 0
}

_status_azure() {
    section "Azure AD"
    if [[ "$ENABLE_AZURE_AD" == "true" ]]; then
        status_line "Status" "ok" "Enabled"
        status_line "Redirect URI" "" "$(_azure_redirect_uri)"
    else
        status_line "Status" "warn" "Disabled"
    fi
    return 0
}

_status_auth() {
    section "Auth hardening"
    hardening_status
}

_status_meta() {
    section "History"
    status_line "Installed" "" "$(state_get INSTALLED_AT unknown)"
    status_line "Last update" "" "$(state_get UPDATED_AT never)"
    status_line "Installer updated" "" "$(state_get INSTALLER_UPDATED_AT never)"
    local prev
    prev="$(state_get PREVIOUS_APP_COMMIT '')"
    [[ -n "$prev" ]] && status_line "Previous commit" "" "${prev:0:7}"
    prev="$(backup_latest)"
    [[ -n "$prev" ]] && status_line "Latest backup" "" "$(basename "$prev")"
    return 0
}

cmd_status() {
    banner "Sentinel Ops Status"

    if ! installation_exists; then
        printf '\n'
        log_warn "No installation found at ${INSTALL_DIR}."
        printf '\nRun:\n  sentinel-ops install\n\n'
        _status_system
        printf '\n'
        return 1
    fi
    config_load || true
    detect_compose >/dev/null 2>&1 || true

    _status_system
    _status_supabase
    _status_logflare
    _status_azure
    _status_auth
    _status_app
    [[ "$MDM_PROXY_ENABLED" == "true" ]] && _mdm_proxy_status
    _status_backups
    _status_urls
    _status_meta
    printf '\n'
    return 0
}
