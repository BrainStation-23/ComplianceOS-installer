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

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

logflare_prompt_config() {
    section "Analytics (Logflare)"

    if confirm "Enable Logflare analytics (log aggregation)?" y; then
        ENABLE_LOGFLARE="true"
    else
        ENABLE_LOGFLARE="false"
    fi
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
    [[ -n "$val" ]] || env_set "$env_file" POSTGRES_BACKEND_SCHEMA "_analytics"

    chmod 600 "$env_file" 2>/dev/null || true
    log_ok "Supabase analytics variables configured"
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

    log_info "Enabling the logs overlay (run.sh config add logs)..."
    run_logged "run.sh config add logs" bash -c \
        "cd '$SUPABASE_DIR' && sh run.sh config add logs" || return 1

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
