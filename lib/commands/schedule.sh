#!/usr/bin/env bash
# lib/commands/schedule.sh - a systemd timer that runs the full backup cycle:
# local full-stack backup, replicate to secondary/offsite if configured,
# apply retention, verify. See docs/BACKUPS.md.
#
# Tolerates hosts without systemd (warns, returns non-fatal) - the same
# contract service_enable_start() already has (lib/os.sh) - so a
# container/WSL host without systemd can still run `backup create` and
# `schedule run-now` by hand.
# shellcheck shell=bash

SO_BACKUP_UNIT="sentinel-ops-backup"

# ---------------------------------------------------------------------------
# Unit generation - pure string building, no filesystem/systemd involved
# ---------------------------------------------------------------------------

# _schedule_unit_text <service|timer>
_schedule_unit_text() {
    local kind="$1"
    case "$kind" in
        service)
            cat <<EOF
[Unit]
Description=Sentinel Ops backup cycle
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${SO_BIN_LINK} --dir ${INSTALL_DIR} schedule run-cycle
EOF
            ;;
        timer)
            cat <<EOF
[Unit]
Description=Sentinel Ops backup schedule

[Timer]
OnCalendar=${BACKUP_SCHEDULE_CALENDAR}
Persistent=true

[Install]
WantedBy=timers.target
EOF
            ;;
    esac
}

# True on the configured integrity-check day (BACKUP_SCHEDULE_CHECK_DAY, a
# %a-style abbreviation, default "Sun"). Pure string match - takes the
# weekday to test as an argument so it is testable without the real date.
_schedule_is_check_day() {
    local today="$1"
    [[ "$today" == "$BACKUP_SCHEDULE_CHECK_DAY" ]]
}

# ---------------------------------------------------------------------------
# Install/enable/disable
# ---------------------------------------------------------------------------

_schedule_install_units() {
    have_cmd systemctl || { log_warn "systemctl not available; cannot schedule backups automatically on this host."; return 1; }

    _schedule_unit_text service >"/etc/systemd/system/${SO_BACKUP_UNIT}.service"
    _schedule_unit_text timer   >"/etc/systemd/system/${SO_BACKUP_UNIT}.timer"
    run_logged "systemctl daemon-reload" systemctl daemon-reload || true
    service_enable_start "${SO_BACKUP_UNIT}.timer"
}

_schedule_status() {
    section "Backup Schedule"
    if [[ "$BACKUP_SCHEDULE_ENABLED" != "true" ]]; then
        status_line "Status" "warn" "Disabled - see: sentinel-ops schedule enable"
        return 0
    fi
    status_line "Status" "ok" "Enabled (${BACKUP_SCHEDULE_CALENDAR})"
    status_line "Integrity check day" "" "$BACKUP_SCHEDULE_CHECK_DAY"
    if have_cmd systemctl; then
        if systemctl is-active --quiet "${SO_BACKUP_UNIT}.timer" 2>/dev/null; then
            status_line "Timer" "ok" "Active"
            local next
            next="$(systemctl show "${SO_BACKUP_UNIT}.timer" --property=NextElapseUSecRealtime --value 2>/dev/null)"
            [[ -n "$next" ]] && status_line "Next run" "" "$next"
        else
            status_line "Timer" "bad" "Not active - re-run: sentinel-ops schedule enable"
        fi
    else
        status_line "Timer" "warn" "systemd unavailable - run cycles manually: sentinel-ops schedule run-now"
    fi
    return 0
}

_schedule_enable() {
    prompt_default BACKUP_SCHEDULE_CALENDAR \
        "Backup schedule (systemd OnCalendar expression, e.g. daily, *-*-* 03:00:00)" \
        "$BACKUP_SCHEDULE_CALENDAR"
    prompt_default BACKUP_SCHEDULE_CHECK_DAY \
        "Day to run remote integrity checks (Mon..Sun)" \
        "$BACKUP_SCHEDULE_CHECK_DAY"
    BACKUP_SCHEDULE_ENABLED="true"
    config_save

    if _schedule_install_units; then
        log_ok "Backup schedule enabled: ${BACKUP_SCHEDULE_CALENDAR}"
    else
        log_warn "Schedule saved, but the systemd timer could not be installed."
        log_warn "Run 'sentinel-ops schedule run-now' yourself (e.g. from cron) instead."
    fi
    return 0
}

_schedule_disable() {
    BACKUP_SCHEDULE_ENABLED="false"
    config_save
    if have_cmd systemctl; then
        systemctl disable --now "${SO_BACKUP_UNIT}.timer" >/dev/null 2>&1 || true
    fi
    log_ok "Backup schedule disabled."
    return 0
}

# ---------------------------------------------------------------------------
# The cycle itself - the systemd unit's ExecStart target
# ---------------------------------------------------------------------------

_schedule_replicate() {
    local role="$1" dir="$2" enabled_var
    enabled_var="$(_restic_config_var "$role" ENABLED)"
    [[ "${!enabled_var}" == "true" ]] || return 0

    log_info "Replicating to ${role}..."
    if restic_backup "$role" "$dir"; then
        state_set "$(_restic_config_var "$role" LAST_BACKUP_AT)" "$(date -Is 2>/dev/null || date)"
        log_ok "Replicated to ${role}."
    else
        log_warn "Replication to ${role} failed - the local backup is still intact."
    fi

    if restic_forget "$role"; then
        log_ok "Retention applied to ${role}."
    else
        log_warn "Could not apply retention policy to ${role}."
    fi

    if _schedule_is_check_day "$(date +%a)"; then
        log_info "Running the scheduled integrity check for ${role}..."
        if restic_check "$role"; then
            state_set "$(_restic_config_var "$role" LAST_CHECK_AT)" "$(date -Is 2>/dev/null || date)"
            log_ok "Integrity check passed for ${role}."
        else
            log_warn "Integrity check FAILED for ${role}. Investigate: sentinel-ops remote ${role} status"
        fi
    fi
}

_schedule_run_cycle() {
    banner "Backup Cycle"
    printf '\n'

    local dir
    if ! dir="$(backup_create "scheduled")"; then
        log_error "Scheduled backup failed - no local backup was produced this cycle."
        return 1
    fi

    _schedule_replicate secondary "$dir"
    _schedule_replicate offsite "$dir"

    if _backup_checksum_verify "$dir"; then
        log_ok "Local backup verified."
    else
        log_warn "Local backup failed its own checksum verification. Investigate: ${dir}"
    fi

    log_ok "Backup cycle complete."
    return 0
}

_schedule_run_now() {
    log_info "Running a backup cycle now..."
    _schedule_run_cycle
}

cmd_schedule() {
    require_root schedule
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true

    case "${1:-status}" in
        status)     _schedule_status ;;
        enable)     _schedule_enable ;;
        disable)    _schedule_disable ;;
        run-now)    _schedule_run_now ;;
        run-cycle)  _schedule_run_cycle ;;
        *)
            log_error "Unknown schedule subcommand: $1"
            printf 'Valid: status, enable, disable, run-now\n'
            return 2
            ;;
    esac
}
