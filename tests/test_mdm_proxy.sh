#!/usr/bin/env bash
# Exercise the Windows MDM proxy (#18): the Caddyfile it generates, the
# certificate checks and copy, and how the container is started. docker is a
# shell function, so nothing here needs a Docker daemon; openssl is real.
#
# The generated Caddyfile was also run in caddy:2.11.7-alpine against an echo
# server: it requests a client certificate, forwards it as base64 DER with
# the secret, overwrites both headers when a client sends them, and answers
# 404 off the MDM paths.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/supabase.sh"
source "${ROOT}/lib/frontend.sh"
source "${ROOT}/lib/mdm_proxy.sh"

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
# Git Bash on Windows: leave -subj "/CN=..." alone (no effect elsewhere)
export MSYS2_ARG_CONV_EXCL="/CN"
CONFIG_DIR="${T}/config"; mkdir -p "$CONFIG_DIR"
export SUPABASE_DIR="${T}/supabase"; mkdir -p "$SUPABASE_DIR"; : >"${SUPABASE_DIR}/.env"
APP_CONTAINER_NAME="sentinel-ops-frontend"; APP_PORT=41820
MDM_CLIENT_CERT_HEADER=""; MDM_PROXY_SECRET_HEADER=""
MDM_PROXY_PORT=8443; MDM_PROXY_BIND="0.0.0.0"; MDM_PROXY_IMAGE="caddy:2.11.7-alpine"
SO_LOG_FILE=""

cert() { openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1" -out "$2" -days 30 -subj "/CN=$3" >/dev/null 2>&1; }
cert "${T}/a.key" "${T}/a.pem" mdm.example.com
cert "${T}/b.key" "${T}/b.pem" other.example.com

# --- the Caddyfile ---------------------------------------------------------------
CF="$(mdm_proxy_caddyfile)"
check "requests, doesn't require, a client certificate" "1" "$(grep -c 'mode request' <<<"$CF")"
check "serves only the MDM paths" "1" \
    "$(grep -c '@mdm path /EnrollmentServer/Policy.svc /EnrollmentServer/Enrollment.svc /ManagementServer/MDM.svc' <<<"$CF")"
check "answers 404 elsewhere" "1" "$(grep -c 'respond 404' <<<"$CF")"
check "forwards to the frontend by name" "1" "$(grep -c 'reverse_proxy sentinel-ops-frontend:41820' <<<"$CF")"
check "the certificate as base64 DER" "1" \
    "$(grep -c 'header_up X-Client-Cert {http.request.tls.client.certificate_der_base64}' <<<"$CF")"
check "the secret from the environment, not the file" "1" \
    "$(grep -c 'header_up X-MDM-Proxy-Secret {\$MDM_PROXY_SECRET}' <<<"$CF")"
MDM_CLIENT_CERT_HEADER="X-SSL-Cert"; MDM_PROXY_SECRET_HEADER="X-Proxy-Token"
CF="$(mdm_proxy_caddyfile)"
check "header names follow the overrides" "2" "$(grep -cE 'header_up (X-SSL-Cert|X-Proxy-Token) ' <<<"$CF")"
MDM_CLIENT_CERT_HEADER=""; MDM_PROXY_SECRET_HEADER=""

# --- the certificate --------------------------------------------------------------
mdm_proxy_check_pair "${T}/a.pem" "${T}/a.key" >/dev/null
check "a certificate and its key pass" "0" "$?"
mdm_proxy_check_pair "${T}/a.pem" "${T}/b.key" >/dev/null
check "another certificate's key fails" "1" "$?"
mdm_proxy_check_pair "${T}/missing.pem" "${T}/a.key" >/dev/null
check "a missing certificate fails" "1" "$?"
mdm_proxy_check_pair "${T}/a.key" "${T}/a.key" >/dev/null
check "a key passed as the certificate fails" "1" "$?"

MDM_PROXY_CERT_FILE="${T}/a.pem"; MDM_PROXY_KEY_FILE="${T}/a.key"
check "the first copy is new" "changed" "$(mdm_proxy_sync_cert 2>/dev/null)"
check "a second sync changes nothing" "same" "$(mdm_proxy_sync_cert 2>/dev/null)"
cp "${T}/b.pem" "${T}/a.pem"; cp "${T}/b.key" "${T}/a.key"
check "a renewed source is copied again" "changed" "$(mdm_proxy_sync_cert 2>/dev/null)"
check "the served copy is the renewed one" "$(file_sha256 "${T}/b.pem")" "$(file_sha256 "${CONFIG_DIR}/mdm-proxy/tls/cert.pem")"
check "the host to probe is the certificate's" "other.example.com" "$(mdm_proxy_cert_host)"
days="$(mdm_proxy_cert_days_left)"
check "days left are counted" "1" "$(( days >= 28 && days <= 30 ))"

# --- the container -----------------------------------------------------------------
ARGV="${T}/argv"; SEEN="${T}/seen"; NET_OK=1
docker() {
    case "$1" in
        network) (( NET_OK )) ;;
        rm) return 0 ;;
        run) printf '%s\n' "$@" >"$ARGV"; printf '%s' "${MDM_PROXY_SECRET:-}" >"$SEEN" ;;
    esac
}
run_logged() { shift; "$@"; }
supabase_network_name() { printf 'supabase_default'; }

mdm_proxy_start >/dev/null 2>&1
secret="$(env_get "${SUPABASE_DIR}/.env" MDM_PROXY_SECRET)"
check "the secret is the app's (generated if needed)" "64" "${#secret}"
check "the container sees it" "$secret" "$(cat "$SEEN")"
check "passed by name" "1" "$(grep -cx -- '-e' "$ARGV" >/dev/null; grep -cx -- 'MDM_PROXY_SECRET' "$ARGV")"
check "never by value" "0" "$(grep -c -- "$secret" "$ARGV")"
check "on the Supabase network" "1" "$(grep -cx -- 'supabase_default' "$ARGV")"
check "publishing the MDM port" "1" "$(grep -cx -- '0.0.0.0:8443:8443' "$ARGV")"
check "the pinned image" "1" "$(grep -cx -- 'caddy:2.11.7-alpine' "$ARGV")"
check "the Caddyfile is written" "1" "$(grep -c 'mode request' "${CONFIG_DIR}/mdm-proxy/Caddyfile")"
check "the Caddyfile holds no secret" "0" "$(grep -c -- "$secret" "${CONFIG_DIR}/mdm-proxy/Caddyfile")"

NET_OK=0
mdm_proxy_start >/dev/null 2>&1
check "without the Supabase network it refuses to start" "1" "$?"

# --- the daily refresh -------------------------------------------------------------
SO_BIN_LINK="/usr/local/bin/sentinel-ops"; INSTALL_DIR="/opt/sentinel-ops"
check "the timer runs sync-cert" "1" \
    "$(mdm_proxy_unit_text service | grep -c 'ExecStart=/usr/local/bin/sentinel-ops --dir /opt/sentinel-ops mdm-proxy sync-cert')"
check "daily" "1" "$(mdm_proxy_unit_text timer | grep -c 'OnCalendar=daily')"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
