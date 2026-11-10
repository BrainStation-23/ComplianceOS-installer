#!/usr/bin/env bash
# lib/config.sh - persistent installer configuration and deployment state.
# shellcheck shell=bash

# Default installation root. Overridable at install time and then persisted.
SO_DEFAULT_INSTALL_DIR="/opt/sentinel-ops"

# Derived paths, set by config_set_paths().
INSTALL_DIR=""
CONFIG_DIR=""
CONFIG_FILE=""
SUPABASE_DIR=""
APP_DIR=""
BACKUP_DIR=""
STATE_DIR=""
STATE_FILE=""
PHASE_DIR=""
LOG_DIR=""
RUNTIME_DIR=""

# Configuration values (defaults; overridden by installer.env).
APP_REPOSITORY="git@github.com:BrainStation-23/sentinel-ops.git"
APP_BRANCH="main"
DEPLOY_KEY=""
# Public endpoints. The defaults are the local ports the stack actually binds,
# so an install with no arguments produces a working deployment on this host.
# Pass real hostnames (or answer the prompts) when putting it behind a domain.
SUPABASE_PUBLIC_URL="http://localhost:8000"
API_EXTERNAL_URL="http://localhost:8000"
SITE_URL="http://localhost:41820"
# Deliberately not 3000, 8000, 5432 or 6543: Supabase's own stack always
# claims those (Studio, Kong, Postgres and its pooler respectively), so a
# fresh host with nothing else running would still collide with itself on a
# plain default install. See frontend_prompt_config() in lib/frontend.sh,
# which re-checks this at install time.
APP_PORT="41820"
# Where the frontend's published port is bound. The reverse proxy is the
# operator's responsibility, so the default is loopback: a proxy on this host
# reaches it, the public internet does not. Set to 0.0.0.0 only if the proxy
# runs on a different machine.
APP_BIND="127.0.0.1"
APP_IMAGE_NAME="sentinel-ops"
APP_CONTAINER_NAME="sentinel-ops-frontend"
ENABLE_LOGFLARE="true"
# Azure AD (Microsoft Entra ID) sign-in. Non-secret only - the client secret
# lives solely in supabase/.env, never here. See lib/azure.sh.
ENABLE_AZURE_AD="false"
AZURE_CLIENT_ID=""
AZURE_TENANT_ID=""
# Optional Supabase Auth hardening, all off by default. Non-secret only - the
# Turnstile secret lives solely in supabase/.env. See lib/hardening.sh.
AUTH_DISABLE_SIGNUP="false"
AUTH_PASSWORD_POLICY="false"
AUTH_PASSWORD_MIN_LENGTH="12"
AUTH_HIBP_ENABLED="false"
AUTH_HIBP_FAIL_CLOSED="false"
AUTH_CAPTCHA_ENABLED="false"
TURNSTILE_SITE_KEY=""
AUTH_RATE_LIMIT_HEADER=""
AUTH_RATE_LIMIT_TOKEN=""
# Windows MDM (sentinel-ops#550): the headers the reverse proxy forwards the
# client certificate and the shared secret in. Empty uses the app's defaults,
# X-Client-Cert and X-MDM-Proxy-Secret. The secret itself lives only in
# supabase/.env (lib/frontend.sh:frontend_mdm_proxy_secret).
MDM_CLIENT_CERT_HEADER=""
MDM_PROXY_SECRET_HEADER=""
# The Windows MDM proxy (lib/mdm_proxy.sh, #18): Caddy on a port of its own for
# what needs the PC's client certificate, when the front proxy can't request
# one (Zoraxy). The console's Settings -> MDM -> MDM port must match the port.
MDM_PROXY_ENABLED="false"
MDM_PROXY_PORT="9443"
MDM_PROXY_BIND="0.0.0.0"
MDM_PROXY_CERT_FILE=""
MDM_PROXY_KEY_FILE=""
MDM_PROXY_IMAGE="caddy:2.11.7-alpine"
# Where the proxy's certificate comes from: "files" (CERT_FILE/KEY_FILE, issued
# elsewhere) or "cloudflare" (Let's Encrypt for MDM_PROXY_DOMAIN through a
# Cloudflare DNS challenge, run in the certbot image). The Cloudflare token
# lives only in config/mdm-proxy/cloudflare.ini.
MDM_PROXY_CERT_SOURCE="files"
MDM_PROXY_DOMAIN=""
MDM_PROXY_ACME_EMAIL=""
MDM_PROXY_CERTBOT_IMAGE="certbot/dns-cloudflare:v5.8.0"
# Supabase Storage's global upload limit in bytes (lib/storage.sh). Upstream
# ships 50 MiB; the application's installer bucket allows 4 GiB.
STORAGE_FILE_SIZE_LIMIT="4294967296"
# Removing superseded Docker images after updates (lib/images.sh). The build
# cache age is a docker duration such as 168h.
IMAGE_CLEANUP_ENABLED="true"
IMAGE_BUILD_CACHE_MAX_AGE="168h"
# Local backup retention (lib/backup.sh:_backup_prune_candidates): at most
# this many, and at most this many GiB in total - "auto" is a fifth of the
# filesystem, 0 is no size limit.
BACKUP_RETENTION_COUNT="10"
BACKUP_RETENTION_MAX_GB="auto"
# Table data a database backup leaves out (lib/backup.sh): logs, telemetry and
# derived state, on top of the built-in list. Space-separated
# <database>:<schema>.<table> patterns, * allowed. BACKUP_INCLUDE_LOG_DATA=true
# turns every exclusion off and dumps everything.
BACKUP_EXCLUDE_DATA=""
BACKUP_INCLUDE_LOG_DATA="false"
# Installer run logs older than this many days are removed (lib/disk.sh); 0
# keeps them all.
LOG_RETENTION_DAYS="30"
# Size limit on every container's log (lib/container_logs.sh): this many files
# of at most this size, per container.
CONTAINER_LOG_MAX_SIZE="50m"
CONTAINER_LOG_MAX_FILES="3"
# Scheduled backups (lib/commands/schedule.sh). Off by default; see
# `sentinel-ops schedule enable`. CHECK_DAY names the day restic's own
# integrity check runs against configured remotes, not every night's backup.
BACKUP_SCHEDULE_ENABLED="false"
BACKUP_SCHEDULE_CALENDAR="daily"
BACKUP_SCHEDULE_CHECK_DAY="Sun"
# 3-2-1's "different medium" and "offsite" copies (lib/restic.sh,
# lib/commands/remote.sh). Both off by default - repository URLs are not
# secrets, but the repository password and any backend credentials never live
# here; see _restic_password_file()/_restic_credentials_file().
RESTIC_SECONDARY_ENABLED="false"
RESTIC_SECONDARY_REPOSITORY=""
RESTIC_SECONDARY_KEEP_DAILY="7"
RESTIC_SECONDARY_KEEP_WEEKLY="4"
RESTIC_SECONDARY_KEEP_MONTHLY="6"
RESTIC_OFFSITE_ENABLED="false"
RESTIC_OFFSITE_REPOSITORY=""
RESTIC_OFFSITE_KEEP_DAILY="7"
RESTIC_OFFSITE_KEEP_WEEKLY="4"
RESTIC_OFFSITE_KEEP_MONTHLY="6"
# Unattended application updates (lib/commands/autoupdate.sh). Off by
# default; see `sentinel-ops auto-update enable`. The calendar is how often the
# remote branch is *checked* - an update only runs when it has moved.
AUTO_UPDATE_ENABLED="false"
AUTO_UPDATE_CALENDAR="hourly"
# An auto-update is skipped while less than this many GiB are free where it
# would write (lib/disk.sh); 0 turns the check off.
AUTO_UPDATE_MIN_FREE_GB="5"
# Branch of the installer repository `sentinel-ops self-update` pulls from
# (lib/selfupdate.sh). SENTINEL_OPS_INSTALLER_BRANCH overrides it per run.
INSTALLER_BRANCH="main"

# Establish every path from the installation root.
config_set_paths() {
    INSTALL_DIR="$(strip_trailing_slash "$1")"
    CONFIG_DIR="${INSTALL_DIR}/config"
    CONFIG_FILE="${CONFIG_DIR}/installer.env"
    SUPABASE_DIR="${INSTALL_DIR}/supabase"
    APP_DIR="${INSTALL_DIR}/app"
    BACKUP_DIR="${INSTALL_DIR}/backups"
    STATE_DIR="${INSTALL_DIR}/.state"
    STATE_FILE="${STATE_DIR}/state.env"
    PHASE_DIR="${STATE_DIR}/phases"
    LOG_DIR="${INSTALL_DIR}/logs"
    RUNTIME_DIR="${INSTALL_DIR}/runtime"
}

config_make_dirs() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$STATE_DIR" "$PHASE_DIR" \
             "$LOG_DIR" "$RUNTIME_DIR"
    # Config and state hold URLs and deployment metadata; keep them private.
    chmod 750 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
}

# True when a previous installation exists at this root.
installation_exists() {
    [[ -f "$CONFIG_FILE" ]]
}

# Load installer.env. Values are read key by key so that the file can never
# execute arbitrary shell.
config_load() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    local key val
    for key in APP_REPOSITORY APP_BRANCH DEPLOY_KEY SUPABASE_PUBLIC_URL \
               API_EXTERNAL_URL SITE_URL APP_PORT APP_BIND APP_IMAGE_NAME \
               APP_CONTAINER_NAME ENABLE_LOGFLARE \
               ENABLE_AZURE_AD AZURE_CLIENT_ID AZURE_TENANT_ID \
               AUTH_DISABLE_SIGNUP AUTH_PASSWORD_POLICY AUTH_PASSWORD_MIN_LENGTH \
               AUTH_HIBP_ENABLED AUTH_HIBP_FAIL_CLOSED AUTH_CAPTCHA_ENABLED \
               TURNSTILE_SITE_KEY AUTH_RATE_LIMIT_HEADER AUTH_RATE_LIMIT_TOKEN \
               MDM_CLIENT_CERT_HEADER MDM_PROXY_SECRET_HEADER \
               MDM_PROXY_ENABLED MDM_PROXY_PORT MDM_PROXY_BIND \
               MDM_PROXY_CERT_FILE MDM_PROXY_KEY_FILE MDM_PROXY_IMAGE \
               MDM_PROXY_CERT_SOURCE MDM_PROXY_DOMAIN MDM_PROXY_ACME_EMAIL \
               MDM_PROXY_CERTBOT_IMAGE \
               STORAGE_FILE_SIZE_LIMIT IMAGE_CLEANUP_ENABLED IMAGE_BUILD_CACHE_MAX_AGE \
               BACKUP_RETENTION_COUNT BACKUP_RETENTION_MAX_GB LOG_RETENTION_DAYS \
               BACKUP_EXCLUDE_DATA BACKUP_INCLUDE_LOG_DATA \
               CONTAINER_LOG_MAX_SIZE CONTAINER_LOG_MAX_FILES \
               BACKUP_SCHEDULE_ENABLED BACKUP_SCHEDULE_CALENDAR BACKUP_SCHEDULE_CHECK_DAY \
               RESTIC_SECONDARY_ENABLED RESTIC_SECONDARY_REPOSITORY \
               RESTIC_SECONDARY_KEEP_DAILY RESTIC_SECONDARY_KEEP_WEEKLY RESTIC_SECONDARY_KEEP_MONTHLY \
               RESTIC_OFFSITE_ENABLED RESTIC_OFFSITE_REPOSITORY \
               RESTIC_OFFSITE_KEEP_DAILY RESTIC_OFFSITE_KEEP_WEEKLY RESTIC_OFFSITE_KEEP_MONTHLY \
               AUTO_UPDATE_ENABLED AUTO_UPDATE_CALENDAR AUTO_UPDATE_MIN_FREE_GB \
               INSTALLER_BRANCH; do
        val="$(env_get "$CONFIG_FILE" "$key" || true)"
        [[ -n "$val" ]] && printf -v "$key" '%s' "$val"
    done
    return 0
}

config_save() {
    config_make_dirs
    local tmp
    tmp="$(mktemp)"
    {
        printf '# Sentinel Ops installer configuration\n'
        printf '# Generated by sentinel-ops %s\n' "$SO_INSTALLER_VERSION"
        printf '# Edit with care: this file is read by every update run.\n\n'
        printf 'INSTALL_DIR=%s\n'           "$INSTALL_DIR"
        printf 'SUPABASE_DIR=%s\n'          "$SUPABASE_DIR"
        printf 'APP_DIR=%s\n'               "$APP_DIR"
        # Informational only - always derived from INSTALL_DIR in
        # config_set_paths(), never read back by config_load(). The "second
        # medium" leg of 3-2-1 is RESTIC_SECONDARY_*, not a relocated hot
        # copy; see docs/DECISIONS.md.
        printf 'BACKUP_DIR=%s\n\n'          "$BACKUP_DIR"
        printf '# Application repository\n'
        printf 'APP_REPOSITORY=%s\n'        "$APP_REPOSITORY"
        printf 'APP_BRANCH=%s\n'            "$APP_BRANCH"
        printf 'DEPLOY_KEY=%s\n\n'          "$DEPLOY_KEY"
        printf '# Public endpoints\n'
        printf 'SUPABASE_PUBLIC_URL=%s\n'   "$SUPABASE_PUBLIC_URL"
        printf 'API_EXTERNAL_URL=%s\n'      "$API_EXTERNAL_URL"
        printf 'SITE_URL=%s\n\n'            "$SITE_URL"
        printf '# Frontend runtime. Point your own reverse proxy at\n'
        printf '# APP_BIND:APP_PORT, and at Supabase Kong for the API.\n'
        printf 'APP_PORT=%s\n'              "$APP_PORT"
        printf 'APP_BIND=%s\n'              "$APP_BIND"
        printf 'APP_IMAGE_NAME=%s\n'        "$APP_IMAGE_NAME"
        printf 'APP_CONTAINER_NAME=%s\n\n'  "$APP_CONTAINER_NAME"
        printf '# Analytics (Logflare) - see docs/LOGFLARE.md\n'
        printf 'ENABLE_LOGFLARE=%s\n\n'     "$ENABLE_LOGFLARE"
        printf '# Azure AD sign-in - see docs/AZURE-AD.md. The client secret is\n'
        printf '# never written here; it lives only in supabase/.env.\n'
        printf 'ENABLE_AZURE_AD=%s\n'       "$ENABLE_AZURE_AD"
        printf 'AZURE_CLIENT_ID=%s\n'       "$AZURE_CLIENT_ID"
        printf 'AZURE_TENANT_ID=%s\n\n'     "$AZURE_TENANT_ID"
        printf '# Auth hardening - see docs/AUTH-HARDENING.md. The Turnstile secret is\n'
        printf '# never written here; it lives only in supabase/.env.\n'
        printf 'AUTH_DISABLE_SIGNUP=%s\n'      "$AUTH_DISABLE_SIGNUP"
        printf 'AUTH_PASSWORD_POLICY=%s\n'     "$AUTH_PASSWORD_POLICY"
        printf 'AUTH_PASSWORD_MIN_LENGTH=%s\n' "$AUTH_PASSWORD_MIN_LENGTH"
        printf 'AUTH_HIBP_ENABLED=%s\n'        "$AUTH_HIBP_ENABLED"
        printf 'AUTH_HIBP_FAIL_CLOSED=%s\n'    "$AUTH_HIBP_FAIL_CLOSED"
        printf 'AUTH_CAPTCHA_ENABLED=%s\n'     "$AUTH_CAPTCHA_ENABLED"
        printf 'TURNSTILE_SITE_KEY=%s\n'       "$TURNSTILE_SITE_KEY"
        printf 'AUTH_RATE_LIMIT_HEADER=%s\n'   "$AUTH_RATE_LIMIT_HEADER"
        printf 'AUTH_RATE_LIMIT_TOKEN=%s\n\n'  "$AUTH_RATE_LIMIT_TOKEN"
        printf '# Windows MDM client certificates - see docs/REVERSE-PROXY.md. Empty\n'
        printf '# uses the app defaults; the proxy secret lives only in supabase/.env.\n'
        printf 'MDM_CLIENT_CERT_HEADER=%s\n'    "$MDM_CLIENT_CERT_HEADER"
        printf 'MDM_PROXY_SECRET_HEADER=%s\n\n' "$MDM_PROXY_SECRET_HEADER"
        printf '# Windows MDM proxy (sentinel-ops mdm-proxy) - see docs/REVERSE-PROXY.md\n'
        printf 'MDM_PROXY_ENABLED=%s\n'   "$MDM_PROXY_ENABLED"
        printf 'MDM_PROXY_PORT=%s\n'      "$MDM_PROXY_PORT"
        printf 'MDM_PROXY_BIND=%s\n'      "$MDM_PROXY_BIND"
        printf 'MDM_PROXY_CERT_FILE=%s\n' "$MDM_PROXY_CERT_FILE"
        printf 'MDM_PROXY_KEY_FILE=%s\n'  "$MDM_PROXY_KEY_FILE"
        printf 'MDM_PROXY_IMAGE=%s\n'    "$MDM_PROXY_IMAGE"
        printf '# files, or cloudflare (Let'"'"'s Encrypt through Cloudflare DNS). The token\n'
        printf '# is never written here; it lives only in config/mdm-proxy/cloudflare.ini.\n'
        printf 'MDM_PROXY_CERT_SOURCE=%s\n'     "$MDM_PROXY_CERT_SOURCE"
        printf 'MDM_PROXY_DOMAIN=%s\n'          "$MDM_PROXY_DOMAIN"
        printf 'MDM_PROXY_ACME_EMAIL=%s\n'      "$MDM_PROXY_ACME_EMAIL"
        printf 'MDM_PROXY_CERTBOT_IMAGE=%s\n\n' "$MDM_PROXY_CERTBOT_IMAGE"
        printf '# Storage upload limit in bytes - see docs/REVERSE-PROXY.md\n'
        printf 'STORAGE_FILE_SIZE_LIMIT=%s\n\n' "$STORAGE_FILE_SIZE_LIMIT"
        printf '# Docker image cleanup after updates - see docs/OPERATIONS.md\n'
        printf 'IMAGE_CLEANUP_ENABLED=%s\n'     "$IMAGE_CLEANUP_ENABLED"
        printf 'IMAGE_BUILD_CACHE_MAX_AGE=%s\n\n' "$IMAGE_BUILD_CACHE_MAX_AGE"
        printf '# Disk space - see docs/OPERATIONS.md\n'
        printf 'LOG_RETENTION_DAYS=%s\n'         "$LOG_RETENTION_DAYS"
        printf 'CONTAINER_LOG_MAX_SIZE=%s\n'     "$CONTAINER_LOG_MAX_SIZE"
        printf 'CONTAINER_LOG_MAX_FILES=%s\n\n'  "$CONTAINER_LOG_MAX_FILES"
        printf '# Backups - see docs/BACKUPS.md\n'
        printf 'BACKUP_RETENTION_COUNT=%s\n' "$BACKUP_RETENTION_COUNT"
        printf 'BACKUP_RETENTION_MAX_GB=%s\n' "$BACKUP_RETENTION_MAX_GB"
        printf 'BACKUP_EXCLUDE_DATA="%s"\n'   "$BACKUP_EXCLUDE_DATA"
        printf 'BACKUP_INCLUDE_LOG_DATA=%s\n' "$BACKUP_INCLUDE_LOG_DATA"
        printf 'BACKUP_SCHEDULE_ENABLED=%s\n'  "$BACKUP_SCHEDULE_ENABLED"
        printf 'BACKUP_SCHEDULE_CALENDAR=%s\n' "$BACKUP_SCHEDULE_CALENDAR"
        printf 'BACKUP_SCHEDULE_CHECK_DAY=%s\n\n' "$BACKUP_SCHEDULE_CHECK_DAY"
        printf '# Offsite/secondary replication (restic). Repository passwords and\n'
        printf '# backend credentials are never written here; see config/restic-*.pass\n'
        printf '# and config/restic-*.env.\n'
        printf 'RESTIC_SECONDARY_ENABLED=%s\n'      "$RESTIC_SECONDARY_ENABLED"
        printf 'RESTIC_SECONDARY_REPOSITORY=%s\n'   "$RESTIC_SECONDARY_REPOSITORY"
        printf 'RESTIC_SECONDARY_KEEP_DAILY=%s\n'   "$RESTIC_SECONDARY_KEEP_DAILY"
        printf 'RESTIC_SECONDARY_KEEP_WEEKLY=%s\n'  "$RESTIC_SECONDARY_KEEP_WEEKLY"
        printf 'RESTIC_SECONDARY_KEEP_MONTHLY=%s\n\n' "$RESTIC_SECONDARY_KEEP_MONTHLY"
        printf 'RESTIC_OFFSITE_ENABLED=%s\n'      "$RESTIC_OFFSITE_ENABLED"
        printf 'RESTIC_OFFSITE_REPOSITORY=%s\n'   "$RESTIC_OFFSITE_REPOSITORY"
        printf 'RESTIC_OFFSITE_KEEP_DAILY=%s\n'   "$RESTIC_OFFSITE_KEEP_DAILY"
        printf 'RESTIC_OFFSITE_KEEP_WEEKLY=%s\n'  "$RESTIC_OFFSITE_KEEP_WEEKLY"
        printf 'RESTIC_OFFSITE_KEEP_MONTHLY=%s\n\n' "$RESTIC_OFFSITE_KEEP_MONTHLY"
        printf '# Updates - see docs/OPERATIONS.md\n'
        printf 'AUTO_UPDATE_ENABLED=%s\n'   "$AUTO_UPDATE_ENABLED"
        printf 'AUTO_UPDATE_CALENDAR=%s\n'  "$AUTO_UPDATE_CALENDAR"
        printf 'AUTO_UPDATE_MIN_FREE_GB=%s\n' "$AUTO_UPDATE_MIN_FREE_GB"
        printf 'INSTALLER_BRANCH=%s\n'      "$INSTALLER_BRANCH"
    } >"$tmp"
    cat "$tmp" >"$CONFIG_FILE"
    rm -f "$tmp"
    chmod 640 "$CONFIG_FILE" 2>/dev/null || true
    log_debug "configuration written to ${CONFIG_FILE}"
}

# ---------------------------------------------------------------------------
# Deployment state
# ---------------------------------------------------------------------------

state_get() {
    local key="$1" fallback="${2:-}" val
    val="$(env_get "$STATE_FILE" "$key" 2>/dev/null || true)"
    if [[ -n "$val" ]]; then printf '%s' "$val"; else printf '%s' "$fallback"; fi
}

state_set() {
    mkdir -p "$STATE_DIR"
    [[ -f "$STATE_FILE" ]] || {
        printf '# Sentinel Ops deployment state - managed automatically.\n' >"$STATE_FILE"
        chmod 640 "$STATE_FILE" 2>/dev/null || true
    }
    env_set "$STATE_FILE" "$1" "$2"
}

state_touch_updated() {
    state_set UPDATED_AT "$(date -Is 2>/dev/null || date)"
}

# ---------------------------------------------------------------------------
# Phase markers - the basis of idempotent re-runs
#
# A completed phase drops a marker file. On a re-run the installer skips a
# phase whose marker exists, so a failure late in the process does not force
# Supabase to be reinstalled or secrets to be regenerated.
# ---------------------------------------------------------------------------

phase_done() {
    [[ -f "${PHASE_DIR}/$1" ]]
}

phase_mark() {
    mkdir -p "$PHASE_DIR"
    printf '%s\n' "$(date -Is 2>/dev/null || date)" >"${PHASE_DIR}/$1"
}

phase_clear() {
    rm -f "${PHASE_DIR}/$1"
}

# Run a phase once. If its marker exists the phase is skipped unless
# SO_FORCE_PHASES=true. Usage: phase_once <name> <description> <function>
phase_once() {
    local name="$1" desc="$2" fn="$3"
    if phase_done "$name" && [[ "${SO_FORCE_PHASES:-false}" != "true" ]]; then
        log_ok "${desc} (already completed, skipping)"
        return 0
    fi
    phase_begin "$desc"
    if "$fn"; then
        phase_mark "$name"
        phase_end
        return 0
    fi
    return 1
}
