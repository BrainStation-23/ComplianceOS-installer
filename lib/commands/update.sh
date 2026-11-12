#!/usr/bin/env bash
# lib/commands/update.sh - application, Supabase and full updates.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Update lock
#
# The auto-update timer and an operator can both reach for the stack at the
# same moment, and two overlapping deployments would interleave image builds,
# migrations and container restarts. Everything that changes what is deployed
# holds this lock.
#
# `self-update` deliberately does not take it: replacing the installer's own
# files never touches the stack, and an auto-update half way through a long
# image build must not stand between an operator and a fix to the installer.
# ---------------------------------------------------------------------------

SO_UPDATE_LOCK_FD=""

# Take the lock without waiting; returns 1 when another process holds it.
# Re-entrant within one process (and its subshells), so `update all` holds it
# across both halves. Released when the process exits, however it exits.
update_lock_acquire() {
    [[ -n "$SO_UPDATE_LOCK_FD" ]] && return 0
    if ! have_cmd flock; then
        log_debug "flock unavailable; updates are not serialised"
        return 0
    fi
    mkdir -p "$STATE_DIR"
    local fd
    exec {fd}>"${STATE_DIR}/update.lock" || return 1
    if ! flock -n "$fd"; then
        exec {fd}>&-
        return 1
    fi
    SO_UPDATE_LOCK_FD="$fd"
    return 0
}

# Only the menu needs this: it outlives the update it ran, and would otherwise
# hold the lock - and starve the auto-update timer - for as long as it is open.
update_lock_release() {
    [[ -n "$SO_UPDATE_LOCK_FD" ]] || return 0
    exec {SO_UPDATE_LOCK_FD}>&-
    SO_UPDATE_LOCK_FD=""
}

update_lock_or_die() {
    update_lock_acquire && return 0
    die "Another update is already running (possibly the auto-update timer: systemctl status ${SO_AUTOUPDATE_UNIT}.service). Try again when it finishes."
}

# Shared entry guard: an update only makes sense against a real installation.
_update_preflight() {
    installation_exists || die "No Sentinel Ops installation found at ${INSTALL_DIR}. Run: sentinel-ops install"
    config_load || die "Could not read ${CONFIG_FILE}"
    require_linux
    detect_os || log_warn "Could not identify this distribution; continuing."
    ensure_docker >/dev/null || die "Docker is not usable."
    supabase_installed || die "Supabase is not installed at ${SUPABASE_DIR}."
}

# Supabase must be healthy before anything touches the schema or the frontend.
_update_require_supabase_healthy() {
    log_info "Verifying Supabase..."
    if ! supabase_check_postgres; then
        log_warn "Supabase is not running; starting it."
        supabase_start || die "Could not start Supabase."
    fi
    if ! supabase_health_check 180; then
        die "Supabase is not healthy. Resolve that first: sentinel-ops status"
    fi
}

# ---------------------------------------------------------------------------
# Application update
# ---------------------------------------------------------------------------

cmd_update_app() {
    require_root update app
    _update_preflight
    update_lock_or_die
    SO_LOG_FILE="${LOG_DIR}/update-app-$(timestamp).log"

    banner "Update Sentinel Ops"
    printf '\n'

    local before_commit before_image
    before_commit="$(state_get APP_COMMIT unknown)"
    before_image="$(state_get APP_IMAGE '')"

    phase_begin "Supabase health"
    _update_require_supabase_healthy
    phase_end

    phase_begin "Fetching application changes"
    deploy_key_prepare || die "Deployment key unavailable."
    deploy_key_known_hosts
    repo_update || die "Could not update the repository."
    repo_validate || die "The updated checkout is not a valid Sentinel Ops repository."
    phase_end

    phase_begin "Application environment"
    app_env_generate || die "Could not regenerate the application environment."
    phase_end

    # The image is built before anything is changed in the database, so a build
    # failure costs nothing and the running deployment is untouched.
    phase_begin "Building the frontend image"
    frontend_build_image || die "Frontend build failed. The running deployment was not modified."
    phase_end

    phase_begin "Database migrations"
    backup_create "pre-app-update" db >/dev/null || log_warn "Backup failed; continuing."
    deploy_migrations || die "Migration failed. The running deployment was not modified."
    phase_end

    phase_begin "Edge functions"
    deploy_functions || die "Edge function deployment failed."
    phase_end

    phase_begin "Deploying the frontend"
    frontend_deploy || die "Frontend deployment failed."
    phase_end

    state_set APP_COMMIT "$(repo_commit)"
    state_set APP_BRANCH "$APP_BRANCH"
    [[ -n "$before_commit" && "$before_commit" != "unknown" ]] && state_set PREVIOUS_APP_COMMIT "$before_commit"
    # A successful deployment is the operator's answer to whatever made
    # auto-update hold back (a failed attempt, a rollback) - stop holding.
    state_set AUTO_UPDATE_SKIP_COMMIT ""
    state_set AUTO_UPDATE_SKIP_REASON ""
    state_touch_updated

    # Only after the new image is live and recorded, so the old one is never
    # removed from under a deployment that did not finish.
    phase_begin "Removing superseded images"
    images_cleanup_after_app_update
    logs_prune_installer || true
    phase_end

    printf '\n'
    log_ok "Sentinel Ops updated"
    status_line "Commit" "" "${before_commit:0:7} -> $(repo_short_commit)"
    status_line "Image" "" "$(frontend_deployed_image)"
    [[ -n "$before_image" ]] && status_line "Previous" "" "$before_image"
    printf '\n'
    return 0
}

# ---------------------------------------------------------------------------
# Supabase update
# ---------------------------------------------------------------------------

cmd_update_supabase() {
    require_root update supabase
    _update_preflight
    update_lock_or_die
    SO_LOG_FILE="${LOG_DIR}/update-supabase-$(timestamp).log"

    banner "Update Supabase"
    printf '\n'

    local current
    current="$(supabase_current_version)"
    status_line "Current version" "" "$current"

    # A database backup is mandatory here: a Supabase update can change the
    # Postgres major version or run its own schema migrations.
    phase_begin "Database backup"
    local backup_dir
    if ! backup_dir="$(backup_create "pre-supabase-update")"; then
        die "Refusing to update Supabase without a successful backup."
    fi
    phase_end

    phase_begin "Updating the Supabase deployment"
    supabase_update_files || die "Could not refresh the Supabase deployment files."
    # Re-apply the settings the installer owns; an upstream .env.example change
    # must not silently revert the configured URLs.
    supabase_apply_config || die "Could not re-apply the Supabase configuration."
    if [[ "$ENABLE_LOGFLARE" == "true" ]]; then
        # An upstream .env.example change must not revert the analytics
        # settings.
        logflare_configure_supabase || log_warn "Could not re-apply the analytics configuration."
    fi
    if azure_enabled; then
        # supabase_update_files just re-synced docker-compose.yml from
        # upstream, which undoes the Azure AD wiring (.env is preserved, the
        # compose file is not) - reapply both.
        azure_apply_config  || log_warn "Could not re-apply the Azure AD configuration."
        azure_patch_compose || log_warn "Could not re-wire Azure AD into the refreshed docker-compose.yml."
    fi
    # An upstream .env.example change can reset COMPOSE_FILE, which would
    # silently drop the auth hardening overlay - re-register it.
    hardening_apply_config || log_warn "Could not re-apply the auth hardening configuration."
    # Upstream's refreshed docker-compose.yml brings back its 50 MiB storage
    # limit; the overlay that raises it must stay registered.
    storage_apply_config || log_warn "Could not re-apply the storage upload limit."
    # Upstream may have changed the db command the sizing appends to, and the
    # host may have been resized. The restart below applies it.
    db_tuning_apply_config || log_warn "Could not re-apply the database sizing."
    # Upstream may have added or removed services; every one needs its log
    # limited. The restart below applies it.
    container_logs_apply_config || log_warn "Could not re-apply the container log limits."
    phase_end

    phase_begin "Pulling images"
    supabase_pull
    phase_end

    phase_begin "Restarting Supabase"
    if ! supabase_restart; then
        log_error "Supabase failed to restart."
        log_error "The pre-update backup is at: ${backup_dir}"
        die "Supabase update failed."
    fi
    if ! supabase_health_check 300; then
        log_error "Supabase did not become healthy after the update."
        log_error "The pre-update backup is at: ${backup_dir}"
        log_error "Restore it with: sentinel-ops restore ${backup_dir}"
        die "Supabase update failed."
    fi
    phase_end

    phase_begin "Verifying Logflare"
    logflare_health_check || log_warn "Logflare is not healthy after the Supabase update."
    phase_end

    local new_version
    new_version="$(supabase_current_version)"
    state_set SUPABASE_VERSION "$new_version"
    state_set PREVIOUS_SUPABASE_VERSION "$current"
    state_touch_updated

    phase_begin "Removing superseded images"
    images_cleanup_after_supabase_update
    logs_prune_installer || true
    phase_end

    printf '\n'
    log_ok "Supabase updated"
    status_line "Version" "" "${current} -> ${new_version}"
    status_line "Backup" "" "$backup_dir"
    printf '\n'
    return 0
}

# ---------------------------------------------------------------------------
# Full update
# ---------------------------------------------------------------------------

cmd_update_all() {
    require_root update all
    update_lock_or_die
    banner "Update Everything"
    printf '\n'
    log_info "Updating Supabase first, then the application."

    cmd_update_supabase || die "Supabase update failed; the application was not touched."
    printf '\n'
    cmd_update_app     || die "Application update failed."

    printf '\n'
    log_ok "Full update complete"
    return 0
}

# Dispatcher for `sentinel-ops update [app|supabase|all|installer]`.
cmd_update() {
    case "${1:-app}" in
        app|application|sentinel-ops) cmd_update_app ;;
        supabase|db)                  cmd_update_supabase ;;
        all|everything)               cmd_update_all ;;
        installer|self)               cmd_self_update "${@:2}" ;;
        *)
            log_error "Unknown update target: $1"
            printf 'Valid targets: app, supabase, all, installer\n'
            return 2
            ;;
    esac
}
