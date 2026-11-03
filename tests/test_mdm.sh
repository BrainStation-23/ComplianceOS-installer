#!/usr/bin/env bash
# Exercise the Windows MDM proxy secret (sentinel-ops#550): generated once into
# supabase/.env, reused afterwards, and handed to the frontend container by
# name so the value never reaches the docker argv the installer logs.
#
# docker and run_logged are replaced with shell functions, so nothing here
# needs a Docker daemon.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/supabase.sh"
source "${ROOT}/lib/frontend.sh"

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
export SUPABASE_DIR="$T"
ENV="${T}/.env"
printf 'ANON_KEY=anon\nSERVICE_ROLE_KEY=service\nKONG_HTTP_PORT=8000\n' >"$ENV"
APP_PORT=41820; APP_BIND="127.0.0.1"; SUPABASE_PUBLIC_URL="http://localhost:8000"
AUTH_CAPTCHA_ENABLED="false"; TURNSTILE_SITE_KEY=""
MDM_CLIENT_CERT_HEADER=""; MDM_PROXY_SECRET_HEADER=""

# docker: the network exists; record what `docker run` was given, and the
# secret the container would see through its environment.
ARGV_FILE="${T}/argv"; SEEN_FILE="${T}/seen"
docker() {
    case "$1" in
        network) return 0 ;;
        rm) return 0 ;;
        run) printf '%s\n' "$@" >"$ARGV_FILE"; printf '%s' "${MDM_PROXY_SECRET:-}" >"$SEEN_FILE" ;;
    esac
}
run_logged() { shift; "$@"; }
supabase_network_name() { printf 'supabase_default'; }

# --- generated once, then reused ------------------------------------------------
frontend_run_container sentinel-ops-frontend sentinel-ops:test 41820 >/dev/null 2>&1
first="$(env_get "$ENV" MDM_PROXY_SECRET)"
check "a secret is generated into supabase/.env" "64" "${#first}"
check "the container sees the secret" "$first" "$(cat "$SEEN_FILE")"
check "the secret is passed by name" "1" "$(grep -cx -- 'MDM_PROXY_SECRET' "$ARGV_FILE")"
check "the value is never in the argv" "0" "$(grep -c -- "$first" "$ARGV_FILE")"
check "no header overrides by default" "0" "$(grep -c -- 'MDM_.*_HEADER' "$ARGV_FILE")"
check "the secret is unset afterwards" "" "${MDM_PROXY_SECRET:-}"

frontend_run_container sentinel-ops-frontend sentinel-ops:test 41820 >/dev/null 2>&1
check "a second start reuses it" "$first" "$(env_get "$ENV" MDM_PROXY_SECRET)"
check "only one line in supabase/.env" "1" "$(grep -c '^MDM_PROXY_SECRET=' "$ENV")"

# --- a too-short secret (hand-edited) is replaced ----------------------------------
env_set "$ENV" MDM_PROXY_SECRET "short"
frontend_run_container sentinel-ops-frontend sentinel-ops:test 41820 >/dev/null 2>&1
check "a secret under 24 characters is replaced" "64" "$(env_get "$ENV" MDM_PROXY_SECRET | tr -d '\n' | wc -c | tr -d ' ')"

# --- header overrides --------------------------------------------------------------
MDM_CLIENT_CERT_HEADER="X-SSL-Client-Cert"; MDM_PROXY_SECRET_HEADER="X-Proxy-Token"
frontend_run_container sentinel-ops-frontend sentinel-ops:test 41820 >/dev/null 2>&1
check "the certificate header is passed when set" "1" "$(grep -cx -- 'MDM_CLIENT_CERT_HEADER=X-SSL-Client-Cert' "$ARGV_FILE")"
check "the secret header is passed when set" "1" "$(grep -cx -- 'MDM_PROXY_SECRET_HEADER=X-Proxy-Token' "$ARGV_FILE")"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
