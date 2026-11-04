#!/usr/bin/env bash
# lib/mdm_proxy.sh - the Windows MDM proxy (#18, #25, sentinel-ops#611, #638).
#
# After enrollment, a Windows PC authenticates every MDM check-in with its
# device certificate at the TLS layer, so whatever terminates TLS for
# check-ins has to request the certificate and forward it to the app. A PC
# that isn't enrolled has no certificate, and Windows fails enrollment
# (0x80192F0C) wherever it's asked for one; TLS is set up before the path is
# known, so check-ins need a port of their own. This Caddy container is that
# port and answers MDM.svc only; discovery, sign-in, enrollment and renewal
# (proved by its signed PKCS#7) stay on 443 behind the front proxy, which
# must not ask for certificates. The console's Settings -> MDM -> MDM port
# must name the same port.
#
# It reaches the frontend by container name on the Supabase network, and
# forwards the certificate with the proxy secret lib/frontend.sh generates.
# It can't answer an HTTP challenge (the front proxy owns 80 and 443), so its
# certificate comes from one of two sources (MDM_PROXY_CERT_SOURCE):
#   files       a copy of one issued elsewhere, typically by Zoraxy
#   cloudflare  Let's Encrypt through a Cloudflare DNS challenge, run here by
#               a certbot container: nothing to install or copy, and it works
#               when the front proxy is on another machine
# Either way a daily timer refreshes it.
# shellcheck shell=bash

MDM_PROXY_CONTAINER="sentinel-ops-mdm-proxy"
SO_MDM_CERT_UNIT="sentinel-ops-mdm-cert"

mdm_proxy_dir() { printf '%s' "${CONFIG_DIR}/mdm-proxy"; }

# --- Let's Encrypt through Cloudflare DNS ------------------------------------------
# certbot keeps its account, certificates and renewal settings under
# letsencrypt/; the API token is in cloudflare.ini (0600), mounted read-only
# into the certbot container only, never passed on a command line.

mdm_proxy_acme_dir() { printf '%s' "$(mdm_proxy_dir)/letsencrypt"; }
mdm_proxy_cloudflare_ini() { printf '%s' "$(mdm_proxy_dir)/cloudflare.ini"; }

# The certificate and key certbot keeps current for a hostname. live/ holds
# relative symlinks into archive/, so they resolve on the host as well.
mdm_proxy_acme_cert_file() { printf '%s/live/%s/fullchain.pem' "$(mdm_proxy_acme_dir)" "$1"; }
mdm_proxy_acme_key_file() { printf '%s/live/%s/privkey.pem' "$(mdm_proxy_acme_dir)" "$1"; }

mdm_proxy_valid_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# The stored token, or nothing.
mdm_proxy_cloudflare_token() {
    sed -n 's/^dns_cloudflare_api_token *= *//p' "$(mdm_proxy_cloudflare_ini)" 2>/dev/null | head -n 1
}

mdm_proxy_cloudflare_save_token() {
    local ini
    ini="$(mdm_proxy_cloudflare_ini)"
    mkdir -p "$(mdm_proxy_dir)"
    ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$1" >"$ini" )
    chmod 600 "$ini"
}

# mdm_proxy_certbot <certbot arguments...>: one run of the pinned certbot
# image with the Cloudflare plugin.
mdm_proxy_certbot() {
    # docker would bind-mount a missing file as a new, empty directory
    [[ -f "$(mdm_proxy_cloudflare_ini)" ]] || { log_error "No Cloudflare token: run sentinel-ops mdm-proxy enable --cloudflare"; return 1; }
    mkdir -p "$(mdm_proxy_acme_dir)"
    chmod 700 "$(mdm_proxy_acme_dir)"
    run_logged "certbot $1" docker run --rm \
        -v "$(mdm_proxy_acme_dir):/etc/letsencrypt" \
        -v "$(mdm_proxy_cloudflare_ini):/cloudflare.ini:ro" \
        "$MDM_PROXY_CERTBOT_IMAGE" "$@"
}

# Issues the certificate for MDM_PROXY_DOMAIN, or keeps the current one while
# it has more than 30 days left (so enabling again doesn't spend Let's
# Encrypt's rate limit).
mdm_proxy_acme_issue() {
    local contact=(--register-unsafely-without-email)
    [[ -n "$MDM_PROXY_ACME_EMAIL" ]] && contact=(--email "$MDM_PROXY_ACME_EMAIL")
    mdm_proxy_certbot certonly --non-interactive --agree-tos "${contact[@]}" \
        --dns-cloudflare \
        --dns-cloudflare-credentials /cloudflare.ini \
        --dns-cloudflare-propagation-seconds 30 \
        --cert-name "$MDM_PROXY_DOMAIN" -d "$MDM_PROXY_DOMAIN" \
        --keep-until-expiring
}

# Renews it when it is within 30 days of expiring; otherwise does nothing.
# The renewal settings certbot saved at issue time name /cloudflare.ini,
# which is where mdm_proxy_certbot mounts the token every time.
mdm_proxy_acme_renew() {
    mdm_proxy_certbot renew --non-interactive --cert-name "$MDM_PROXY_DOMAIN"
}

# The paths the app serves on the MDM port: check-ins only. Everything else
# is a 404 here (sentinel-ops#638: the enrollment endpoints moved to 443).
MDM_PROXY_PATHS="/ManagementServer/MDM.svc"

# The Caddyfile, printed. Pure: the secret stays in the container's
# environment ({$MDM_PROXY_SECRET}), never in the file.
mdm_proxy_caddyfile() {
    local cert_header="${MDM_CLIENT_CERT_HEADER:-X-Client-Cert}"
    local secret_header="${MDM_PROXY_SECRET_HEADER:-X-MDM-Proxy-Secret}"
    cat <<EOF
# Generated by sentinel-ops (lib/mdm_proxy.sh); changes are overwritten.
{
	admin off
	auto_https off
}

:8443 {
	tls /tls/cert.pem /tls/key.pem {
		client_auth {
			mode request
		}
	}
	@mdm path ${MDM_PROXY_PATHS}
	handle @mdm {
		reverse_proxy ${APP_CONTAINER_NAME}:${APP_PORT} {
			header_up ${cert_header} {http.request.tls.client.certificate_der_base64}
			header_up ${secret_header} {\$MDM_PROXY_SECRET}
		}
	}
	handle {
		respond 404
	}
}
EOF
}

# mdm_proxy_check_pair <cert> <key>: a readable certificate that hasn't
# expired, and the key that belongs to it. Prints why not, and fails.
mdm_proxy_check_pair() {
    local cert="$1" key="$2" a b
    [[ -r "$cert" ]] || { printf 'cannot read the certificate %s' "$cert"; return 1; }
    [[ -r "$key" ]] || { printf 'cannot read the key %s' "$key"; return 1; }
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || { printf '%s is not a PEM certificate' "$cert"; return 1; }
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || { printf 'the certificate %s has expired' "$cert"; return 1; }
    a="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null)"
    b="$(openssl pkey -in "$key" -pubout 2>/dev/null)"
    [[ -n "$a" && "$a" == "$b" ]] || { printf 'the key %s does not belong to the certificate %s' "$key" "$cert"; return 1; }
    return 0
}

# Days until the served certificate expires, or nothing when there is none.
mdm_proxy_cert_days_left() {
    local cert end now
    cert="$(mdm_proxy_dir)/tls/cert.pem"
    [[ -r "$cert" ]] || return 1
    end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
    [[ -n "$end" ]] || return 1
    end="$(date -d "$end" +%s 2>/dev/null)" || return 1
    now="$(date +%s)"
    printf '%s' "$(( (end - now) / 86400 ))"
}

# Copies MDM_PROXY_CERT_FILE / MDM_PROXY_KEY_FILE into the proxy's own
# directory. Prints "changed" when the copy is new, "same" when it was
# already current; fails when the source is unusable.
mdm_proxy_sync_cert() {
    local dir why
    dir="$(mdm_proxy_dir)/tls"
    if ! why="$(mdm_proxy_check_pair "$MDM_PROXY_CERT_FILE" "$MDM_PROXY_KEY_FILE")"; then
        log_error "MDM proxy certificate: ${why}"
        return 1
    fi
    mkdir -p "$dir"
    chmod 700 "$dir"
    if [[ -f "${dir}/cert.pem" && -f "${dir}/key.pem" ]] \
        && [[ "$(file_sha256 "$MDM_PROXY_CERT_FILE")" == "$(file_sha256 "${dir}/cert.pem")" ]] \
        && [[ "$(file_sha256 "$MDM_PROXY_KEY_FILE")" == "$(file_sha256 "${dir}/key.pem")" ]]; then
        printf 'same'
        return 0
    fi
    install -m 644 "$MDM_PROXY_CERT_FILE" "${dir}/cert.pem"
    install -m 600 "$MDM_PROXY_KEY_FILE" "${dir}/key.pem"
    printf 'changed'
}

# (Re)starts the proxy container from the current config.
mdm_proxy_start() {
    local dir network
    dir="$(mdm_proxy_dir)"
    network="$(supabase_network_name)"
    if ! docker network inspect "$network" >/dev/null 2>&1; then
        log_error "Supabase network '${network}' not found; the MDM proxy reaches the frontend through it."
        return 1
    fi
    mkdir -p "$dir"
    mdm_proxy_caddyfile >"${dir}/Caddyfile"
    chmod 644 "${dir}/Caddyfile"

    docker rm -f "$MDM_PROXY_CONTAINER" >/dev/null 2>&1 || true
    local log_args=()
    mapfile -t log_args < <(container_log_run_args)
    local args=(
        run -d
        --name "$MDM_PROXY_CONTAINER"
        --restart unless-stopped
        --network "$network"
        # by name, like the frontend's keys: run_logged writes the argv to the log
        -e MDM_PROXY_SECRET
        -v "${dir}/Caddyfile:/etc/caddy/Caddyfile:ro"
        -v "${dir}/tls:/tls:ro"
        -p "${MDM_PROXY_BIND}:${MDM_PROXY_PORT}:8443"
        "${log_args[@]}"
        "$MDM_PROXY_IMAGE"
    )
    local rc=0 secret
    secret="$(frontend_mdm_proxy_secret)"
    export MDM_PROXY_SECRET="$secret"
    run_logged "start ${MDM_PROXY_CONTAINER}" docker "${args[@]}" || rc=$?
    unset MDM_PROXY_SECRET
    return "$rc"
}

mdm_proxy_stop() {
    docker rm -f "$MDM_PROXY_CONTAINER" >/dev/null 2>&1 || true
}

# _mdm_proxy_unit_text <service|timer>: the daily certificate refresh.
mdm_proxy_unit_text() {
    case "$1" in
        service)
            cat <<EOF
[Unit]
Description=Sentinel Ops MDM proxy certificate refresh
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${SO_BIN_LINK} --dir ${INSTALL_DIR} mdm-proxy sync-cert
EOF
            ;;
        timer)
            cat <<EOF
[Unit]
Description=Sentinel Ops MDM proxy certificate refresh, daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
            ;;
    esac
}

mdm_proxy_install_timer() {
    have_cmd systemctl || { log_warn "systemctl not available; refresh the MDM proxy's certificate with: sentinel-ops mdm-proxy sync-cert"; return 0; }
    mdm_proxy_unit_text service >"/etc/systemd/system/${SO_MDM_CERT_UNIT}.service"
    mdm_proxy_unit_text timer   >"/etc/systemd/system/${SO_MDM_CERT_UNIT}.timer"
    run_logged "systemctl daemon-reload" systemctl daemon-reload || true
    service_enable_start "${SO_MDM_CERT_UNIT}.timer"
}

mdm_proxy_remove_timer() {
    have_cmd systemctl || return 0
    [[ -f "/etc/systemd/system/${SO_MDM_CERT_UNIT}.timer" ]] || return 0
    systemctl disable --now "${SO_MDM_CERT_UNIT}.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SO_MDM_CERT_UNIT}.timer" "/etc/systemd/system/${SO_MDM_CERT_UNIT}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# The hostname the served certificate is for (its first DNS name, else its
# CN). Caddy matches the request's Host to the TLS server name when client
# certificates are on, so a check has to ask for it by name, as a PC does.
mdm_proxy_cert_host() {
    local cert host
    cert="$(mdm_proxy_dir)/tls/cert.pem"
    host="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
        | grep -o 'DNS:[^,]*' | head -n 1 | cut -d: -f2)"
    [[ -n "$host" ]] || host="$(openssl x509 -in "$cert" -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *commonName *= *//p' | head -n 1)"
    printf '%s' "${host:-localhost}"
}

# What the app answers on the MDM port without a client certificate: 401
# means the request reached it with the proxy secret; 503, that the secret
# isn't arriving; nothing, that the proxy isn't serving.
mdm_proxy_probe_http() {
    local host
    host="$(mdm_proxy_cert_host)"
    curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
        --resolve "${host}:${MDM_PROXY_PORT}:127.0.0.1" \
        -H 'Content-Type: application/vnd.syncml.dm+xml' --data '<SyncML/>' \
        "https://${host}:${MDM_PROXY_PORT}/ManagementServer/MDM.svc" 2>/dev/null || true
}

# Whether the proxy asks the client for a certificate during the handshake.
mdm_proxy_probe_tls() {
    openssl s_client -connect "127.0.0.1:${MDM_PROXY_PORT}" -servername "$(mdm_proxy_cert_host)" \
        </dev/null 2>&1 \
        | grep -qiE 'Requested Signature Algorithms|Acceptable client certificate|Client Certificate Types'
}
