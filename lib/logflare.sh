#!/usr/bin/env bash
# lib/logflare.sh - Supabase Analytics (Logflare).
#
# Follows the official self-hosting guide:
#   https://supabase.com/docs/reference/self-hosting-analytics/introduction
#
# Analytics is not part of the base Supabase stack. Upstream ships it as an
# optional compose overlay enabled with `run.sh config add logs`, which layers
# docker-compose.logs.yml on top of the base stack and adds two services:
# analytics (Logflare) and vector (log collection).
#
# That overlay is the only deployment path here. When upstream does not ship
# it, analytics is skipped - it is a log aggregator, not a dependency of the
# application, and rolling our own compose stack alongside Supabase's would
# only create something else to keep in sync.
#
# The Supabase-side variables this phase owns are documented in docs/LOGFLARE.md.
# shellcheck shell=bash

# Logflare's HTTP port inside the container. Upstream deliberately does not
# publish it to the host - access is meant to go through the API gateway.
LOGFLARE_PORT="4000"

# The upstream compose overlay that adds the analytics and vector services.
LOGFLARE_OVERLAY="docker-compose.logs.yml"

# Our own overlay, layered after upstream's, that points Logflare's log store
# at a remote Postgres or at BigQuery. Absent for the local backend.
LOGFLARE_BACKEND_OVERLAY="docker-compose.sentinel-analytics.yml"

# The schema Logflare keeps its log tables in. Upstream's overlay hardcodes
# it, for the Postgres backend and for Logflare's own metadata alike.
LOGFLARE_SCHEMA="_analytics"

# The BigQuery service-account key, in supabase/ where upstream's docs put it,
# and where Logflare reads it inside the container.
LOGFLARE_GCLOUD_KEY="gcloud.json"
LOGFLARE_GCLOUD_KEY_TARGET="/opt/app/rel/logflare/bin/gcloud.json"

# The daily timer that applies LOGFLARE_RETENTION_DAYS.
SO_LOGFLARE_RETENTION_UNIT="sentinel-ops-logflare-retention"

# Collected at the prompt, written to supabase/.env by
# logflare_configure_supabase(). Never persisted in installer.env. Empty
# means "keep whatever supabase/.env already has".
LOGFLARE_REMOTE_BACKEND_URL=""
GOOGLE_PROJECT_ID=""
GOOGLE_PROJECT_NUMBER=""
LOGFLARE_GCLOUD_KEY_SOURCE=""

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

logflare_prompt_config() {
    section "Analytics (Logflare)"

    if confirm "Enable Logflare analytics (log aggregation)?" y; then
        ENABLE_LOGFLARE="true"
    else
        ENABLE_LOGFLARE="false"
        return 0
    fi

    if ! logflare_prompt_backend "$(logflare_backend)"; then
        log_warn "Keeping the logs on this server; change it later with: sentinel-ops logflare backend"
        LOGFLARE_BACKEND="local"
    fi
    if [[ "$LOGFLARE_BACKEND" != "bigquery" ]]; then
        local days="${LOGFLARE_RETENTION_DAYS:-7}"
        while :; do
            prompt_default days "Delete collected logs older than how many days? (0 keeps them forever)" "$days"
            logflare_valid_retention "$days" && break
            log_warn "Enter a whole number of days, e.g. 7 (0 turns retention off)."
            [[ "$SO_ASSUME_YES" == "true" || ! -t 0 ]] && { days="7"; break; }
        done
        LOGFLARE_RETENTION_DAYS="$days"
    fi
    return 0
}

# The configured backend; a hand-edited value that is not one falls back to
# local rather than reaching Compose.
logflare_backend() {
    case "${LOGFLARE_BACKEND:-local}" in
        local|remote|bigquery) printf '%s' "${LOGFLARE_BACKEND:-local}" ;;
        *)
            log_warn "LOGFLARE_BACKEND='${LOGFLARE_BACKEND}' is not local, remote or bigquery; using local." >&2
            printf 'local'
            ;;
    esac
}

logflare_valid_retention() { [[ "$1" =~ ^(0|[1-9][0-9]{0,4})$ ]]; }

# Retention in days, 0 when off. Empty (an installation from before this
# setting existed) is off: nothing it collected is deleted until someone asks.
logflare_retention_days() {
    local days="${LOGFLARE_RETENTION_DAYS:-0}"
    if logflare_valid_retention "$days"; then
        printf '%s' "$days"
    else
        log_warn "LOGFLARE_RETENTION_DAYS='${LOGFLARE_RETENTION_DAYS}' is not a number of days; retention is off." >&2
        printf '0'
    fi
}

# A remote backend URL Compose and psql will both take as-is. `$` would be
# read as a Compose variable, quotes and whitespace would end the value.
logflare_valid_remote_url() {
    local url="$1"
    [[ "$url" =~ ^postgres(ql)?://[^[:space:]]+$ ]] || return 1
    [[ "$url" != *'$'* && "$url" != *'"'* && "$url" != *"'"* ]]
}

# A file that looks like a Google service-account key.
logflare_valid_gcloud_key() {
    local file="$1"
    [[ -f "$file" && -r "$file" ]] || return 1
    if have_cmd jq; then
        [[ "$(jq -r '.type // empty' "$file" 2>/dev/null)" == "service_account" ]]
    else
        grep -Eq '"type"[[:space:]]*:[[:space:]]*"service_account"' "$file"
    fi
}

# Compose's !reset tag, which the BigQuery overlay needs to take upstream's
# Postgres variables away, arrived in Docker Compose 2.24.0.
logflare_compose_supports_reset() {
    local ver major minor
    ver="$(docker compose version --short 2>/dev/null)" || return 1
    ver="${ver#v}"
    major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    (( major > 2 || (major == 2 && minor >= 24) ))
}

# Ask which backend to use and for that backend's details. Sets
# LOGFLARE_BACKEND and the transport variables above; writes nothing.
# logflare_prompt_backend [default]
logflare_prompt_backend() {
    local choice="${1:-local}" env_file="${SUPABASE_DIR}/.env" existing
    printf '\nWhere should Logflare store the logs it collects?\n'
    printf '  local     this server'"'"'s Postgres (the default)\n'
    printf '  remote    a Postgres on another host (a postgres:// URL)\n'
    printf '  bigquery  Google BigQuery, Supabase'"'"'s recommendation for production\n'
    while :; do
        prompt_default choice "Log storage (local, remote, bigquery)" "$choice"
        case "$choice" in local|remote|bigquery) break ;; esac
        log_warn "Choose local, remote or bigquery."
        [[ "$SO_ASSUME_YES" == "true" || ! -t 0 ]] && { choice="local"; break; }
    done

    case "$choice" in
        remote)
            existing="$(env_get "$env_file" LOGFLARE_REMOTE_BACKEND_URL 2>/dev/null || true)"
            prompt_secret LOGFLARE_REMOTE_BACKEND_URL \
                "Remote Postgres URL (postgresql://user:password@host:5432/dbname)" "$existing"
            if ! logflare_valid_remote_url "$LOGFLARE_REMOTE_BACKEND_URL"; then
                log_error "Not a usable postgres:// URL. Percent-encode \$, quotes and spaces in the password."
                LOGFLARE_REMOTE_BACKEND_URL=""
                return 1
            fi
            ;;
        bigquery)
            printf '\nNeeds a Google Cloud project with billing enabled and a service-account\n'
            printf 'JSON key. See docs/LOGFLARE.md.\n'
            prompt_default GOOGLE_PROJECT_ID "Google Cloud project ID" \
                "$(env_get "$env_file" GOOGLE_PROJECT_ID 2>/dev/null || true)"
            prompt_default GOOGLE_PROJECT_NUMBER "Google Cloud project number" \
                "$(env_get "$env_file" GOOGLE_PROJECT_NUMBER 2>/dev/null || true)"
            local have_key=""
            [[ -f "${SUPABASE_DIR}/${LOGFLARE_GCLOUD_KEY}" ]] && have_key="(keep the installed key)"
            prompt_default LOGFLARE_GCLOUD_KEY_SOURCE \
                "Path to the service-account JSON key${have_key:+ - blank keeps the installed one}" ""
            if [[ -z "$GOOGLE_PROJECT_ID" || ! "$GOOGLE_PROJECT_NUMBER" =~ ^[0-9]+$ ]]; then
                log_error "A project ID and a numeric project number are both required."
                return 1
            fi
            if [[ -n "$LOGFLARE_GCLOUD_KEY_SOURCE" ]]; then
                logflare_valid_gcloud_key "$LOGFLARE_GCLOUD_KEY_SOURCE" || {
                    log_error "${LOGFLARE_GCLOUD_KEY_SOURCE} is not a service-account JSON key."
                    LOGFLARE_GCLOUD_KEY_SOURCE=""
                    return 1
                }
            elif [[ -z "$have_key" ]]; then
                log_error "A service-account JSON key is required."
                return 1
            fi
            ;;
    esac
    LOGFLARE_BACKEND="$choice"
    return 0
}

# The overlay defines the analytics and vector services itself and only
# interpolates these variables out of supabase/.env, so we set the documented
# variables and never redefine the services' own connection settings.
logflare_configure_supabase() {
    local env_file="${SUPABASE_DIR}/.env" val key

    # Access tokens. Generated once and never rotated automatically - vector,
    # Logflare and Studio all authenticate with these same values.
    for key in LOGFLARE_PUBLIC_ACCESS_TOKEN LOGFLARE_PRIVATE_ACCESS_TOKEN; do
        val="$(env_get "$env_file" "$key" 2>/dev/null || true)"
        if [[ -z "$val" || "$val" == *your-super-secret* || "$val" == *change*me* ]]; then
            env_set "$env_file" "$key" "$(random_token 32)"
            log_debug "generated ${key}"
        fi
    done

    # Encryption key for sensitive Logflare database columns. Upstream requires
    # this to be base64 and warns it is mandatory for production use.
    val="$(env_get "$env_file" LOGFLARE_DB_ENCRYPTION_KEY 2>/dev/null || true)"
    if [[ -z "$val" ]]; then
        env_set "$env_file" LOGFLARE_DB_ENCRYPTION_KEY "$(openssl rand -base64 32 2>/dev/null || random_token 32)"
        log_debug "generated LOGFLARE_DB_ENCRYPTION_KEY"
    fi
    # Present but empty is correct until a key rotation is in progress.
    env_get "$env_file" LOGFLARE_DB_ENCRYPTION_KEY_RETIRED >/dev/null 2>&1 || \
        env_set "$env_file" LOGFLARE_DB_ENCRYPTION_KEY_RETIRED ""

    # Single-tenant Supabase mode: no account creation, and the Supabase log
    # sources Studio expects are seeded automatically.
    env_set "$env_file" LOGFLARE_SINGLE_TENANT "true"
    env_set "$env_file" LOGFLARE_SUPABASE_MODE "true"

    # vector mounts the Docker socket to collect container logs. The path
    # differs under rootless Docker and Podman's compatibility shim.
    local sock="/var/run/docker.sock"
    if [[ ! -S "$sock" ]]; then
        sock="$(env_get "$env_file" DOCKER_SOCKET_LOCATION 2>/dev/null || printf '/var/run/docker.sock')"
        log_warn "/var/run/docker.sock not found; using ${sock}. Logs will not flow if this is wrong."
    fi
    env_set "$env_file" DOCKER_SOCKET_LOCATION "$sock"

    # Postgres backend. Only set when the overlay has not already wired it up,
    # so we never fight the upstream compose file.
    val="$(env_get "$env_file" POSTGRES_BACKEND_SCHEMA 2>/dev/null || true)"
    [[ -n "$val" ]] || env_set "$env_file" POSTGRES_BACKEND_SCHEMA "$LOGFLARE_SCHEMA"

    # Where the logs go. Values entered in this run are written; otherwise
    # what supabase/.env already holds stays (a Supabase update never
    # re-prompts).
    [[ -n "$LOGFLARE_REMOTE_BACKEND_URL" ]] && \
        env_set "$env_file" LOGFLARE_REMOTE_BACKEND_URL "$LOGFLARE_REMOTE_BACKEND_URL"
    [[ -n "$GOOGLE_PROJECT_ID" ]]     && env_set "$env_file" GOOGLE_PROJECT_ID "$GOOGLE_PROJECT_ID"
    [[ -n "$GOOGLE_PROJECT_NUMBER" ]] && env_set "$env_file" GOOGLE_PROJECT_NUMBER "$GOOGLE_PROJECT_NUMBER"
    if [[ -n "$LOGFLARE_GCLOUD_KEY_SOURCE" ]]; then
        install -m 600 "$LOGFLARE_GCLOUD_KEY_SOURCE" "${SUPABASE_DIR}/${LOGFLARE_GCLOUD_KEY}" || {
            log_error "Could not copy ${LOGFLARE_GCLOUD_KEY_SOURCE} to ${SUPABASE_DIR}/${LOGFLARE_GCLOUD_KEY}."
            return 1
        }
    fi

    chmod 600 "$env_file" 2>/dev/null || true
    logflare_apply_backend || return 1
    log_ok "Supabase analytics variables configured"
    return 0
}

# ---------------------------------------------------------------------------
# Backend overlay
# ---------------------------------------------------------------------------

_logflare_backend_overlay_path() { printf '%s/%s' "$SUPABASE_DIR" "$LOGFLARE_BACKEND_OVERLAY"; }

# Print the overlay for a backend; nothing for local, which is upstream's
# own wiring. Values are interpolated by Compose from supabase/.env, so no
# secret is ever written into the overlay itself.
# logflare_render_backend_overlay <local|remote|bigquery>
# shellcheck disable=SC2016 # ${...} is for Compose to interpolate, not bash
logflare_render_backend_overlay() {
    local backend="$1"
    [[ "$backend" == "local" ]] && return 0
    printf '# Generated by sentinel-ops (lib/logflare.sh). Do not edit: it is rewritten\n'
    printf '# whenever the analytics configuration is applied. Change the backend\n'
    printf '# with: sentinel-ops logflare backend\n'
    printf 'services:\n'
    printf '  analytics:\n'
    printf '    environment:\n'
    case "$backend" in
        remote)
            printf '      POSTGRES_BACKEND_URL: ${LOGFLARE_REMOTE_BACKEND_URL}\n'
            ;;
        bigquery)
            # Logflare picks BigQuery only when POSTGRES_BACKEND_URL is absent -
            # an empty value still selects Postgres - so the upstream values
            # are removed, not blanked.
            printf '      POSTGRES_BACKEND_URL: !reset null\n'
            printf '      POSTGRES_BACKEND_SCHEMA: !reset null\n'
            printf '      GOOGLE_PROJECT_ID: ${GOOGLE_PROJECT_ID}\n'
            printf '      GOOGLE_PROJECT_NUMBER: ${GOOGLE_PROJECT_NUMBER}\n'
            printf '    volumes:\n'
            printf '      - ./%s:%s:ro,z\n' "$LOGFLARE_GCLOUD_KEY" "$LOGFLARE_GCLOUD_KEY_TARGET"
            ;;
    esac
}

# True when our overlay is listed after upstream's logs overlay - the order
# that lets it override what upstream sets.
_logflare_backend_overlay_after_logs() {
    local current entry seen_logs="false" entries=()
    current="$(env_get "${SUPABASE_DIR}/.env" COMPOSE_FILE 2>/dev/null || true)"
    IFS=':' read -r -a entries <<<"$current"
    for entry in "${entries[@]}"; do
        [[ "$entry" == "$LOGFLARE_OVERLAY" ]] && seen_logs="true"
        [[ "$entry" == "$LOGFLARE_BACKEND_OVERLAY" ]] && { [[ "$seen_logs" == "true" ]]; return; }
    done
    return 1
}

# Write (or remove) the backend overlay and its COMPOSE_FILE entry. It only
# adds to the analytics service, so it is listed only while upstream's logs
# overlay is: on its own it would define analytics without an image and
# Compose would refuse to start anything.
logflare_apply_backend() {
    local env_file="${SUPABASE_DIR}/.env" overlay backend tmp
    overlay="$(_logflare_backend_overlay_path)"
    backend="$(logflare_backend)"

    if [[ "$backend" == "local" ]]; then
        compose_file_register "$env_file" "$LOGFLARE_BACKEND_OVERLAY" false
        rm -f "$overlay"
        return 0
    fi

    if [[ "$backend" == "remote" ]] && \
        [[ -z "$(env_get "$env_file" LOGFLARE_REMOTE_BACKEND_URL 2>/dev/null || true)" ]]; then
        log_error "LOGFLARE_BACKEND=remote, but supabase/.env has no LOGFLARE_REMOTE_BACKEND_URL."
        log_error "Set it with: sentinel-ops logflare backend remote"
        return 1
    fi
    if [[ "$backend" == "bigquery" && ! -f "${SUPABASE_DIR}/${LOGFLARE_GCLOUD_KEY}" ]]; then
        log_error "LOGFLARE_BACKEND=bigquery, but ${SUPABASE_DIR}/${LOGFLARE_GCLOUD_KEY} is missing."
        log_error "Set it up with: sentinel-ops logflare backend bigquery"
        return 1
    fi

    tmp="$(mktemp)"
    logflare_render_backend_overlay "$backend" >"$tmp"
    cmp -s "$tmp" "$overlay" 2>/dev/null || cat "$tmp" >"$overlay"
    rm -f "$tmp"

    if ! logflare_overlay_registered; then
        compose_file_register "$env_file" "$LOGFLARE_BACKEND_OVERLAY" false
    elif ! _logflare_backend_overlay_after_logs; then
        compose_file_register "$env_file" "$LOGFLARE_BACKEND_OVERLAY" true
    fi
    return 0
}

# Take the backend overlay out of COMPOSE_FILE, keeping the file, for when
# upstream's logs overlay goes (logflare disable).
logflare_unregister_backend() {
    compose_file_register "${SUPABASE_DIR}/.env" "$LOGFLARE_BACKEND_OVERLAY" false
}

# ---------------------------------------------------------------------------
# The log store: size, purge, retention
#
# Logflare's Postgres backend keeps one table per source,
# <schema>.log_events_<source token>, with a `timestamp TIMESTAMP` column
# (UTC, BRIN-indexed). Its own metadata - sources, users, settings - lives in
# other tables of the local _analytics schema and is never touched here, so
# Logflare carries on as before after a purge.
# ---------------------------------------------------------------------------

# Run SQL from stdin against the backend that holds the log tables, through
# the database container's psql. A remote URL travels in the environment,
# not on a command line.
logflare_backend_psql() {
    local cid url
    cid="$(_db_container)" || return 1
    case "$(logflare_backend)" in
        local)
            docker exec -i -e PGPASSWORD="$(_db_pass)" "$cid" \
                psql -U "$DB_SUPERUSER" -d _supabase -v ON_ERROR_STOP=1 "$@"
            ;;
        remote)
            url="$(env_get "${SUPABASE_DIR}/.env" LOGFLARE_REMOTE_BACKEND_URL 2>/dev/null || true)"
            [[ -n "$url" ]] || { log_error "No LOGFLARE_REMOTE_BACKEND_URL in supabase/.env."; return 1; }
            SO_LOGFLARE_URL="$url" docker exec -i -e SO_LOGFLARE_URL -e PGCONNECT_TIMEOUT=15 "$cid" \
                sh -c 'exec psql "$SO_LOGFLARE_URL" -v ON_ERROR_STOP=1 "$@"' psql "$@"
            ;;
        *)
            log_error "The BigQuery backend is not a Postgres database."
            return 1
            ;;
    esac
}

# Check a remote URL before it is saved: it answers, and the schema Logflare
# writes to exists or can be created.
logflare_remote_check() {
    local url="$1" cid
    cid="$(_db_container)" || return 1
    SO_LOGFLARE_URL="$url" docker exec -i -e SO_LOGFLARE_URL -e PGCONNECT_TIMEOUT=15 "$cid" \
        sh -c 'exec psql "$SO_LOGFLARE_URL" -v ON_ERROR_STOP=1 -qtA' >>"${SO_LOG_FILE:-/dev/null}" 2>&1 <<SQL
SELECT 1;
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = '${LOGFLARE_SCHEMA}') THEN
    CREATE SCHEMA ${LOGFLARE_SCHEMA};
  END IF;
END \$\$;
SQL
}

_logflare_tables_sql() {
    printf "SELECT tablename FROM pg_tables WHERE schemaname = '%s' AND tablename LIKE 'log\\\\_events\\\\_%%' ORDER BY 1;\n" \
        "$LOGFLARE_SCHEMA"
}

# The log tables, one per line. Only names Logflare itself would produce are
# passed on, so they are safe to put into SQL.
logflare_log_tables() {
    local out t
    out="$(_logflare_tables_sql | logflare_backend_psql -qtA 2>>"${SO_LOG_FILE:-/dev/null}")" || return 1
    while IFS= read -r t; do
        [[ "$t" =~ ^log_events_[A-Za-z0-9_]+$ ]] && printf '%s\n' "$t"
    done <<<"$out"
    return 0
}

# Bytes taken by the log tables, indexes included.
logflare_storage_bytes() {
    local out
    out="$(printf "SELECT COALESCE(SUM(pg_total_relation_size(format('%%I.%%I', schemaname, tablename)::regclass)), 0) FROM pg_tables WHERE schemaname = '%s' AND tablename LIKE 'log\\\\_events\\\\_%%';\n" \
        "$LOGFLARE_SCHEMA" | logflare_backend_psql -qtA 2>>"${SO_LOG_FILE:-/dev/null}")" || return 1
    out="${out//[[:space:]]/}"
    [[ "$out" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$out"
}

# The SQL that purges the tables named on stdin: everything, or rows older
# than N days. A table with nothing newer than the cutoff is truncated rather
# than deleted row by row - the first run after turning retention on is
# usually exactly that, and TRUNCATE hands the space straight back.
# _logflare_purge_sql <all|days>
_logflare_purge_sql() {
    local mode="$1" t qt cutoff
    cutoff="(now() AT TIME ZONE 'UTC') - interval '${mode} days'"
    while IFS= read -r t; do
        [[ "$t" =~ ^log_events_[A-Za-z0-9_]+$ ]] || continue
        qt="${LOGFLARE_SCHEMA}.\"${t}\""
        if [[ "$mode" == "all" ]]; then
            printf 'TRUNCATE %s;\n' "$qt"
        else
            printf 'DO $$ BEGIN\n'
            printf '  IF EXISTS (SELECT 1 FROM %s WHERE "timestamp" >= %s) THEN\n' "$qt" "$cutoff"
            printf '    DELETE FROM %s WHERE "timestamp" < %s;\n' "$qt" "$cutoff"
            printf '  ELSE\n'
            printf '    TRUNCATE %s;\n' "$qt"
            printf '  END IF;\n'
            printf 'END $$;\n'
            # Plain VACUUM: no long lock, and the freed space is reused, so
            # the tables stop growing even though the files do not shrink.
            printf 'VACUUM %s;\n' "$qt"
        fi
    done
}

# logflare_purge <all|days>
logflare_purge() {
    local mode="$1" tables
    tables="$(logflare_log_tables)" || { log_error "Could not list the log tables."; return 1; }
    if [[ -z "$tables" ]]; then
        log_info "No log tables found; nothing to purge."
        return 0
    fi
    _logflare_purge_sql "$mode" <<<"$tables" | logflare_backend_psql -q >>"${SO_LOG_FILE:-/dev/null}" 2>&1
}

# ---------------------------------------------------------------------------
# Retention timer
# ---------------------------------------------------------------------------

# _logflare_retention_unit_text <service|timer>
# The service reads LOGFLARE_RETENTION_DAYS when it runs, so changing the
# number of days never needs the units rewritten.
_logflare_retention_unit_text() {
    case "$1" in
        service)
            cat <<EOF
[Unit]
Description=Sentinel Ops Logflare log retention
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${SO_BIN_LINK} --dir ${INSTALL_DIR} --yes logflare prune
EOF
            ;;
        timer)
            cat <<EOF
[Unit]
Description=Sentinel Ops Logflare log retention

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=900

[Install]
WantedBy=timers.target
EOF
            ;;
    esac
}

# True when the retention timer should exist: a number of days is set and
# the logs are in Postgres. BigQuery handles its own data lifecycle.
logflare_retention_wanted() {
    [[ "$(logflare_retention_days)" != "0" && "$(logflare_backend)" != "bigquery" ]]
}

# Install or remove the timer to match the configuration. Kept while
# Logflare is disabled, so what it collected before still ages out.
logflare_retention_sync() {
    local unit="/etc/systemd/system/${SO_LOGFLARE_RETENTION_UNIT}"
    if ! logflare_retention_wanted; then
        if have_cmd systemctl && [[ -f "${unit}.timer" ]]; then
            systemctl disable --now "${SO_LOGFLARE_RETENTION_UNIT}.timer" >/dev/null 2>&1 || true
            rm -f "${unit}.timer" "${unit}.service"
            systemctl daemon-reload >/dev/null 2>&1 || true
            log_ok "Log retention timer removed"
        fi
        return 0
    fi
    if ! have_cmd systemctl; then
        log_warn "systemctl not available; run 'sentinel-ops logflare prune' yourself (e.g. from cron)."
        return 1
    fi
    _logflare_retention_unit_text service >"${unit}.service"
    _logflare_retention_unit_text timer   >"${unit}.timer"
    systemctl daemon-reload >/dev/null 2>&1 || true
    service_enable_start "${SO_LOGFLARE_RETENTION_UNIT}.timer" || return 1
    log_ok "Logs older than $(logflare_retention_days) days are deleted daily"
    return 0
}

# True when upstream ships the mechanism to enable analytics.
logflare_overlay_available() {
    [[ -f "${SUPABASE_DIR}/run.sh" ]]
}

# True when the logs overlay is listed in COMPOSE_FILE, i.e. Compose will
# start analytics and vector.
logflare_overlay_registered() {
    local current
    current="$(env_get "${SUPABASE_DIR}/.env" COMPOSE_FILE 2>/dev/null || true)"
    [[ ":${current}:" == *":${LOGFLARE_OVERLAY}:"* ]]
}

# Take the logs overlay out of COMPOSE_FILE. upstream's run.sh is the
# mechanism that put it there, so it gets the first go; the overlay is then
# removed directly if it is still listed, so the result never depends on what
# a given upstream release's run.sh happens to do. Other overlays keep their
# place either way.
logflare_remove_overlay() {
    if logflare_overlay_available && logflare_overlay_registered; then
        run_logged "run.sh config remove logs" bash -c \
            "cd '$SUPABASE_DIR' && sh run.sh config remove logs" || \
            log_warn "run.sh could not remove the logs overlay; removing it directly."
    fi
    compose_file_register "${SUPABASE_DIR}/.env" "$LOGFLARE_OVERLAY" false
    # Ours only adds to upstream's analytics service; it cannot stay without it.
    logflare_unregister_backend
    ! logflare_overlay_registered
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

logflare_install() {
    if [[ "$ENABLE_LOGFLARE" != "true" ]]; then
        log_info "Logflare is disabled in the configuration; skipping."
        return 0
    fi

    if ! logflare_overlay_available; then
        log_warn "This Supabase release ships no run.sh, so the logs overlay cannot be enabled."
        log_warn "Analytics is skipped; the rest of the stack is unaffected."
        ENABLE_LOGFLARE="false"
        return 0
    fi

    logflare_configure_supabase || return 1

    if [[ "$(logflare_backend)" == "remote" ]]; then
        log_info "Checking the remote log database..."
        if ! logflare_remote_check "$(env_get "${SUPABASE_DIR}/.env" LOGFLARE_REMOTE_BACKEND_URL)"; then
            log_error "Could not reach the remote log database, or create the ${LOGFLARE_SCHEMA} schema in it."
            log_error "Fix the URL with: sentinel-ops logflare backend remote"
            return 1
        fi
    fi

    log_info "Enabling the logs overlay (run.sh config add logs)..."
    run_logged "run.sh config add logs" bash -c \
        "cd '$SUPABASE_DIR' && sh run.sh config add logs" || return 1
    # Now that upstream's overlay is listed, ours can go after it.
    logflare_apply_backend || return 1

    log_info "Starting the Supabase stack with analytics..."
    run_logged "run.sh start" bash -c "cd '$SUPABASE_DIR' && sh run.sh start" || return 1

    # Upstream warns that the Logflare dashboard has no authentication of its
    # own, so it must never be exposed publicly.
    log_warn "Logflare's /dashboard has no authentication - do not expose port ${LOGFLARE_PORT} publicly."
    return 0
}

# ---------------------------------------------------------------------------
# Health
#
# Port 4000 is not published to the host by default, so the probe runs inside
# the container. Each step falls back to the next.
# ---------------------------------------------------------------------------

logflare_check() {
    local cid
    cid="$(supabase_container_id analytics)"
    [[ -n "$cid" ]] || return 1

    # 1. In-container HTTP probe (the port is not exposed to the host).
    if docker exec "$cid" sh -c \
        'command -v curl >/dev/null && curl -fsS http://127.0.0.1:4000/health >/dev/null' 2>/dev/null; then
        return 0
    fi
    if docker exec "$cid" sh -c \
        'command -v wget >/dev/null && wget -qO- http://127.0.0.1:4000/health >/dev/null' 2>/dev/null; then
        return 0
    fi

    # 2. Docker's own healthcheck verdict.
    local health
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
    [[ "$health" == "healthy" ]]
}

logflare_running() {
    supabase_service_running analytics
}

logflare_health_check() {
    [[ "$ENABLE_LOGFLARE" == "true" ]] || return 0

    log_info "Waiting for Logflare..."
    # Logflare runs its database migrations on first boot, so the initial start
    # is slow; upstream's own healthcheck allows a 60s start period.
    if wait_for 180 5 logflare_check; then
        log_ok "Logflare available"
        return 0
    fi

    if logflare_running; then
        # Degraded log aggregation must not take the application offline.
        log_warn "Logflare is running but did not answer its health endpoint."
        log_warn "Check with: sentinel-ops logs logflare"
        return 0
    fi

    log_error "Logflare failed health check"
    log_error "Check with: sentinel-ops logs logflare"
    return 1
}
