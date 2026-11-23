#!/usr/bin/env bash
# lib/commands/remote.sh - configure the two 3-2-1 replication targets
# (secondary = a different local/attached medium, offsite = remote/cloud),
# both driven by restic (lib/restic.sh). Both are optional and off by
# default. See the wiki page Offsite-Backups.
# shellcheck shell=bash

_remote_role_label() {
    case "$1" in
        secondary) printf 'Secondary (different medium)' ;;
        offsite)   printf 'Offsite' ;;
        *)         printf '%s' "$1" ;;
    esac
}

_remote_status_one() {
    local role="$1" enabled_var repo_var enabled repo daily_var weekly_var monthly_var
    enabled_var="$(_restic_config_var "$role" ENABLED)"
    repo_var="$(_restic_config_var "$role" REPOSITORY)"
    enabled="${!enabled_var}"
    repo="${!repo_var}"

    section "$(_remote_role_label "$role")"
    if [[ "$enabled" != "true" || -z "$repo" ]]; then
        status_line "Status" "warn" "Not configured - see: sentinel-ops remote ${role} configure"
        return 0
    fi

    status_line "Status" "ok" "Configured"
    status_line "Repository" "" "$(mask_secret "$repo")"
    daily_var="$(_restic_config_var "$role" KEEP_DAILY)"
    weekly_var="$(_restic_config_var "$role" KEEP_WEEKLY)"
    monthly_var="$(_restic_config_var "$role" KEEP_MONTHLY)"
    status_line "Retention" "" "keep-daily ${!daily_var}, keep-weekly ${!weekly_var}, keep-monthly ${!monthly_var}"
    status_line "Last backup" "" "$(state_get "$(_restic_config_var "$role" LAST_BACKUP_AT)" 'never')"
    status_line "Last check"  "" "$(state_get "$(_restic_config_var "$role" LAST_CHECK_AT)" 'never')"
    return 0
}

_remote_status_all() {
    _remote_status_one secondary
    _remote_status_one offsite
}

_remote_configure() {
    local role="$1"
    local enabled_var repo_var daily_var weekly_var monthly_var
    enabled_var="$(_restic_config_var "$role" ENABLED)"
    repo_var="$(_restic_config_var "$role" REPOSITORY)"
    daily_var="$(_restic_config_var "$role" KEEP_DAILY)"
    weekly_var="$(_restic_config_var "$role" KEEP_WEEKLY)"
    monthly_var="$(_restic_config_var "$role" KEEP_MONTHLY)"

    section "Configure $(_remote_role_label "$role")"
    printf 'A restic repository URL, e.g. a local path, s3:bucket/path, b2:bucket:path,\n'
    printf 'sftp:user@host:/path - see https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html\n\n'

    local repo
    prompt_default repo "Repository URL" "${!repo_var}"
    [[ -n "$repo" ]] || { log_error "A repository URL is required."; return 1; }
    printf -v "$repo_var" '%s' "$repo"

    local pass_file
    pass_file="$(_restic_password_file "$role")"
    if [[ -f "$pass_file" ]]; then
        log_info "Repository password already set at ${pass_file} (leave blank to keep it)."
    fi
    local pass
    prompt_secret pass "Repository password (blank to generate one)" "$(cat "$pass_file" 2>/dev/null || true)"
    [[ -n "$pass" ]] || pass="$(random_token 24)"
    mkdir -p "$CONFIG_DIR"
    printf '%s' "$pass" >"$pass_file"
    chmod 600 "$pass_file" 2>/dev/null || true

    printf '\nBackend credentials (e.g. AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY for S3).\n'
    printf 'Enter a variable name to set it, blank to finish.\n\n'
    local creds_file key val
    creds_file="$(_restic_credentials_file "$role")"
    while true; do
        prompt_default key "Variable name (blank to finish)" ""
        [[ -n "$key" ]] || break
        prompt_secret val "Value for ${key}" "$(env_get "$creds_file" "$key" 2>/dev/null || true)"
        env_set "$creds_file" "$key" "$val"
    done
    [[ -f "$creds_file" ]] && chmod 600 "$creds_file" 2>/dev/null || true

    local daily weekly monthly
    prompt_default daily   "Keep how many daily snapshots (0 to disable)"   "${!daily_var}"
    prompt_default weekly  "Keep how many weekly snapshots (0 to disable)"  "${!weekly_var}"
    prompt_default monthly "Keep how many monthly snapshots (0 to disable)" "${!monthly_var}"
    printf -v "$daily_var" '%s' "$daily"
    printf -v "$weekly_var" '%s' "$weekly"
    printf -v "$monthly_var" '%s' "$monthly"
    printf -v "$enabled_var" 'true'

    config_save

    restic_install || { log_warn "restic is not installed; ${role} is configured but cannot replicate yet."; return 1; }
    if restic_init "$role"; then
        log_ok "Repository ready: $(mask_secret "$repo")"
    else
        log_warn "Could not initialise the repository; check the URL and credentials above."
        return 1
    fi

    printf '\n'
    log_ok "$(_remote_role_label "$role") configured."
    log_info "Run 'sentinel-ops schedule run-now' or wait for the next scheduled cycle to replicate."
    return 0
}

_remote_check() {
    local role="$1" enabled_var
    enabled_var="$(_restic_config_var "$role" ENABLED)"
    [[ "${!enabled_var}" == "true" ]] || die "$(_remote_role_label "$role") is not configured."
    log_info "Checking $(_remote_role_label "$role") repository integrity..."
    if restic_check "$role"; then
        state_set "$(_restic_config_var "$role" LAST_CHECK_AT)" "$(date -Is 2>/dev/null || date)"
        log_ok "Repository check passed."
    else
        die "Repository check failed; see the log."
    fi
}

_remote_forget() {
    local role="$1" enabled_var
    enabled_var="$(_restic_config_var "$role" ENABLED)"
    [[ "${!enabled_var}" == "true" ]] || die "$(_remote_role_label "$role") is not configured."
    log_info "Applying retention policy to $(_remote_role_label "$role")..."
    restic_forget "$role" && log_ok "Retention applied." || die "Could not apply retention policy."
}

_remote_dispatch_role() {
    local role="$1"; shift
    case "${1:-status}" in
        status)    _remote_status_one "$role" ;;
        configure) _remote_configure "$role" ;;
        check)     _remote_check "$role" ;;
        forget)    _remote_forget "$role" ;;
        *)
            log_error "Unknown remote ${role} subcommand: $1"
            printf 'Valid: status, configure, check, forget\n'
            return 2
            ;;
    esac
}

cmd_remote() {
    require_root remote
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    supabase_installed || die "Supabase is not installed at ${SUPABASE_DIR}."

    banner "Offsite / Secondary Backup"
    printf '\n'

    case "${1:-status}" in
        status)             _remote_status_all ;;
        secondary|offsite)  local role="$1"; shift; _remote_dispatch_role "$role" "$@" ;;
        *)
            log_error "Unknown remote subcommand: $1"
            printf 'Valid: status, secondary [status|configure|check|forget], offsite [status|configure|check|forget]\n'
            return 2
            ;;
    esac
}
