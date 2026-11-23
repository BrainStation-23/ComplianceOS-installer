#!/usr/bin/env bash
# Exercise restic's pure helpers - role/path/string mapping and the retention
# argument builder - in isolation from the restic binary or a real
# repository. Everything that actually shells out to `restic` (_restic_run
# and everything built on it) is a thin wrapper exercised manually, not here
# - see the wiki page Offsite-Backups.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/restic.sh"

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
config_make_dirs

# --- path/string mapping -----------------------------------------------------
check "password file path (secondary)" "${CONFIG_DIR}/restic-secondary.pass" "$(_restic_password_file secondary)"
check "password file path (offsite)"   "${CONFIG_DIR}/restic-offsite.pass"   "$(_restic_password_file offsite)"
check "credentials file path"          "${CONFIG_DIR}/restic-secondary.env" "$(_restic_credentials_file secondary)"

check "config var: enabled"        "RESTIC_SECONDARY_ENABLED"        "$(_restic_config_var secondary ENABLED)"
check "config var: repository"     "RESTIC_OFFSITE_REPOSITORY"       "$(_restic_config_var offsite REPOSITORY)"
check "config var: keep-daily"     "RESTIC_SECONDARY_KEEP_DAILY"     "$(_restic_config_var secondary KEEP_DAILY)"
check "config var: arbitrary state key" "RESTIC_OFFSITE_LAST_CHECK_AT" "$(_restic_config_var offsite LAST_CHECK_AT)"

# --- retention argument construction -----------------------------------------
args="$(_restic_forget_args 7 4 6)"
check "forget args: daily present"   "1" "$(grep -c -- '--keep-daily'   <<<"$args")"
check "forget args: daily value"     "1" "$(grep -cx '7' <<<"$args")"
check "forget args: weekly present"  "1" "$(grep -c -- '--keep-weekly'  <<<"$args")"
check "forget args: monthly present" "1" "$(grep -c -- '--keep-monthly' <<<"$args")"
check "forget args: always prunes"   "1" "$(grep -c -- '--prune' <<<"$args")"

# A "0" keep-value omits that flag entirely, so a role can disable a bucket.
args_no_daily="$(_restic_forget_args 0 4 6)"
check "forget args: 0 omits --keep-daily"  "0" "$(grep -c -- '--keep-daily'   <<<"$args_no_daily")"
check "forget args: weekly/monthly still present" "2" \
    "$(grep -c -- '--keep-weekly\|--keep-monthly' <<<"$args_no_daily")"

args_all_zero="$(_restic_forget_args 0 0 0)"
check "forget args: all zero still prunes, no keep flags" \
    "--prune" "$(printf '%s\n' "$args_all_zero" | tr -d '\n')"

# --- env_keys (lib/common.sh) against a realistic credentials file ---------
CREDS="${T}/creds.env"
cat >"$CREDS" <<'EOF'
# comment, blank line and inline value below should all be handled
AWS_ACCESS_KEY_ID=AKIAEXAMPLE

AWS_SECRET_ACCESS_KEY=shh
EOF
keys="$(env_keys "$CREDS")"
check "env_keys count"        "2"                      "$(printf '%s\n' "$keys" | grep -c '.')"
check "env_keys first key"    "AWS_ACCESS_KEY_ID"      "$(printf '%s\n' "$keys" | sed -n 1p)"
check "env_keys second key"   "AWS_SECRET_ACCESS_KEY"  "$(printf '%s\n' "$keys" | sed -n 2p)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
