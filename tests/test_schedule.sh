#!/usr/bin/env bash
# Exercise the systemd unit text generation and the check-day match - both
# pure string logic, asserted with zero systemd/date involvement. The
# install/enable/disable/run-cycle functions that actually touch systemctl
# or shell out to backup_create_full/restic are not tested here - see
# the wiki page Offsite-Backups.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/commands/schedule.sh"

pass=0; fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
    else
        printf 'FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
        fail=$((fail+1))
    fi
}

T="$(mktemp -d)"
config_set_paths "${T}/root"
SO_BIN_LINK="/usr/local/bin/sentinel-ops"
BACKUP_SCHEDULE_CALENDAR="daily"

# --- service unit -------------------------------------------------------
service_text="$(_schedule_unit_text service)"
check "service has the right ExecStart" "1" \
    "$(grep -Fc "ExecStart=${SO_BIN_LINK} --dir ${INSTALL_DIR} schedule run-cycle" <<<"$service_text")"
check "service is a oneshot" "1" "$(grep -c '^Type=oneshot$' <<<"$service_text")"

# --- timer unit -----------------------------------------------------------
timer_text="$(_schedule_unit_text timer)"
check "timer uses the configured calendar" "1" "$(grep -c '^OnCalendar=daily$' <<<"$timer_text")"
check "timer is persistent (missed runs still fire)" "1" "$(grep -c '^Persistent=true$' <<<"$timer_text")"

BACKUP_SCHEDULE_CALENDAR="*-*-* 03:00:00"
timer_text2="$(_schedule_unit_text timer)"
check "timer calendar reflects a custom expression" "1" \
    "$(grep -Fc 'OnCalendar=*-*-* 03:00:00' <<<"$timer_text2")"

# --- check-day matching -----------------------------------------------------
BACKUP_SCHEDULE_CHECK_DAY="Sun"
check "check day matches Sun"     "0" "$(_schedule_is_check_day Sun; echo $?)"
check "check day rejects Mon"     "1" "$(_schedule_is_check_day Mon; echo $?)"

BACKUP_SCHEDULE_CHECK_DAY="Wed"
for day in Mon Tue Wed Thu Fri Sat Sun; do
    expect="1"; [[ "$day" == "Wed" ]] && expect="0"
    check "check day '${day}' against Wed" "$expect" "$(_schedule_is_check_day "$day"; echo $?)"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
