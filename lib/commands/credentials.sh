#!/usr/bin/env bash
# lib/commands/credentials.sh - controlled disclosure of generated secrets.
#
# Secrets are never written to installer logs or printed during installation.
# This command is the one place that shows them, and it refuses to run for a
# user who could not read supabase/.env directly anyway.
# shellcheck shell=bash

_cred_line() {
    local label="$1" value="$2"
    if [[ -z "$value" ]]; then
        printf '%-26s %s(not set)%s\n' "$label" "$C_DIM" "$C_RESET"
    elif [[ "$SO_SHOW_SECRETS" == "true" ]]; then
        printf '%-26s %s\n' "$label" "$value"
    else
        printf '%-26s %s\n' "$label" "$(mask_secret "$value")"
    fi
}

cmd_credentials() {
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true

    local env_file="${SUPABASE_DIR}/.env"
    [[ -r "$env_file" ]] || die "Cannot read ${env_file} (try running as root)."

    banner "Sentinel Ops Credentials"

    if [[ "$SO_SHOW_SECRETS" != "true" ]]; then
        printf '\n%sValues are masked. Re-run with --show to reveal them.%s\n' "$C_DIM" "$C_RESET"
    else
        printf '\n%sSecrets are shown in full. Do not paste this output anywhere.%s\n' "$C_YELLOW" "$C_RESET"
    fi

    section "Supabase Studio"
    _cred_line "URL"                "$SUPABASE_PUBLIC_URL"
    _cred_line "Username"           "$(env_get "$env_file" DASHBOARD_USERNAME || true)"
    _cred_line "Password"           "$(env_get "$env_file" DASHBOARD_PASSWORD || true)"

    section "Database"
    _cred_line "Host"               "localhost"
    _cred_line "Port"               "$(env_get "$env_file" POSTGRES_PORT || printf '5432')"
    _cred_line "Database"           "$(env_get "$env_file" POSTGRES_DB || printf 'postgres')"
    _cred_line "User"               "$(env_get "$env_file" POSTGRES_USER || printf 'postgres')"
    _cred_line "Password"           "$(env_get "$env_file" POSTGRES_PASSWORD || true)"

    section "API keys"
    _cred_line "Publishable (anon)" "$(supabase_publishable_key || true)"
    _cred_line "Service role"       "$(supabase_service_role_key || true)"
    _cred_line "JWT secret"         "$(env_get "$env_file" JWT_SECRET || true)"

    if [[ "$ENABLE_LOGFLARE" == "true" ]]; then
        section "Logflare"
        _cred_line "Public token"   "$(env_get "$env_file" LOGFLARE_PUBLIC_ACCESS_TOKEN || true)"
        _cred_line "Private token"  "$(env_get "$env_file" LOGFLARE_PRIVATE_ACCESS_TOKEN || true)"
    fi

    section "Windows MDM (reverse proxy)"
    _cred_line "Proxy secret"       "$(env_get "$env_file" MDM_PROXY_SECRET || true)"
    _cred_line "Certificate header" "${MDM_CLIENT_CERT_HEADER:-X-Client-Cert}"
    _cred_line "Secret header"      "${MDM_PROXY_SECRET_HEADER:-X-MDM-Proxy-Secret}"

    printf '\n'
    printf '%sThe service-role key and JWT secret grant full database access.%s\n' "$C_YELLOW" "$C_RESET"
    printf '%sNeither is ever given to the frontend build.%s\n\n' "$C_DIM" "$C_RESET"
    return 0
}
