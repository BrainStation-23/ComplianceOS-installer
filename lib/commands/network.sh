#!/usr/bin/env bash
# lib/commands/network.sh - expose (or restrict) the stack on the network.
#
# By default the frontend binds to 127.0.0.1 (APP_BIND) and is reachable only
# through whatever reverse proxy the operator puts in front of it. Supabase's
# own compose file is different: its gateway publishes to every interface
# unconditionally (upstream's own choice, not this installer's), so the host
# firewall is the only thing standing between it and the internet - see the
# README's "Firewall" section.
#
# A fresh install defaults to LAN exposure: SUPABASE_PUBLIC_URL, API_EXTERNAL_URL
# and SITE_URL are seeded from this host's own LAN IP address (see
# detect_lan_ip() in lib/common.sh), and the firewall rule that opens the
# ports is scoped to RFC1918 ranges (see FIREWALL_PRIVATE_RANGES in
# lib/firewall.sh) rather than to the world. That is enough for an operator on
# the same network to reach the install with zero manual configuration, without
# also handing it to the public internet. There is still no TLS on either
# port - moving to a real domain is `sentinel-ops domain set <hostname>`,
# which puts a proxy in front instead (see the wiki page Go-Live-on-a-Domain).
# shellcheck shell=bash

network_prompt_config() {
    section "Public Network Access"
    printf 'By default the frontend and Supabase API are reachable from other devices on\n'
    printf 'this network, using this host'"'"'s own LAN address. Supabase'"'"'s own gateway\n'
    printf 'always binds every interface (upstream'"'"'s choice); the firewall rule opened\n'
    printf 'below is scoped to private/LAN address ranges, not the public internet.\n\n'
    printf 'There is no TLS on either port this way. For a real domain instead, install\n'
    printf 'normally and run: sentinel-ops domain set <hostname>\n\n'
    printf 'Toggle this later with: sentinel-ops network\n\n'

    if confirm "Expose the frontend and Supabase API on the LAN now?" y; then
        APP_BIND="0.0.0.0"
    else
        APP_BIND="127.0.0.1"
    fi
}

# Open the ports implied by the current configuration, scoped to private/LAN
# address ranges. Called from a fresh install (after Supabase's .env exists, so
# the Kong/gateway port is known) and from `network enable`.
network_apply_firewall() {
    [[ "$APP_BIND" == "0.0.0.0" ]] || { log_debug "Public access not requested; firewall left untouched."; return 0; }
    firewall_open_port_private "$APP_PORT" || log_warn "Could not open ${APP_PORT}/tcp automatically."
    if supabase_installed; then
        firewall_open_port_private "$(supabase_kong_port)" || log_warn "Could not open $(supabase_kong_port)/tcp automatically."
    fi
    return 0
}

_network_status() {
    section "Network Exposure"
    if [[ "$SITE_URL" == https://* ]]; then
        status_line "Mode" "ok" "Domain configured (${SITE_URL}) - see: sentinel-ops domain status"
    elif [[ "$APP_BIND" == "0.0.0.0" ]]; then
        status_line "Mode" "warn" "LAN access enabled, no TLS"
    else
        status_line "Mode" "ok" "Loopback only"
    fi

    if [[ "$APP_BIND" == "0.0.0.0" ]]; then
        status_line "Frontend" "warn" "LAN-reachable (0.0.0.0:${APP_PORT})"
    else
        status_line "Frontend" "ok" "Loopback only (${APP_BIND:-127.0.0.1}:${APP_PORT})"
    fi
    if supabase_installed; then
        status_line "Supabase gateway" "warn" "Always public upstream (0.0.0.0:$(supabase_kong_port)) - the firewall is what protects it"
    fi
    firewall_detect >/dev/null
    if firewall_active; then
        status_line "Firewall" "ok" "${FIREWALL_BACKEND} active"
    else
        status_line "Firewall" "bad" "${FIREWALL_BACKEND} $([[ "$FIREWALL_BACKEND" == "none" ]] && printf 'not found' || printf 'installed, inactive')"
    fi
    return 0
}

# Push the in-memory SUPABASE_PUBLIC_URL/API_EXTERNAL_URL/SITE_URL/APP_BIND
# into both installer.env and supabase/.env, and restart the containers that
# actually validate against them. Without this, GoTrue (auth) keeps checking
# redirects against whatever SITE_URL it was started with, no matter what
# `network enable`/`disable` just changed.
_network_persist_and_restart() {
    config_save
    supabase_apply_config || log_warn "Could not update ${SUPABASE_DIR}/.env with the new URLs."

    if supabase_installed; then
        log_info "Restarting Kong and Auth so they pick up the current URLs..."
        if run_logged "restart gateway/auth" bash -c \
                "$(_supabase_compose_cmd) up -d --force-recreate $(supabase_gateway_service) auth"; then
            wait_for 60 5 supabase_check_auth && log_ok "Auth healthy" \
                || log_warn "Auth did not answer its health check; check: sentinel-ops logs supabase"
        else
            log_warn "Could not restart Kong/Auth automatically; try: sentinel-ops update supabase"
        fi
    fi
}

_network_enable() {
    log_warn "This exposes the frontend and Supabase API to this host's LAN, with no TLS."
    log_warn "Anything that can reach this host on these ports can reach the application and the database API."

    # confirm() takes the default under --yes, and "n" is the safe default
    # here - so --yes would never approve this otherwise. Mirror nuke's own
    # confirmation, which honours --yes explicitly for exactly this reason.
    if [[ "$SO_ASSUME_YES" == "true" ]]; then
        log_warn "--yes given; proceeding without confirmation."
    else
        confirm "Continue?" n || { log_info "Cancelled."; return 0; }
    fi

    APP_BIND="0.0.0.0"

    # Only replace URLs that still point at loopback. An operator who has
    # already pointed these at a real domain (sentinel-ops domain set) does
    # not want a bind-address toggle to clobber them back to a bare IP.
    if [[ "$SUPABASE_PUBLIC_URL" == http://localhost:* || "$SUPABASE_PUBLIC_URL" == http://127.0.0.1:* ]]; then
        local lan_ip kong_port
        lan_ip="$(lan_ip_or_localhost)"
        kong_port="$(supabase_kong_port)"
        SUPABASE_PUBLIC_URL="http://${lan_ip}:${kong_port}"
        [[ "$API_EXTERNAL_URL" == http://localhost:* || "$API_EXTERNAL_URL" == http://127.0.0.1:* ]] && \
            API_EXTERNAL_URL="$SUPABASE_PUBLIC_URL"
        [[ "$SITE_URL" == http://localhost:* || "$SITE_URL" == http://127.0.0.1:* ]] && \
            SITE_URL="http://${lan_ip}:${APP_PORT}"
    fi

    _network_persist_and_restart
    network_apply_firewall

    if container_exists "$APP_CONTAINER_NAME"; then
        log_info "Restarting the frontend bound to 0.0.0.0..."
        if frontend_run_container "$APP_CONTAINER_NAME" "$(frontend_deployed_image)" "$APP_PORT" \
            && wait_for 60 3 frontend_check_http "$APP_PORT"; then
            log_ok "Frontend reachable on 0.0.0.0:${APP_PORT}"
        else
            log_error "Frontend restart failed; check: sentinel-ops logs app"
            return 1
        fi
    fi
    printf '\n'
    log_ok "LAN access enabled."
    status_line "Application" "" "$SITE_URL"
    status_line "Supabase" "" "$SUPABASE_PUBLIC_URL"
    log_warn "The firewall rule (where a firewall is active) only admits private/LAN address ranges."
    log_warn "Make sure nothing beyond ports 22/${APP_PORT}/$(supabase_kong_port 2>/dev/null || printf 8000) is open on this host's edge."
    return 0
}

_network_disable() {
    APP_BIND="127.0.0.1"
    _network_persist_and_restart

    if container_exists "$APP_CONTAINER_NAME"; then
        log_info "Restarting the frontend bound to loopback..."
        frontend_run_container "$APP_CONTAINER_NAME" "$(frontend_deployed_image)" "$APP_PORT" \
            && wait_for 60 3 frontend_check_http "$APP_PORT"
    fi
    firewall_close_port_private "$APP_PORT"

    log_ok "Frontend restricted back to 127.0.0.1."
    log_warn "Supabase's gateway (port $(supabase_kong_port 2>/dev/null || printf 8000)) still binds every interface -"
    log_warn "that is upstream's own compose file, not something this installer controls."
    log_warn "Close it at the firewall by hand if you no longer want it reachable."
    return 0
}

cmd_network() {
    require_root network
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
    detect_os >/dev/null 2>&1 || true

    banner "Network Exposure"
    printf '\n'

    case "${1:-status}" in
        status)  _network_status ;;
        enable)  _network_enable ;;
        disable) _network_disable ;;
        *)
            log_error "Unknown network subcommand: $1"
            printf 'Valid: status, enable, disable\n'
            return 2
            ;;
    esac
}
