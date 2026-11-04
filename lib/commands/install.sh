#!/usr/bin/env bash
# lib/commands/install.sh - first installation.
#
# Every step runs behind a phase marker, so re-running after a failure resumes
# rather than starting over. Nothing here destroys existing state.
# shellcheck shell=bash

# --- individual phases -----------------------------------------------------

_install_system_checks() {
    require_linux
    require_supported_os
    install_base_prerequisites || return 1
    ensure_docker || return 1
    return 0
}

_install_supabase_files() {
    supabase_install_files || return 1
    supabase_generate_secrets || return 1
    supabase_apply_config || return 1
    if azure_enabled; then
        azure_apply_config || return 1
        azure_patch_compose || log_warn "Azure AD sign-in was configured but could not be wired into the auth container."
    fi
    hardening_apply_config || return 1
    storage_apply_config || return 1
    container_logs_apply_config || log_warn "Container logs are not size-limited; re-run: sentinel-ops repair apply"
    return 0
}

_install_supabase_start() {
    supabase_pull
    supabase_start || return 1
    if ! supabase_health_check 240; then
        printf '\n'
        log_error "Supabase health check failed."
        log_error "Sentinel Ops installation cannot continue."
        printf '\nRun:\n  sentinel-ops status\n\n'
        return 1
    fi
    state_set SUPABASE_VERSION "$(supabase_current_version)"
    return 0
}

# Auth hardening is applied in _install_supabase_files so a fresh stack starts
# with it, but that phase is skipped on a re-run - which is exactly when an
# operator answering the prompts on an existing installation expects them to
# take effect. Re-apply on every run; recreate auth only if something changed.
_install_auth_hardening() {
    local before
    before="$(_hardening_fingerprint)"
    hardening_apply_config || return 1
    if [[ "$before" != "$(_hardening_fingerprint)" ]] && supabase_service_running auth; then
        _auth_restart "" || return 1
    fi
    return 0
}

# The same re-run reasoning as auth hardening: an installation that predates
# the storage overlay gets it here, and storage is recreated only if it
# changed.
_install_storage_limit() {
    local before
    before="$(_storage_fingerprint)"
    storage_apply_config || return 1
    if [[ "$before" != "$(_storage_fingerprint)" ]] && supabase_service_running storage; then
        storage_restart || return 1
    fi
    return 0
}

# Analytics adds services after the stack first started, and an installation
# that predates the overlay has none, so it is re-applied on every run.
# `up -d` recreates only the containers whose logging actually changed.
_install_container_logs() {
    local before
    before="$(_container_logs_fingerprint)"
    container_logs_apply_config || return 1
    if [[ "$before" != "$(_container_logs_fingerprint)" ]] && supabase_check_postgres; then
        supabase_restart || return 1
    fi
    return 0
}

_install_network() {
    firewall_ensure_active
    network_apply_firewall
    return 0
}

_install_logflare() {
    logflare_install || return 1
    logflare_health_check || return 1
    return 0
}

_install_repository() {
    deploy_key_prepare || return 1
    deploy_key_known_hosts
    repo_test_access || return 1
    repo_clone || return 1
    repo_validate || return 1
    return 0
}

_install_app_env() {
    app_env_generate
}

_install_database() {
    # A backup before the very first migration run is cheap and gives a clean
    # restore point for the pre-application database.
    backup_create "pre-install-migrations" db >/dev/null || \
        log_warn "Could not create a pre-migration backup; continuing."
    deploy_migrations || return 1
    deploy_functions || return 1
    return 0
}

_install_frontend() {
    frontend_build_image || return 1
    frontend_deploy || return 1
    return 0
}

# --- configuration ---------------------------------------------------------

_install_prompt_install_dir() {
    local dir="$SO_DEFAULT_INSTALL_DIR"
    [[ -n "${SO_INSTALL_DIR_OVERRIDE:-}" ]] && dir="$SO_INSTALL_DIR_OVERRIDE"
    prompt_default dir "Installation directory" "$dir"
    config_set_paths "$dir"
    config_make_dirs
    SO_LOG_FILE="${LOG_DIR}/install-$(timestamp).log"
    log_info "Logging to ${SO_LOG_FILE}"
}

_install_collect_config() {
    # Re-use anything already recorded, so a resumed install does not re-ask.
    config_load 2>/dev/null || true

    # Network exposure and the frontend port are decided first: Supabase's own
    # URL prompts need APP_BIND (LAN vs loopback) and APP_PORT to offer the
    # right default, rather than asking for the same three URLs twice.
    frontend_prompt_config
    network_prompt_config
    supabase_prompt_config
    repo_prompt_config

    logflare_prompt_config
    azure_prompt_config
    hardening_prompt_config

    config_save
}

_install_summary() {
    local sb_url="$SUPABASE_PUBLIC_URL" app_url="$SITE_URL"

    printf '\n'
    banner "Installation Complete"
    printf '\n'
    section "URLs"
    status_line "Application" "" "$app_url"
    status_line "Supabase" "" "$sb_url"

    # No reverse proxy is installed - these are the upstreams to point one at.
    section "Reverse proxy upstreams"
    status_line "Frontend" "" "${APP_BIND:-127.0.0.1}:${APP_PORT}"
    status_line "Supabase API" "" "127.0.0.1:$(supabase_kong_port)"

    if [[ "$APP_BIND" == "0.0.0.0" ]]; then
        printf '\n'
        log_warn "LAN access is enabled: the frontend binds every interface, and its firewall"
        log_warn "rule (where a firewall is active) only admits private/LAN address ranges."
        log_warn "There is no TLS on this. Toggle with: sentinel-ops network"
        log_warn "For a real domain instead, run: sentinel-ops domain set <hostname>"
    fi

    section "Deployed"
    status_line "Supabase" "" "$(supabase_current_version)"
    status_line "Git commit" "" "$(repo_short_commit)"
    status_line "Image" "" "$(frontend_deployed_image)"
    status_line "Migrations" "" "$(migrations_applied_count) applied"
    storage_status

    if azure_enabled; then
        section "Azure AD"
        status_line "Status" "ok" "Enabled"
        status_line "Redirect URI" "" "$(_azure_redirect_uri)"
    fi

    section "Auth hardening"
    hardening_status

    printf '\n'
    # Credentials are deliberately not printed here: installation output is
    # routinely copied into tickets and chat.
    printf 'Supabase credentials are available with:\n'
    printf '  %ssentinel-ops credentials%s\n\n' "$C_BOLD" "$C_RESET"
    printf 'Check the deployment at any time with:\n'
    printf '  %ssentinel-ops status%s\n\n' "$C_BOLD" "$C_RESET"
}

# --- entry point -----------------------------------------------------------

cmd_install() {
    require_root install

    banner "Sentinel Ops Installer"
    printf '\n'

    phase_begin "System checks"
    _install_system_checks || die "System prerequisites are not satisfied."
    phase_end

    _install_prompt_install_dir

    # Copy the installer into the installation root before anything else
    # depends on its templates, so the rest of the run (and every future
    # update) uses one canonical copy.
    phase_begin "Installing the sentinel-ops command"
    selfinstall || die "Could not install the sentinel-ops command."
    phase_end

    if installation_exists && phase_done frontend; then
        log_warn "An installation already exists at ${INSTALL_DIR}."
        log_warn "Use 'sentinel-ops update' to update it."
        if ! confirm "Continue and re-run the installer anyway?" n; then
            return 0
        fi
    fi

    _install_collect_config

    phase_once supabase_files  "Supabase deployment files"   _install_supabase_files  || die "Supabase setup failed."
    phase_once supabase_start  "Starting Supabase"           _install_supabase_start  || die "Supabase did not become healthy."

    phase_begin "Auth hardening"
    _install_auth_hardening || die "Could not apply the auth hardening configuration."
    phase_end

    phase_begin "Storage upload limit"
    _install_storage_limit || die "Could not apply the storage upload limit."
    phase_end

    phase_begin "Network exposure"
    _install_network || log_warn "Could not apply firewall rules; open the ports manually if needed."
    phase_end

    # Analytics is a log aggregator, not a dependency of the application: a
    # failure here leaves the phase unmarked (so a re-run retries it) but must
    # not abort an otherwise good installation.
    phase_once logflare        "Analytics (Logflare)"        _install_logflare        || \
        log_warn "Analytics was not deployed; the rest of the stack is unaffected."

    phase_begin "Container log limits"
    _install_container_logs || log_warn "Container logs are not size-limited; re-run: sentinel-ops repair apply"
    phase_end
    phase_once repository      "Sentinel Ops repository"     _install_repository      || die "Repository checkout failed."

    # The remaining phases are cheap and depend on current config, so they run
    # on every install invocation rather than being marker-gated.
    phase_begin "Application environment"
    _install_app_env || die "Could not generate the application environment."
    phase_end

    phase_begin "Database migrations and edge functions"
    _install_database || die "Database deployment failed."
    phase_end

    phase_begin "Frontend image and container"
    _install_frontend || die "Frontend deployment failed."
    phase_end

    phase_mark frontend
    state_set INSTALLER_VERSION "$SO_INSTALLER_VERSION"
    state_set INSTALLED_AT      "$(state_get INSTALLED_AT "$(date -Is 2>/dev/null || date)")"
    state_set APP_COMMIT        "$(repo_commit)"
    state_set APP_BRANCH        "$APP_BRANCH"
    state_set SUPABASE_VERSION  "$(supabase_current_version)"
    state_touch_updated

    # A reinstall over kept config (nuke --keep-config) has the setting but
    # not the timer, which nuke removed.
    if [[ "$AUTO_UPDATE_ENABLED" == "true" ]]; then
        autoupdate_refresh_units || log_warn "Could not install the auto-update timer; re-run: sentinel-ops auto-update enable"
    fi

    _install_summary
    return 0
}
