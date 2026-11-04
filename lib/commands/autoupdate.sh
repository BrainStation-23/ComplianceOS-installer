#!/usr/bin/env bash
# lib/commands/autoupdate.sh - unattended application updates.
#
# A systemd timer periodically asks the application repository which commit
# its branch points at - a single `git ls-remote`, nothing else. Only when that
# differs from the deployed commit does it run the same `update app` an
# operator would. A check that finds nothing new touches nothing: no fetch, no
# health checks, no backup, no image build.
#
# Same systemd tolerance as lib/commands/schedule.sh: on a host without
# systemd, `enable` saves the setting and warns, and `run-now` still works
# from the operator's own cron.
# shellcheck shell=bash

SO_AUTOUPDATE_UNIT="sentinel-ops-autoupdate"

# ---------------------------------------------------------------------------
# Unit generation - pure string building, no filesystem/systemd involved
# ---------------------------------------------------------------------------

# _autoupdate_unit_text <service|timer>
#
# ExecStart goes through the PATH symlink, so a `self-update` takes effect at
# the very next check without the units having to be rewritten.
_autoupdate_unit_text() {
    local kind="$1"
    case "$kind" in
        service)
            cat <<EOF
[Unit]
Description=Sentinel Ops application auto-update
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${SO_BIN_LINK} --dir ${INSTALL_DIR} --yes auto-update run-cycle
EOF
            ;;
        timer)
            cat <<EOF
[Unit]
Description=Sentinel Ops application auto-update check

[Timer]
OnCalendar=${AUTO_UPDATE_CALENDAR}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
            ;;
    esac
}

# ---------------------------------------------------------------------------
# The decision - pure, so it is testable without git or a network
# ---------------------------------------------------------------------------

# _autoupdate_decide <remote-commit> <deployed-commit> <held-commit>
#
#   unknown     the remote could not be read - do nothing
#   undeployed  nothing has ever been deployed here - not ours to start
#   current     the branch has not moved - do nothing
#   held        the branch still points at a commit auto-update was told to
#               leave alone (it failed to deploy, or was rolled back)
#   update      the branch has moved - deploy it
_autoupdate_decide() {
    local remote="$1" deployed="$2" held="$3"
    if [[ -z "$remote" ]]; then
        printf 'unknown'
    elif [[ -z "$deployed" || "$deployed" == "unknown" ]]; then
        printf 'undeployed'
    elif [[ "$remote" == "$deployed" ]]; then
        printf 'current'
    elif [[ -n "$held" && "$remote" == "$held" ]]; then
        printf 'held'
    else
        printf 'update'
    fi
}

# The commit the configured branch points at upstream; empty on failure.
_autoupdate_remote_commit() {
    GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 \
        git ls-remote "$APP_REPOSITORY" "refs/heads/${APP_BRANCH}" 2>>"${SO_LOG_FILE:-/dev/null}" \
        | awk 'NR == 1 { print $1 }'
}

_autoupdate_record() {
    state_set AUTO_UPDATE_LAST_RESULT "$1"
}

# ---------------------------------------------------------------------------
# The cycle - the systemd unit's ExecStart target
# ---------------------------------------------------------------------------

_autoupdate_run_cycle() {
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    SO_LOG_FILE="${LOG_DIR}/auto-update-$(date +%Y-%m-%d).log"
    # Nobody is at the terminal to answer a prompt.
    SO_ASSUME_YES="true"

    state_set AUTO_UPDATE_LAST_CHECK_AT "$(date -Is 2>/dev/null || date)"

    if ! deploy_key_prepare >/dev/null; then
        _autoupdate_record "check failed: no usable deployment key"
        return 1
    fi
    deploy_key_known_hosts >/dev/null

    local remote deployed held reason decision
    remote="$(_autoupdate_remote_commit)" || remote=""
    deployed="$(state_get APP_COMMIT '')"
    held="$(state_get AUTO_UPDATE_SKIP_COMMIT '')"
    reason="$(state_get AUTO_UPDATE_SKIP_REASON 'held')"
    decision="$(_autoupdate_decide "$remote" "$deployed" "$held")"

    case "$decision" in
        unknown)
            log_error "Could not read ${APP_BRANCH} from ${APP_REPOSITORY}."
            _autoupdate_record "check failed: repository unreachable"
            return 1
            ;;
        undeployed)
            log_warn "No deployed commit recorded; finish the installation first (sentinel-ops install)."
            _autoupdate_record "skipped: nothing deployed yet"
            return 0
            ;;
        current)
            log_info "Up to date (${deployed:0:7}); nothing to do."
            _autoupdate_record "up to date (${deployed:0:7})"
            return 0
            ;;
        held)
            log_info "${APP_BRANCH} is still at ${remote:0:7} (${reason}); waiting for a newer commit."
            _autoupdate_record "holding: ${remote:0:7} ${reason}"
            return 0
            ;;
    esac

    # An update writes a backup and a new image. On a nearly full disk that is
    # what fills it, so wait - checked again every cycle, nothing is held.
    local short
    if ! short="$(disk_room_for_update)"; then
        log_error "Not updating to ${remote:0:7}: only ${short} (AUTO_UPDATE_MIN_FREE_GB=${AUTO_UPDATE_MIN_FREE_GB}). Free space with: sentinel-ops cleanup"
        _autoupdate_record "skipped: low disk space (${short})"
        return 1
    fi

    # An operator's update (or a long one from the previous check) is already
    # doing the work - this is not a failure, just not our turn.
    if ! update_lock_acquire; then
        log_info "Another update is running; checking again next cycle."
        _autoupdate_record "skipped: another update was running"
        return 0
    fi

    log_info "New commit on ${APP_BRANCH}: ${deployed:0:7} -> ${remote:0:7}. Updating."
    # A subshell, because cmd_update_app exits through die() on failure and the
    # outcome still has to be recorded. It inherits the lock.
    if ( cmd_update_app ); then
        state_set AUTO_UPDATE_LAST_UPDATE_AT "$(date -Is 2>/dev/null || date)"
        _autoupdate_record "updated ${deployed:0:7} -> ${remote:0:7}"
        return 0
    fi

    # Retrying the same commit every cycle would rebuild a broken image (and
    # take a backup) every hour, for nothing. Hold it until something changes.
    state_set AUTO_UPDATE_SKIP_COMMIT "$remote"
    state_set AUTO_UPDATE_SKIP_REASON "failed to deploy"
    _autoupdate_record "update to ${remote:0:7} failed"
    log_error "Auto-update to ${remote:0:7} failed. It will not be retried until ${APP_BRANCH} moves on,"
    log_error "or an operator runs: sentinel-ops update app"
    return 1
}

# ---------------------------------------------------------------------------
# Install/enable/disable/status
# ---------------------------------------------------------------------------

_autoupdate_install_units() {
    have_cmd systemctl || { log_warn "systemctl not available; cannot check for updates automatically on this host."; return 1; }

    _autoupdate_unit_text service >"/etc/systemd/system/${SO_AUTOUPDATE_UNIT}.service"
    _autoupdate_unit_text timer   >"/etc/systemd/system/${SO_AUTOUPDATE_UNIT}.timer"
    run_logged "systemctl daemon-reload" systemctl daemon-reload || true
    service_enable_start "${SO_AUTOUPDATE_UNIT}.timer"
}

_autoupdate_status() {
    section "Auto-update"
    if [[ "$AUTO_UPDATE_ENABLED" != "true" ]]; then
        status_line "Status" "warn" "Disabled - see: sentinel-ops auto-update enable"
    else
        status_line "Status" "ok" "Enabled (checks ${AUTO_UPDATE_CALENDAR})"
        if have_cmd systemctl; then
            if systemctl is-active --quiet "${SO_AUTOUPDATE_UNIT}.timer" 2>/dev/null; then
                status_line "Timer" "ok" "Active"
                local next
                next="$(systemctl show "${SO_AUTOUPDATE_UNIT}.timer" --property=NextElapseUSecRealtime --value 2>/dev/null)"
                [[ -n "$next" ]] && status_line "Next check" "" "$next"
            else
                status_line "Timer" "bad" "Not active - re-run: sentinel-ops auto-update enable"
            fi
        else
            status_line "Timer" "warn" "systemd unavailable - run checks manually: sentinel-ops auto-update run-now"
        fi
    fi
    status_line "Tracking" "" "${APP_BRANCH} of ${APP_REPOSITORY}"
    status_line "Last check" "" "$(state_get AUTO_UPDATE_LAST_CHECK_AT never)"
    status_line "Last result" "" "$(state_get AUTO_UPDATE_LAST_RESULT -)"
    status_line "Last auto-update" "" "$(state_get AUTO_UPDATE_LAST_UPDATE_AT never)"
    local held
    held="$(state_get AUTO_UPDATE_SKIP_COMMIT '')"
    [[ -n "$held" ]] && status_line "Holding" "warn" \
        "${held:0:7} ($(state_get AUTO_UPDATE_SKIP_REASON held)) - cleared by: sentinel-ops update app"
    return 0
}

_autoupdate_enable() {
    prompt_default AUTO_UPDATE_CALENDAR \
        "How often to check for a new release (systemd OnCalendar expression, e.g. hourly, *:0/15, daily)" \
        "$AUTO_UPDATE_CALENDAR"
    AUTO_UPDATE_ENABLED="true"
    config_save

    if _autoupdate_install_units; then
        log_ok "Auto-update enabled: checking ${AUTO_UPDATE_CALENDAR}; updates run only when ${APP_BRANCH} has moved."
    else
        log_warn "Setting saved, but the systemd timer could not be installed."
        log_warn "Run 'sentinel-ops auto-update run-now' yourself (e.g. from cron) instead."
    fi
    return 0
}

_autoupdate_disable() {
    AUTO_UPDATE_ENABLED="false"
    config_save
    if have_cmd systemctl; then
        # Stops future checks only. An update already in progress is a oneshot
        # service of its own and is left to finish rather than killed half way.
        systemctl disable --now "${SO_AUTOUPDATE_UNIT}.timer" >/dev/null 2>&1 || true
    fi
    log_ok "Auto-update disabled."
    return 0
}

# Rewrite the units from the current code when auto-update is on. Called after
# a self-update, so a changed unit definition reaches existing installations.
autoupdate_refresh_units() {
    [[ "$AUTO_UPDATE_ENABLED" == "true" ]] || return 0
    _autoupdate_install_units >/dev/null 2>&1 || return 1
}

cmd_autoupdate() {
    require_root auto-update
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true

    case "${1:-status}" in
        status)     _autoupdate_status ;;
        enable)     _autoupdate_enable ;;
        disable)    _autoupdate_disable ;;
        run-now)    log_info "Checking for an application update now..."; _autoupdate_run_cycle ;;
        run-cycle)  _autoupdate_run_cycle ;;
        *)
            log_error "Unknown auto-update subcommand: $1"
            printf 'Valid: status, enable, disable, run-now\n'
            return 2
            ;;
    esac
}
