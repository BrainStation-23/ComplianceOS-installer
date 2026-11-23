#!/usr/bin/env bash
# lib/hardening.sh - optional Supabase Auth (gotrue) hardening.
#
# Five independent, opt-in settings, all off by default so an install that
# skips the prompts behaves exactly as before:
#
#   signup           GOTRUE_DISABLE_SIGNUP - accounts are created by admins only
#   password-policy  minimum length plus lower/upper/digit/symbol classes
#   hibp             reject passwords found in known breaches (Pwned Passwords)
#   captcha          Cloudflare Turnstile on password sign-in
#   rate-limit       key gotrue's per-IP rate limits on a header the reverse
#                    proxy sets - without one, self-hosted gotrue applies no
#                    per-IP limit at all (performRateLimitingWithHeader returns
#                    early when GOTRUE_RATE_LIMIT_HEADER is empty)
#
# Upstream's docker-compose.yml already wires GOTRUE_DISABLE_SIGNUP to
# ${DISABLE_SIGNUP}, so "signup" is a plain .env setting. None of the others
# appear in upstream's compose file at all, so setting them in .env alone does
# nothing. They are delivered through a generated Compose overlay instead,
# registered in COMPOSE_FILE the same way upstream's own optional overlays are
# (Design-Decisions #28). The overlay is regenerated on every apply, so it
# never drifts, and `update supabase` leaves it alone because upstream does
# not ship a file by that name.
#
# The Turnstile secret is the one credential here. Like the Azure AD client
# secret it is entered by the operator, written only to supabase/.env
# (chmod 600) and interpolated into the overlay by reference - it never
# appears in the overlay, in installer.env or in the log.
# shellcheck shell=bash

HARDENING_OVERLAY="docker-compose.sentinel-auth.yml"
HARDENING_FEATURES=(signup password-policy hibp captcha rate-limit)

# A dedicated header rather than X-Forwarded-For or X-Real-IP: Envoy appends to
# X-Forwarded-For (so its first entry is whatever the client sent) and Kong
# overwrites X-Real-IP with the proxy's own address (so every user would share
# one bucket). A header only the edge proxy sets passes through both gateways
# untouched. See the wiki page Auth-Hardening.
HARDENING_DEFAULT_RATE_LIMIT_HEADER="X-Sentinel-Client-IP"

# The same character classes as hosted Supabase's
# "lower_upper_letters_digits_symbols" option. Sets are ":"-separated; the
# colon inside the symbol set is escaped as "\:" (gotrue's
# PasswordRequiredCharacters.Decode joins it back).
HARDENING_PASSWORD_CHARACTERS='abcdefghijklmnopqrstuvwxyz:ABCDEFGHIJKLMNOPQRSTUVWXYZ:0123456789:!@#$%^&*()_+-=[]{};'"'"'\:"|<>?,./`~'

# Non-secret config, persisted in installer.env.
AUTH_DISABLE_SIGNUP="false"
AUTH_PASSWORD_POLICY="false"
AUTH_PASSWORD_MIN_LENGTH="12"
AUTH_HIBP_ENABLED="false"
AUTH_HIBP_FAIL_CLOSED="false"
AUTH_CAPTCHA_ENABLED="false"
TURNSTILE_SITE_KEY=""
AUTH_RATE_LIMIT_HEADER=""
AUTH_RATE_LIMIT_TOKEN=""

# Set only for the duration of a single interactive prompt+apply in the same
# run; never persisted to installer.env and never logged.
TURNSTILE_SECRET_KEY=""

_hardening_overlay_path() { printf '%s/%s' "$SUPABASE_DIR" "$HARDENING_OVERLAY"; }

# "signup|password-policy|..." for usage messages.
_hardening_feature_list() {
    local IFS='|'
    printf '%s' "${HARDENING_FEATURES[*]}"
}

hardening_feature_known() {
    local f
    for f in "${HARDENING_FEATURES[@]}"; do
        [[ "$f" == "$1" ]] && return 0
    done
    return 1
}

# True when any setting that needs the overlay is on.
hardening_any_overlay_feature() {
    [[ "$AUTH_PASSWORD_POLICY" == "true" || "$AUTH_HIBP_ENABLED" == "true" \
        || "$AUTH_CAPTCHA_ENABLED" == "true" || -n "$AUTH_RATE_LIMIT_HEADER" ]]
}

hardening_feature_enabled() {
    case "$1" in
        signup)          [[ "$AUTH_DISABLE_SIGNUP" == "true" ]] ;;
        password-policy) [[ "$AUTH_PASSWORD_POLICY" == "true" ]] ;;
        hibp)            [[ "$AUTH_HIBP_ENABLED" == "true" ]] ;;
        captcha)         [[ "$AUTH_CAPTCHA_ENABLED" == "true" ]] ;;
        rate-limit)      [[ -n "$AUTH_RATE_LIMIT_HEADER" ]] ;;
        *)               return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Pwned Passwords health check
#
# Enabling the breached-password check on a host that cannot reach the API
# silently does nothing (fail-open) or blocks every password change
# (fail-closed), so it is only enabled after a real round trip succeeds.
#
# The probe asks for the range of SHA-1("password") - the most breached
# password there is - and requires its suffix in the answer. A bare HTTP 200
# is not enough: a captive portal or an intercepting proxy returns one too.
# ---------------------------------------------------------------------------

HIBP_API_URL="https://api.pwnedpasswords.com/range/"
_HIBP_PROBE_PREFIX="5BAA6"
_HIBP_PROBE_SUFFIX="1E4C9B93F3F0682250B6CF8331B7EE68FD8"
# Where the last hardening_hibp_check ran: "auth container" or "this host".
HIBP_CHECK_FROM=""

# The body is captured before it is searched: piping straight into grep -q
# would let grep exit at the first match, SIGPIPE the downloader, and - under
# the CLI's pipefail - turn a success into a failure.
_hibp_response_ok() {
    local body="$1"
    grep -qi "^${_HIBP_PROBE_SUFFIX}:" <<<"${body//$'\r'/}"
}

_hibp_probe_host() {
    local body
    body="$(curl -fsS --max-time 10 -A "sentinel-ops-installer" \
        "${HIBP_API_URL}${_HIBP_PROBE_PREFIX}" 2>/dev/null)" || return 1
    _hibp_response_ok "$body"
}

# gotrue is what makes the real request, so its container's egress is what
# matters (a host proxy or a Docker network policy can differ from the host's
# own). Its image ships wget for its healthcheck.
_hibp_probe_container() {
    local body
    body="$(docker exec "$1" wget -qO- -T 10 -U "sentinel-ops-installer" \
        "${HIBP_API_URL}${_HIBP_PROBE_PREFIX}" 2>/dev/null)" || return 1
    _hibp_response_ok "$body"
}

# The running auth container's id, when it can run a probe (has wget);
# nothing otherwise - before Supabase is up, or outside an installation.
_hardening_auth_cid() {
    local cid=""
    if declare -F supabase_container_id >/dev/null && supabase_installed 2>/dev/null; then
        cid="$(supabase_container_id auth 2>/dev/null || true)"
    fi
    if [[ -n "$cid" ]] && docker exec "$cid" sh -c 'command -v wget' >/dev/null 2>&1; then
        printf '%s' "$cid"
    fi
}

# 0 when the API answered correctly from the auth container (when it is
# running) or this host (before Supabase is up). Sets HIBP_CHECK_FROM.
hardening_hibp_check() {
    local cid
    cid="$(_hardening_auth_cid)"
    if [[ -n "$cid" ]]; then
        HIBP_CHECK_FROM="auth container"
        _hibp_probe_container "$cid"
        return
    fi
    HIBP_CHECK_FROM="this host"
    _hibp_probe_host
}

# ---------------------------------------------------------------------------
# Turnstile health check
#
# gotrue verifies every CAPTCHA token server-side, by posting it with the
# secret to Cloudflare's siteverify endpoint. If the auth container cannot
# reach that endpoint, or the secret is wrong, every password sign-in fails -
# so CAPTCHA is only enabled after a real siteverify round trip.
#
# A dummy token with a valid secret is answered with "invalid-input-response"
# (token rejected, secret accepted); a bad secret with "invalid-input-secret".
# Cloudflare's published test secrets answer with result_with_testing_key.
# ---------------------------------------------------------------------------

TURNSTILE_VERIFY_URL="https://challenges.cloudflare.com/turnstile/v0/siteverify"
_TURNSTILE_PROBE_TOKEN="sentinel-ops-healthcheck"
# Where the last hardening_turnstile_check ran, and what it found.
TURNSTILE_CHECK_FROM=""
TURNSTILE_CHECK_RESULT=""

# Classify a siteverify response body:
#   ok | bad-secret | test-key | unreachable
_turnstile_classify() {
    local body="$1"
    if [[ "$body" == *'"result_with_testing_key":true'* ]]; then
        printf 'test-key'
    elif [[ "$body" == *'"invalid-input-secret"'* ]]; then
        printf 'bad-secret'
    elif [[ "$body" == *'"invalid-input-response"'* ]]; then
        printf 'ok'
    else
        printf 'unreachable'
    fi
}

# The secret never goes on a command line (visible in ps): curl reads it from
# stdin, and docker exec takes it from the environment by name.
_turnstile_probe_host() {
    local secret="$1"
    printf '%s' "$secret" | curl -sS --max-time 10 -X POST \
        --data-urlencode "secret@-" -d "response=${_TURNSTILE_PROBE_TOKEN}" \
        "$TURNSTILE_VERIFY_URL" 2>/dev/null || true
}

_turnstile_probe_container() {
    local cid="$1" secret="$2"
    # Turnstile secrets are URL-safe (0x + [A-Za-z0-9_-]), so no encoding is
    # needed for busybox wget's --post-data.
    SO_TS_SECRET="$secret" docker exec -e SO_TS_SECRET "$cid" sh -c \
        "wget -qO- -T 10 --post-data \"secret=\${SO_TS_SECRET}&response=${_TURNSTILE_PROBE_TOKEN}\" '${TURNSTILE_VERIFY_URL}'" \
        2>/dev/null || true
}

# 0 only for a real, valid secret reachable from where gotrue runs. Sets
# TURNSTILE_CHECK_FROM and TURNSTILE_CHECK_RESULT (see _turnstile_classify).
# Note: siteverify answers HTTP 200 even for errors, so wget/curl succeed on
# every real answer and only the body decides.
hardening_turnstile_check() {
    local secret="$1" cid body
    cid="$(_hardening_auth_cid)"
    if [[ -n "$cid" ]]; then
        TURNSTILE_CHECK_FROM="auth container"
        body="$(_turnstile_probe_container "$cid" "$secret")"
    else
        TURNSTILE_CHECK_FROM="this host"
        body="$(_turnstile_probe_host "$secret")"
    fi
    TURNSTILE_CHECK_RESULT="$(_turnstile_classify "$body")"
    [[ "$TURNSTILE_CHECK_RESULT" == "ok" ]]
}

# Does the application checkout read the Turnstile site key yet? Enabling
# CAPTCHA before the login form sends a token locks every password user out.
# 0 = yes, 1 = no, 2 = cannot tell (no checkout yet).
_hardening_app_supports_captcha() {
    [[ -n "${APP_DIR:-}" && -d "${APP_DIR}/src" ]] || return 2
    grep -rqs 'TURNSTILE_SITE_KEY' "${APP_DIR}/src"
}

# ---------------------------------------------------------------------------
# Per-feature enable/disable. Enabling may prompt for the details a feature
# needs; it returns non-zero (leaving the feature off) if those are missing.
# ---------------------------------------------------------------------------

hardening_enable_feature() {
    case "$1" in
        signup)
            if [[ "${ENABLE_AZURE_AD:-false}" == "true" ]]; then
                log_warn "Azure AD sign-in is enabled. With sign-up disabled, gotrue may refuse a"
                log_warn "first-time SSO user who has no account yet - provision them first"
                log_warn "(sync-employees) and test one SSO login after enabling this."
            fi
            AUTH_DISABLE_SIGNUP="true"
            ;;
        password-policy)
            prompt_default AUTH_PASSWORD_MIN_LENGTH "Minimum password length" "${AUTH_PASSWORD_MIN_LENGTH:-12}"
            if ! [[ "$AUTH_PASSWORD_MIN_LENGTH" =~ ^[0-9]+$ ]] || (( AUTH_PASSWORD_MIN_LENGTH < 6 )); then
                log_warn "Minimum length must be a number of at least 6; using 12."
                AUTH_PASSWORD_MIN_LENGTH="12"
            fi
            AUTH_PASSWORD_POLICY="true"
            log_info "Only applies when a password is set; existing passwords keep working until changed."
            ;;
        hibp)
            log_info "Each new password's hash prefix is checked against api.pwnedpasswords.com."
            log_info "Checking that the API is reachable..."
            if ! hardening_hibp_check; then
                log_error "api.pwnedpasswords.com did not answer correctly from ${HIBP_CHECK_FROM}."
                log_error "Breached-password checking was NOT enabled. Allow outbound HTTPS to"
                log_error "api.pwnedpasswords.com (and any proxy in between), then retry with:"
                log_error "  sudo sentinel-ops auth enable hibp"
                AUTH_HIBP_ENABLED="false"
                return 1
            fi
            log_ok "Pwned Passwords API reachable from ${HIBP_CHECK_FROM}"
            if confirm "Reject the password when that API cannot be reached (fail closed)?" n; then
                AUTH_HIBP_FAIL_CLOSED="true"
            else
                AUTH_HIBP_FAIL_CLOSED="false"
            fi
            AUTH_HIBP_ENABLED="true"
            ;;
        captcha)
            local supported=0
            _hardening_app_supports_captcha || supported=$?
            if (( supported != 0 )); then
                if (( supported == 1 )); then
                    log_warn "The application checkout does not read TURNSTILE_SITE_KEY yet."
                else
                    log_warn "Cannot tell whether the application supports Turnstile (not checked out yet)."
                fi
                log_warn "If the login form does not send a CAPTCHA token, every password sign-in"
                log_warn "will be rejected once this is on."
                confirm "Enable CAPTCHA anyway?" n || return 1
            fi
            printf '\nCreate a Turnstile widget at https://dash.cloudflare.com/?to=/:account/turnstile\n'
            printf 'for the application hostname. Browsers need to reach challenges.cloudflare.com.\n\n'
            prompt_default TURNSTILE_SITE_KEY "Turnstile site key" "$TURNSTILE_SITE_KEY"
            local existing=""
            [[ -f "${SUPABASE_DIR}/.env" ]] && existing="$(env_get "${SUPABASE_DIR}/.env" TURNSTILE_SECRET_KEY 2>/dev/null || true)"
            prompt_secret TURNSTILE_SECRET_KEY "Turnstile secret key" "$existing"
            if [[ -z "$TURNSTILE_SITE_KEY" || -z "$TURNSTILE_SECRET_KEY" ]]; then
                log_warn "Site key or secret left blank; CAPTCHA will not be enabled."
                return 1
            fi
            log_info "Verifying the secret with Cloudflare..."
            if ! hardening_turnstile_check "$TURNSTILE_SECRET_KEY"; then
                case "$TURNSTILE_CHECK_RESULT" in
                    bad-secret)
                        log_error "Cloudflare rejected the Turnstile secret key - check it was copied in full." ;;
                    test-key)
                        log_error "That is one of Cloudflare's published test secrets, which provide no protection." ;;
                    *)
                        log_error "challenges.cloudflare.com did not answer from ${TURNSTILE_CHECK_FROM}."
                        log_error "gotrue verifies every sign-in there, so allow outbound HTTPS to it first." ;;
                esac
                log_error "CAPTCHA was NOT enabled. Retry with: sudo sentinel-ops auth enable captcha"
                TURNSTILE_SECRET_KEY=""
                return 1
            fi
            log_ok "Turnstile secret verified from ${TURNSTILE_CHECK_FROM}"
            AUTH_CAPTCHA_ENABLED="true"
            ;;
        rate-limit)
            if [[ "${SITE_URL:-}" != https://* ]]; then
                log_warn "No domain is configured. This only works behind a reverse proxy that sets the"
                log_warn "header below on every request; without it gotrue still applies no per-IP limit."
            fi
            log_info "The reverse proxy must OVERWRITE this header with the client address, e.g. nginx:"
            log_info "  proxy_set_header ${HARDENING_DEFAULT_RATE_LIMIT_HEADER} \$remote_addr;"
            log_info "and the Supabase API port must not be reachable except through that proxy."
            prompt_default AUTH_RATE_LIMIT_HEADER "Client-IP header set by the reverse proxy" \
                "${AUTH_RATE_LIMIT_HEADER:-$HARDENING_DEFAULT_RATE_LIMIT_HEADER}"
            if ! [[ "$AUTH_RATE_LIMIT_HEADER" =~ ^[A-Za-z0-9-]+$ ]]; then
                log_warn "Not a valid header name: ${AUTH_RATE_LIMIT_HEADER}"
                AUTH_RATE_LIMIT_HEADER=""
                return 1
            fi
            ;;
        *)
            log_error "Unknown feature: $1 (valid: ${HARDENING_FEATURES[*]})"
            return 2
            ;;
    esac
    return 0
}

hardening_disable_feature() {
    case "$1" in
        signup)          AUTH_DISABLE_SIGNUP="false" ;;
        password-policy) AUTH_PASSWORD_POLICY="false" ;;
        hibp)            AUTH_HIBP_ENABLED="false"; AUTH_HIBP_FAIL_CLOSED="false" ;;
        captcha)         AUTH_CAPTCHA_ENABLED="false" ;;
        rate-limit)      AUTH_RATE_LIMIT_HEADER="" ;;
        *)
            log_error "Unknown feature: $1 (valid: ${HARDENING_FEATURES[*]})"
            return 2
            ;;
    esac
    return 0
}

hardening_prompt_config() {
    section "Auth hardening (all optional)"

    if confirm "Disable public sign-up (accounts are created by admins only)?" n; then
        hardening_enable_feature signup
    else
        AUTH_DISABLE_SIGNUP="false"
    fi
    if confirm "Enforce a strong password policy (length + upper/lower/digit/symbol)?" n; then
        hardening_enable_feature password-policy
    else
        AUTH_PASSWORD_POLICY="false"
    fi
    if confirm "Reject passwords found in known data breaches (needs outbound HTTPS)?" n; then
        hardening_enable_feature hibp || AUTH_HIBP_ENABLED="false"
    else
        AUTH_HIBP_ENABLED="false"
    fi
    if confirm "Require a CAPTCHA (Cloudflare Turnstile) on password sign-in?" n; then
        hardening_enable_feature captcha || AUTH_CAPTCHA_ENABLED="false"
    else
        AUTH_CAPTCHA_ENABLED="false"
    fi
    if confirm "Rate-limit sign-in per client IP (needs a reverse proxy)?" n; then
        hardening_enable_feature rate-limit || AUTH_RATE_LIMIT_HEADER=""
    else
        AUTH_RATE_LIMIT_HEADER=""
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

# Quote a literal for a YAML single-quoted scalar that Compose will not
# interpolate: ' doubles, and $ becomes $$ (Compose interpolates inside quoted
# YAML strings too).
_hardening_yaml_literal() {
    local v="$1"
    v="${v//\'/\'\'}"
    v="${v//\$/\$\$}"
    printf "'%s'" "$v"
}

# Print the overlay for the current settings.
hardening_render_overlay() {
    printf '# Generated by sentinel-ops (lib/hardening.sh). Do not edit: it is rewritten\n'
    printf '# on every install, `update supabase` and `sentinel-ops auth` run.\n'
    printf '# See https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Auth-Hardening\n'
    printf 'services:\n'
    printf '  auth:\n'
    printf '    environment:\n'
    if [[ "$AUTH_PASSWORD_POLICY" == "true" ]]; then
        printf '      GOTRUE_PASSWORD_MIN_LENGTH: %s\n' "$(_hardening_yaml_literal "$AUTH_PASSWORD_MIN_LENGTH")"
        printf '      GOTRUE_PASSWORD_REQUIRED_CHARACTERS: %s\n' "$(_hardening_yaml_literal "$HARDENING_PASSWORD_CHARACTERS")"
    fi
    if [[ "$AUTH_HIBP_ENABLED" == "true" ]]; then
        printf "      GOTRUE_PASSWORD_HIBP_ENABLED: 'true'\n"
        printf '      GOTRUE_PASSWORD_HIBP_FAIL_CLOSED: %s\n' "$(_hardening_yaml_literal "$AUTH_HIBP_FAIL_CLOSED")"
    fi
    if [[ "$AUTH_CAPTCHA_ENABLED" == "true" ]]; then
        printf "      GOTRUE_SECURITY_CAPTCHA_ENABLED: 'true'\n"
        printf "      GOTRUE_SECURITY_CAPTCHA_PROVIDER: 'turnstile'\n"
        # By reference: the secret stays in supabase/.env. ':?' makes Compose
        # refuse to start with a clear message instead of gotrue crash-looping
        # on "captcha provider secret is empty".
        # Double-quoted so the message's punctuation cannot break the YAML.
        printf '      GOTRUE_SECURITY_CAPTCHA_SECRET: "${TURNSTILE_SECRET_KEY:?TURNSTILE_SECRET_KEY is missing from supabase/.env - add it or run sentinel-ops auth disable captcha}"\n'
    fi
    if [[ -n "$AUTH_RATE_LIMIT_HEADER" ]]; then
        printf '      GOTRUE_RATE_LIMIT_HEADER: %s\n' "$(_hardening_yaml_literal "$AUTH_RATE_LIMIT_HEADER")"
        if [[ "$AUTH_RATE_LIMIT_TOKEN" =~ ^[0-9]+$ ]]; then
            printf '      GOTRUE_RATE_LIMIT_TOKEN_REFRESH: %s\n' "$(_hardening_yaml_literal "$AUTH_RATE_LIMIT_TOKEN")"
        fi
    fi
}

# Add or remove the overlay from COMPOSE_FILE in supabase/.env, keeping every
# other entry (the logs overlay, a pg17 overlay) and their order.
_hardening_compose_file_set() {
    compose_file_register "${SUPABASE_DIR}/.env" "$HARDENING_OVERLAY" "$1"
}

# Everything hardening_write_overlay can change, as one string - lets a caller
# tell whether a re-apply actually changed anything (and so needs a restart).
_hardening_fingerprint() {
    printf '%s|%s|%s' \
        "$(env_get "${SUPABASE_DIR}/.env" DISABLE_SIGNUP 2>/dev/null || true)" \
        "$(env_get "${SUPABASE_DIR}/.env" COMPOSE_FILE 2>/dev/null || true)" \
        "$(cat "$(_hardening_overlay_path)" 2>/dev/null || true)"
}

# Write (or remove) the overlay and register (or unregister) it.
hardening_write_overlay() {
    local env_file="${SUPABASE_DIR}/.env" overlay
    [[ -f "$env_file" ]] || { log_error "Missing ${env_file}"; return 1; }
    overlay="$(_hardening_overlay_path)"

    if hardening_any_overlay_feature; then
        local tmp
        tmp="$(mktemp)"
        hardening_render_overlay >"$tmp"
        if ! cmp -s "$tmp" "$overlay" 2>/dev/null; then
            cat "$tmp" >"$overlay"
        fi
        rm -f "$tmp"
        _hardening_compose_file_set true
    else
        _hardening_compose_file_set false
        rm -f "$overlay"
    fi
    return 0
}

# Write the .env side and the overlay. Safe to call on every install/update:
# when no fresh secret was entered in this run, the one already in .env is
# kept, exactly like the Azure AD client secret.
hardening_apply_config() {
    local env_file="${SUPABASE_DIR}/.env"
    [[ -f "$env_file" ]] || { log_error "Missing ${env_file}"; return 1; }

    # Only ever turned on here. Turning it off is an explicit
    # `sentinel-ops auth disable signup`, so an operator who set
    # DISABLE_SIGNUP=true by hand before this feature existed keeps it.
    if [[ "$AUTH_DISABLE_SIGNUP" == "true" ]]; then
        env_set "$env_file" DISABLE_SIGNUP "true"
    fi
    if [[ -n "$TURNSTILE_SECRET_KEY" ]]; then
        env_set "$env_file" TURNSTILE_SECRET_KEY "$TURNSTILE_SECRET_KEY"
    fi

    if [[ "$AUTH_CAPTCHA_ENABLED" == "true" && -z "$(env_get "$env_file" TURNSTILE_SECRET_KEY 2>/dev/null || true)" ]]; then
        log_warn "CAPTCHA is enabled but supabase/.env has no TURNSTILE_SECRET_KEY; disabling it."
        AUTH_CAPTCHA_ENABLED="false"
    fi

    hardening_write_overlay || return 1
    chmod 600 "$env_file" 2>/dev/null || true
    log_ok "Auth hardening configuration applied"
    return 0
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

hardening_status() {
    local f label detail
    for f in "${HARDENING_FEATURES[@]}"; do
        case "$f" in
            signup)          label="Public sign-up";    detail="disabled (admin-created accounts only)" ;;
            password-policy) label="Password policy";   detail="min ${AUTH_PASSWORD_MIN_LENGTH}, upper/lower/digit/symbol" ;;
            hibp)            label="Breached passwords"; detail="rejected (fail-$([[ "$AUTH_HIBP_FAIL_CLOSED" == "true" ]] && printf closed || printf open))" ;;
            captcha)         label="CAPTCHA";           detail="Turnstile" ;;
            rate-limit)      label="Per-IP rate limit"; detail="keyed on ${AUTH_RATE_LIMIT_HEADER}" ;;
        esac
        if [[ "$f" == "hibp" ]] && hardening_feature_enabled hibp && ! hardening_hibp_check; then
            # Enabled earlier, unreachable now: fail-open means passwords go
            # unchecked, fail-closed means nobody can set one.
            status_line "$label" "warn" "API unreachable from ${HIBP_CHECK_FROM} - $([[ "$AUTH_HIBP_FAIL_CLOSED" == "true" ]] && printf 'password changes are being refused' || printf 'passwords are NOT being checked')"
        elif [[ "$f" == "captcha" ]] && hardening_feature_enabled captcha \
                && ! hardening_turnstile_check "$(env_get "${SUPABASE_DIR}/.env" TURNSTILE_SECRET_KEY 2>/dev/null || true)"; then
            # Enabled earlier, failing now: every password sign-in is refused.
            status_line "$label" "warn" "verification failing (${TURNSTILE_CHECK_RESULT} from ${TURNSTILE_CHECK_FROM}) - password sign-in is being refused"
        elif hardening_feature_enabled "$f"; then
            status_line "$label" "ok" "$detail"
        else
            status_line "$label" "" "off"
        fi
    done
    return 0
}
