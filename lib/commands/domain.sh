#!/usr/bin/env bash
# lib/commands/domain.sh - point the stack at a real domain, no reinstall.
#
# A domain implies a reverse proxy terminating TLS in front of both upstreams
# (see the wiki page Go-Live-on-a-Domain), so this also flips APP_BIND back to loopback -
# per Design-Decisions #7 the installer never runs that proxy itself. Moving
# to a domain is therefore always a config change plus a restart: no rebuild,
# no data loss, and it undoes exactly what `network enable` (or a fresh
# install's LAN default) turned on.
# shellcheck shell=bash

_domain_status() {
    section "Domain"
    if [[ "$SITE_URL" == https://* ]]; then
        status_line "Mode" "ok" "Domain (${SITE_URL})"
        status_line "Reverse proxy upstreams" "" "127.0.0.1:${APP_PORT} (frontend), 127.0.0.1:$(supabase_kong_port 2>/dev/null || printf 8000) (Supabase)"
        # Through the proxy, since that is what browsers upload through.
        section "Uploads"
        storage_status
        storage_proxy_status
    elif [[ "$APP_BIND" == "0.0.0.0" ]]; then
        status_line "Mode" "warn" "No domain configured - LAN access enabled instead"
    else
        status_line "Mode" "ok" "No domain configured - loopback only"
    fi
    return 0
}

# Accept a bare hostname or a full URL and return a bare hostname.
_domain_normalize_host() {
    printf '%s' "$(url_host "$1")"
}

# Pure config transform: no Docker, no restart. Sets the three URLs to
# https://<host>, flips APP_BIND back to loopback, and persists both to
# installer.env and supabase/.env (the latter is what GoTrue and Kong
# actually read - see Design-Decisions #7/#8).
_domain_apply_settings() {
    local host="$1"
    if [[ -z "$host" ]]; then
        log_error "Not a usable hostname."
        return 1
    fi

    SUPABASE_PUBLIC_URL="https://${host}"
    API_EXTERNAL_URL="https://${host}"
    SITE_URL="https://${host}"
    APP_BIND="127.0.0.1"

    config_save
    supabase_apply_config
}

# domain set <hostname>
_domain_set() {
    local raw="${1:-}" host
    if [[ -z "$raw" ]]; then
        log_error "Usage: sentinel-ops domain set <hostname>"
        return 2
    fi
    host="$(_domain_normalize_host "$raw")"
    [[ -n "$host" ]] || die "Not a usable hostname: ${raw}"

    log_info "Pointing Sentinel Ops at https://${host}"
    log_warn "This installer does not run a reverse proxy for you - see https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Go-Live-on-a-Domain"
    log_warn "Make sure ${host} resolves here and something on this host terminates TLS on 443 first."

    if [[ "$SO_ASSUME_YES" != "true" ]]; then
        confirm "Continue?" y || { log_info "Cancelled."; return 0; }
    fi

    _domain_apply_settings "$host" || die "Could not update the domain configuration."

    firewall_close_port_private "$APP_PORT"
    supabase_installed && firewall_close_port_private "$(supabase_kong_port)"

    if supabase_installed; then
        log_info "Restarting Kong and Auth so they pick up the new URLs..."
        if run_logged "restart gateway/auth" bash -c \
                "$(_supabase_compose_cmd) up -d --force-recreate $(supabase_gateway_service) auth"; then
            wait_for 60 5 supabase_check_auth && log_ok "Auth healthy" \
                || log_warn "Auth did not answer its health check; check: sentinel-ops logs supabase"
        else
            log_warn "Could not restart Kong/Auth automatically; restart Supabase manually: sentinel-ops update supabase"
        fi
    fi

    if container_exists "$APP_CONTAINER_NAME"; then
        log_info "Restarting the frontend bound to loopback..."
        frontend_run_container "$APP_CONTAINER_NAME" "$(frontend_deployed_image)" "$APP_PORT" \
            && wait_for 60 3 frontend_check_http "$APP_PORT"
    fi

    printf '\n'
    log_ok "Domain configured: https://${host}"
    status_line "Application" "" "$SITE_URL"
    status_line "Supabase" "" "$SUPABASE_PUBLIC_URL"
    printf '\nPoint your reverse proxy at 127.0.0.1:%s (frontend) and 127.0.0.1:%s (Supabase API).\n' \
        "$APP_PORT" "$(supabase_kong_port 2>/dev/null || printf 8000)"
    printf 'Worked Zoraxy/nginx/Caddy/Traefik configs: https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Reverse-Proxy\n'
    printf 'Once the proxy is up, check that uploads get through it with:\n'
    printf '  sentinel-ops domain status\n\n'
    return 0
}

cmd_domain() {
    require_root domain
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
    supabase_installed || die "Supabase is not installed at ${SUPABASE_DIR}."

    banner "Domain"
    printf '\n'

    case "${1:-status}" in
        status) _domain_status ;;
        set)    _domain_set "${2:-}" ;;
        *)
            log_error "Unknown domain subcommand: $1"
            printf 'Valid: status, set <hostname>\n'
            return 2
            ;;
    esac
}
