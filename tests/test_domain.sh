#!/usr/bin/env bash
# Exercise `sentinel-ops domain set`'s config transform in isolation from
# Docker. `_domain_apply_settings` is deliberately pure (no container restart,
# same split as `_nuke_filesystem`/`cmd_nuke`), so it is tested directly
# against the files it writes - which is exactly what the LAN/localhost bug
# report (Design-Decisions #22) showed missing: URLs updated in memory but
# never persisted to supabase/.env, where Kong and GoTrue actually read them.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/supabase.sh"
source "${ROOT}/lib/commands/domain.sh"

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

# --- hostname normalisation --------------------------------------------------
check "strips scheme and path" "app.example.com" "$(_domain_normalize_host 'https://app.example.com/some/path')"
check "strips a port"          "app.example.com" "$(_domain_normalize_host 'app.example.com:8443')"
check "accepts a bare host"    "app.example.com" "$(_domain_normalize_host 'app.example.com')"

# --- the config transform ----------------------------------------------------
T="$(mktemp -d)"
config_set_paths "${T}/root"
config_make_dirs
mkdir -p "$SUPABASE_DIR"
printf 'SITE_URL=http://192.168.1.50:41820\nADDITIONAL_REDIRECT_URLS=\n' >"${SUPABASE_DIR}/.env"

APP_PORT="41820"
APP_BIND="0.0.0.0"
SUPABASE_PUBLIC_URL="http://192.168.1.50:8000"
API_EXTERNAL_URL="http://192.168.1.50:8000"
SITE_URL="http://192.168.1.50:41820"

_domain_apply_settings "app.example.com" >/dev/null 2>&1

check "SUPABASE_PUBLIC_URL becomes https" "https://app.example.com" "$SUPABASE_PUBLIC_URL"
check "API_EXTERNAL_URL becomes https"    "https://app.example.com" "$API_EXTERNAL_URL"
check "SITE_URL becomes https"            "https://app.example.com" "$SITE_URL"
check "APP_BIND reverts to loopback"      "127.0.0.1"                "$APP_BIND"

check "installer.env persisted"  "https://app.example.com" "$(env_get "$CONFIG_FILE" SITE_URL)"
check "installer.env bind"       "127.0.0.1"                "$(env_get "$CONFIG_FILE" APP_BIND)"
check "supabase/.env persisted"  "https://app.example.com" "$(env_get "${SUPABASE_DIR}/.env" SITE_URL)"
check "redirect urls updated"    "https://app.example.com/**" "$(env_get "${SUPABASE_DIR}/.env" ADDITIONAL_REDIRECT_URLS)"

# A second call is idempotent: no duplicate redirect-url entries.
_domain_apply_settings "app.example.com" >/dev/null 2>&1
check "redirect urls stay singular on re-run" "https://app.example.com/**" \
    "$(env_get "${SUPABASE_DIR}/.env" ADDITIONAL_REDIRECT_URLS)"

# An empty hostname is refused rather than writing a broken "https://" URL.
BEFORE_SITE_URL="$SITE_URL"
_domain_apply_settings "" >/dev/null 2>&1
rc=$?
check "empty host is rejected"        "1"              "$rc"
check "empty host leaves URL untouched" "$BEFORE_SITE_URL" "$SITE_URL"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
