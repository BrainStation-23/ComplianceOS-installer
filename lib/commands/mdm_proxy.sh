#!/usr/bin/env bash
# lib/commands/mdm_proxy.sh - sentinel-ops mdm-proxy (#18): a port of its own
# for Windows MDM behind a front proxy that can't request client certificates
# (Zoraxy). See lib/mdm_proxy.sh and docs/REVERSE-PROXY.md.
#
#   sentinel-ops mdm-proxy status
#   sentinel-ops mdm-proxy enable [--port N] [--cert FILE] [--key FILE]
#   sentinel-ops mdm-proxy disable
#   sentinel-ops mdm-proxy sync-cert      (the daily timer runs this)
# shellcheck shell=bash

_mdm_proxy_status() {
    section "Windows MDM proxy"
    if [[ "$MDM_PROXY_ENABLED" != "true" ]]; then
        status_line "MDM proxy" "" "Off - see: sentinel-ops mdm-proxy enable"
        return 0
    fi
    if container_running "$MDM_PROXY_CONTAINER"; then
        status_line "Container" "ok" "Running on ${MDM_PROXY_BIND}:${MDM_PROXY_PORT}"
    else
        status_line "Container" "bad" "Not running - try: sentinel-ops mdm-proxy enable"
    fi
    local days subject
    subject="$(openssl x509 -in "$(mdm_proxy_dir)/tls/cert.pem" -noout -subject 2>/dev/null | sed 's/^subject= *//')"
    if days="$(mdm_proxy_cert_days_left)"; then
        if (( days < 14 )); then
            status_line "Certificate" "warn" "${subject:-?}, expires in ${days} days - is ${MDM_PROXY_CERT_FILE} renewing?"
        else
            status_line "Certificate" "ok" "${subject:-?}, ${days} days left"
        fi
    else
        status_line "Certificate" "bad" "None copied - run: sentinel-ops mdm-proxy sync-cert"
    fi
    if mdm_proxy_probe_tls; then
        status_line "Client certificates" "ok" "Requested in the TLS handshake"
    else
        status_line "Client certificates" "bad" "Not requested on port ${MDM_PROXY_PORT}"
    fi
    local code
    code="$(mdm_proxy_probe_http)"
    case "$code" in
        401) status_line "Reaches the app" "ok" "401 without a certificate, as it should" ;;
        503) status_line "Reaches the app" "bad" "503: the app has no MDM_PROXY_SECRET - run: sentinel-ops update app" ;;
        *)   status_line "Reaches the app" "bad" "HTTP ${code:-no answer} from /ManagementServer/MDM.svc" ;;
    esac
    printf '\n  Set %sSettings -> MDM -> MDM port%s in the console to %s.\n' "$C_BOLD" "$C_RESET" "$MDM_PROXY_PORT"
    return 0
}

_mdm_proxy_enable() {
    require_root
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    section "Windows MDM proxy"
    printf 'Windows PCs check in with a client certificate. When the proxy on 443\n'
    printf "can't request one (Zoraxy), this proxy takes a port of its own for them;\n"
    printf 'discovery stays on 443. Use the certificate your front proxy issued for the\n'
    printf "MDM hostname (Zoraxy: <zoraxy>/conf/certs/<hostname>.pem and .key).\n\n"

    local port="${SO_OPT_PORT:-$MDM_PROXY_PORT}" cert="${SO_OPT_CERT:-$MDM_PROXY_CERT_FILE}" key="${SO_OPT_KEY:-$MDM_PROXY_KEY_FILE}"
    [[ -n "$SO_OPT_PORT" ]] || prompt_default port "Port for Windows MDM" "$port"
    [[ -n "$SO_OPT_CERT" ]] || prompt_default cert "Certificate (PEM, with its chain) for the MDM hostname" "$cert"
    [[ -n "$SO_OPT_KEY" ]] || prompt_default key "Its private key" "$key"

    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 && port != 8000 && port != APP_PORT )) \
        || die "Pick a port from 1024 to 65535 that nothing else here uses (not 443, 8000 or ${APP_PORT})."
    if [[ "$port" != "$MDM_PROXY_PORT" || "$MDM_PROXY_ENABLED" != "true" ]] && port_in_use "$port"; then
        die "Port ${port} is already in use on this host."
    fi
    local why
    why="$(mdm_proxy_check_pair "$cert" "$key")" || die "$why"

    local old_port="$MDM_PROXY_PORT" was="$MDM_PROXY_ENABLED"
    MDM_PROXY_ENABLED="true"
    MDM_PROXY_PORT="$port"
    MDM_PROXY_CERT_FILE="$cert"
    MDM_PROXY_KEY_FILE="$key"
    config_save

    mdm_proxy_sync_cert >/dev/null || die "Could not copy the certificate."
    mdm_proxy_start || die "The MDM proxy did not start."
    if [[ "$was" == "true" && "$old_port" != "$port" ]]; then
        firewall_close_port "$old_port" || true
    fi
    firewall_open_port "$port" || log_warn "Could not open ${port}/tcp automatically; open it yourself."
    mdm_proxy_install_timer || true
    log_ok "MDM proxy running on port ${port}"
    printf '\nNext: in the console, %sSettings -> MDM -> MDM port%s = %s, before PCs enroll.\n' "$C_BOLD" "$C_RESET" "$port"
    printf 'Open %s/tcp wherever else traffic to this host is filtered (cloud security group).\n' "$port"
    printf 'Check it with: sentinel-ops mdm-proxy status\n\n'
    return 0
}

_mdm_proxy_disable() {
    require_root
    mdm_proxy_stop
    mdm_proxy_remove_timer
    if [[ "$MDM_PROXY_ENABLED" == "true" ]]; then
        firewall_close_port "$MDM_PROXY_PORT" || true
    fi
    MDM_PROXY_ENABLED="false"
    config_save
    log_ok "MDM proxy stopped. Clear Settings -> MDM -> MDM port in the console too, or PCs that enroll can't check in."
    return 0
}

# Refresh the served certificate from its source; restart only when it changed
# (Caddy doesn't watch its certificate files).
_mdm_proxy_sync_cert() {
    [[ "$MDM_PROXY_ENABLED" == "true" ]] || { log_info "The MDM proxy is off."; return 0; }
    local result
    result="$(mdm_proxy_sync_cert)" || return 1
    if [[ "$result" == "changed" ]]; then
        mdm_proxy_start || return 1
        log_ok "MDM proxy certificate renewed"
    else
        log_info "MDM proxy certificate unchanged"
    fi
    return 0
}

cmd_mdm_proxy() {
    local sub="${1:-status}"
    case "$sub" in
        status)    _mdm_proxy_status ;;
        enable)    _mdm_proxy_enable ;;
        disable)   _mdm_proxy_disable ;;
        sync-cert) _mdm_proxy_sync_cert ;;
        *) log_error "Unknown: mdm-proxy ${sub} (status|enable|disable|sync-cert)"; return 2 ;;
    esac
}
