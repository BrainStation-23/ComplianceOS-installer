#!/usr/bin/env bash
# lib/frontend.sh - application environment, Docker image and container.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Non-empty (a human-readable reason) when this port cannot be used for the
# frontend; empty when it is safe to use.
_frontend_port_conflict() {
    local port="$1" reserved
    for reserved in $(supabase_reserved_ports); do
        if [[ "$port" == "$reserved" ]]; then
            printf 'is reserved by Supabase - its own compose file always publishes it'
            return 0
        fi
    done
    if port_in_use "$port"; then
        printf 'is already in use on this host'
        return 0
    fi
    return 1
}

# Interactive prompt for the frontend's published port. Validated against
# every port Supabase's own compose file always publishes (its gateway and
# pooler, upstream's choice, not something this installer can move) and
# against whatever else is already listening, so a collision is caught here
# instead of surfacing later as a raw "port is already allocated" from Docker.
frontend_prompt_config() {
    section "Frontend Port"

    local conflict
    while true; do
        prompt_default APP_PORT "Frontend port" "$APP_PORT"

        conflict="$(_frontend_port_conflict "$APP_PORT")" || break
        log_warn "Port ${APP_PORT} ${conflict}."
        if [[ "$SO_ASSUME_YES" == "true" || ! -t 0 ]]; then
            die "Port ${APP_PORT} cannot be used and this run cannot prompt for another. Set APP_PORT to a free port in ${CONFIG_FILE} and re-run."
        fi
    done
}

# ---------------------------------------------------------------------------
# Application environment
# ---------------------------------------------------------------------------

# Generate app/.env.local from the live Supabase configuration.
#
# Keys the installer owns are always refreshed (they are derived values, and a
# stale Supabase URL is a broken deployment). Any other key an operator added
# is preserved.
#
# .env.local rather than .env: the application repository *tracks* .env, so
# writing there leaves the checkout permanently dirty and the next
# `git merge --ff-only` in `update app` aborts with "the local checkout has
# diverged". Vite reads .env.local with higher precedence than .env, and the
# repository's .gitignore already covers *.local, so this overrides the
# committed values without touching version control.
app_env_generate() {
    local env_file="${APP_DIR}/.env.local"
    local pub_key project_id

    if ! pub_key="$(supabase_publishable_key)"; then
        log_error "Could not read the Supabase publishable (anon) key from ${SUPABASE_DIR}/.env"
        return 1
    fi
    project_id="local"

    [[ -f "$env_file" ]] || : >"$env_file"

    # NOTE: the service-role key is deliberately absent. Anything in a Vite
    # build is shipped to the browser, so a service-role key here would hand
    # every visitor full database access.
    env_set "$env_file" PORT                          "$APP_PORT"
    env_set "$env_file" NODE_ENV                      "production"
    env_set "$env_file" SUPABASE_PROJECT_ID           "\"${project_id}\""
    env_set "$env_file" SUPABASE_PUBLISHABLE_KEY      "\"${pub_key}\""
    env_set "$env_file" SUPABASE_URL                  "\"${SUPABASE_PUBLIC_URL}\""
    env_set "$env_file" VITE_SUPABASE_PROJECT_ID      "\"${project_id}\""
    env_set "$env_file" VITE_SUPABASE_PUBLISHABLE_KEY "\"${pub_key}\""
    env_set "$env_file" VITE_SUPABASE_URL             "\"${SUPABASE_PUBLIC_URL}\""

    chmod 640 "$env_file" 2>/dev/null || true
    log_ok "Application environment written to ${env_file}"

    # An earlier installer version wrote the tracked .env directly. Say so once,
    # rather than letting `update app` fail later with a confusing merge error.
    if repo_is_cloned && [[ -n "$(app_git status --porcelain -- .env 2>/dev/null)" ]]; then
        log_warn "The checkout has local modifications to the tracked .env file."
        log_warn "This installer no longer writes it. Discard them with:"
        log_warn "  git -C ${APP_DIR} checkout -- .env"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Build assets
# ---------------------------------------------------------------------------

# The Dockerfile belongs in the application repository. Until it is committed
# there, the installer supplies one so deployment is not blocked.
frontend_provision_build_files() {
    local src="${SO_ASSETS_DIR}/app"

    if [[ -f "${APP_DIR}/Dockerfile" ]]; then
        log_ok "Using the Dockerfile from the application repository"
    else
        cp "${src}/Dockerfile" "${APP_DIR}/Dockerfile" || return 1
        log_info "Repository has no Dockerfile; using the installer's production template."
    fi

    [[ -f "${APP_DIR}/.dockerignore" ]] || cp "${src}/dockerignore" "${APP_DIR}/.dockerignore"
    return 0
}

frontend_image_tag()  { printf '%s:%s' "$APP_IMAGE_NAME" "$(repo_short_commit)"; }
frontend_image_latest() { printf '%s:latest' "$APP_IMAGE_NAME"; }

# Every build carries this label, so cleanup can find this installer's own
# untagged builds without touching anyone else's (lib/images.sh). It is set on
# the command line rather than in the Dockerfile, because the repository's own
# Dockerfile takes precedence over the installer's.
APP_IMAGE_LABEL="org.sentinel-ops.component=frontend"

# Hosts a build has to reach: the Dockerfile's `# syntax=` line and its base
# images are pulled from Docker Hub on every build.
FRONTEND_REGISTRY_HOSTS="registry-1.docker.io auth.docker.io"

_frontend_registry_resolves() {
    local host
    for host in $FRONTEND_REGISTRY_HOSTS; do
        getent hosts "$host" >/dev/null 2>&1 || return 1
    done
}

# Fail fast, with a plain explanation, when this host cannot resolve Docker
# Hub. Otherwise the same problem surfaces as a BuildKit trace about anonymous
# tokens. Skipped when Docker is configured with a proxy (the proxy resolves
# names, not this host) or when getent is unavailable.
frontend_registry_preflight() {
    have_cmd getent || return 0
    if [[ -n "$(docker info --format '{{.HTTPProxy}}{{.HTTPSProxy}}' 2>/dev/null)" ]]; then
        return 0
    fi
    _frontend_registry_resolves && return 0

    log_warn "Cannot resolve Docker Hub yet; waiting up to 30s for DNS..."
    wait_for 30 5 _frontend_registry_resolves && return 0

    log_error "DNS lookup failed for Docker Hub (${FRONTEND_REGISTRY_HOSTS// /, })."
    log_error "The build needs it to pull its base images. Check this host's resolver:"
    log_error "  resolvectl query auth.docker.io"
    log_error "  resolvectl status"
    log_error "If the upstream DNS server is unreliable, set FallbackDNS= in"
    log_error "/etc/systemd/resolved.conf and run: systemctl restart systemd-resolved"
    return 1
}

# Build the production image, tagged with the Git SHA so a previous image is
# always available to roll back to.
#
# A build that fails on a DNS or network error is retried: those are usually
# brief, and a failed auto-update holds its commit until the branch moves on.
# Any other failure is a real build error and is not retried.
frontend_build_image() {
    local tag latest attempt=1 attempts=3
    local delay="${SO_BUILD_RETRY_DELAY:-15}"
    tag="$(frontend_image_tag)"
    latest="$(frontend_image_latest)"

    frontend_provision_build_files || return 1
    frontend_registry_preflight || return 1

    log_info "Building Docker image ${tag}..."
    # Supabase URLs and keys are not build-time inputs: the app reads them from
    # process.env at runtime via /runtime-config.js, and frontend_run_container
    # passes them as container env vars. See frontend_run_container below.
    while ! run_logged "docker build" docker build \
            --build-arg "APP_PORT=${APP_PORT}" \
            --label "$APP_IMAGE_LABEL" \
            -t "$tag" -t "$latest" \
            -f "${APP_DIR}/Dockerfile" \
            "$APP_DIR"; do
        if ! is_network_error "$SO_LAST_OUTPUT"; then
            return 1
        fi
        if (( attempt >= attempts )); then
            log_error "The build kept failing on network errors (${attempts} attempts)."
            log_error "Check this host's DNS and outbound access to Docker Hub."
            return 1
        fi
        log_warn "That looks like a network error; retrying in ${delay}s (attempt $((attempt + 1))/${attempts})..."
        sleep "$delay"
        attempt=$(( attempt + 1 ))
        delay=$(( delay * 2 ))
    done
    log_ok "Image built: ${tag}"
    return 0
}

# ---------------------------------------------------------------------------
# Container lifecycle
# ---------------------------------------------------------------------------

container_exists()  { docker container inspect "$1" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# Where the published port is bound. Defaults to loopback so the container is
# reachable by a reverse proxy on this host but not from the public internet.
frontend_bind_address() {
    printf '%s' "${APP_BIND:-127.0.0.1}"
}

# The shared secret the reverse proxy sends with a Windows PC's client
# certificate (sentinel-ops#550): the app trusts the forwarded certificate only
# when the secret comes with it, and answers 503 on /ManagementServer/MDM.svc
# without one. Generated once, at least 24 characters, and kept with the other
# secrets in supabase/.env; `sentinel-ops credentials --show` prints it for
# the proxy's configuration (docs/REVERSE-PROXY.md).
frontend_mdm_proxy_secret() {
    local env_file="${SUPABASE_DIR}/.env" secret
    secret="$(env_get "$env_file" MDM_PROXY_SECRET 2>/dev/null || true)"
    if [[ ${#secret} -lt 24 ]]; then
        secret="$(random_token 32)"
        env_set "$env_file" MDM_PROXY_SECRET "$secret"
    fi
    printf '%s' "$secret"
}

# Start a container from an image. frontend_run_container <name> <image> <host-port>
frontend_run_container() {
    local name="$1" image="$2" host_port="$3" network bind attached="false"
    network="$(supabase_network_name)"
    bind="$(frontend_bind_address)"

    docker rm -f "$name" >/dev/null 2>&1 || true

    # Attaching to the Supabase network lets a dockerised reverse proxy route to
    # this container by name instead of going back out through the host, and is
    # also how the Nitro server reaches the Supabase gateway (see below).
    if docker network inspect "$network" >/dev/null 2>&1; then
        attached="true"
    else
        log_warn "Supabase network '${network}' not found; starting on the default bridge."
    fi

    # The image ships with no credentials in it on purpose, so everything the
    # server needs has to arrive here. This is not just the browser's
    # configuration: the app is a TanStack Start/Nitro server, and its
    # server-side code reads SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from
    # process.env (src/integrations/supabase/client.server.ts). Without them
    # every server function and /api/health fail with "Missing Supabase
    # environment variable(s)" while the container still serves HTML, so the
    # deployment looks up but cannot talk to the database.
    local pub_key svc_key server_url
    if ! pub_key="$(supabase_publishable_key)"; then
        log_error "Could not read the Supabase publishable (anon) key from ${SUPABASE_DIR}/.env"
        return 1
    fi
    if ! svc_key="$(supabase_service_role_key)"; then
        log_error "Could not read the Supabase service-role key from ${SUPABASE_DIR}/.env"
        return 1
    fi

    # SUPABASE_URL is the endpoint the *server* dials, which is not the same as
    # the one the browser uses. SUPABASE_PUBLIC_URL is routinely
    # http://localhost:8000, and inside this container localhost is the
    # container itself, not the gateway. Address the gateway by its Compose
    # service name while we are on the Supabase network; only fall back to the
    # public URL when we are not, where it is the best guess available.
    if [[ "$attached" == "true" ]]; then
        server_url="http://api-gw:$(supabase_kong_port)"
    else
        server_url="$SUPABASE_PUBLIC_URL"
    fi

    # Runtime environment is passed explicitly rather than with --env-file:
    # Docker does not strip quotes from an env file, so the quoted values in
    # app/.env (which is written in the format the application's own tooling
    # expects) would arrive with literal " characters around them.
    local args=(
        run -d
        --name "$name"
        --restart unless-stopped
        -e "NODE_ENV=production"
        -e "APP_PORT=${APP_PORT}"
        # Nitro's node-server listens on PORT/HOST. HOST must be 0.0.0.0 or the
        # server binds to loopback *inside* the container and the published port
        # reaches nothing.
        -e "PORT=${APP_PORT}"
        -e "HOST=0.0.0.0"
        -e "SUPABASE_URL=${server_url}"
        # The browser gets this one, via the /runtime-config.js server route.
        -e "SUPABASE_PUBLIC_URL=${SUPABASE_PUBLIC_URL}"
        # The console's own public origin. Auth redirects only to SITE_URL/**, so
        # the Windows MDM sign-in builds its Azure AD callback on it
        # (sentinel-ops#633); `domain set` re-creates the container with the new one.
        -e "SITE_URL=${SITE_URL}"
        # Both keys are passed by name, not as NAME=value: run_logged writes the
        # argv it is given into the installer log, and the service-role key is a
        # full-access credential that must not be persisted there.
        -e SUPABASE_PUBLISHABLE_KEY
        -e SUPABASE_SERVICE_ROLE_KEY
        -p "${bind}:${host_port}:${APP_PORT}"
    )
    # Windows MDM (sentinel-ops#550): the proxy secret by name, like the keys
    # above; the header names only when the proxy uses other ones.
    args+=(-e MDM_PROXY_SECRET)
    if [[ -n "${MDM_CLIENT_CERT_HEADER:-}" ]]; then
        args+=(-e "MDM_CLIENT_CERT_HEADER=${MDM_CLIENT_CERT_HEADER}")
    fi
    if [[ -n "${MDM_PROXY_SECRET_HEADER:-}" ]]; then
        args+=(-e "MDM_PROXY_SECRET_HEADER=${MDM_PROXY_SECRET_HEADER}")
    fi
    # The browser needs the Turnstile site key to render the CAPTCHA, served
    # through /runtime-config.js like the Supabase URL. It is public by design.
    if [[ "$AUTH_CAPTCHA_ENABLED" == "true" && -n "$TURNSTILE_SITE_KEY" ]]; then
        args+=(-e "TURNSTILE_SITE_KEY=${TURNSTILE_SITE_KEY}")
    fi
    if [[ "$attached" == "true" ]]; then
        args+=(--network "$network")
    fi
    args+=("$image")

    local rc=0 mdm_secret
    mdm_secret="$(frontend_mdm_proxy_secret)"
    export SUPABASE_PUBLISHABLE_KEY="$pub_key"
    export SUPABASE_SERVICE_ROLE_KEY="$svc_key"
    export MDM_PROXY_SECRET="$mdm_secret"
    run_logged "start ${name}" docker "${args[@]}" || rc=$?
    unset SUPABASE_PUBLISHABLE_KEY SUPABASE_SERVICE_ROLE_KEY MDM_PROXY_SECRET
    return "$rc"
}

frontend_check_http() {
    local port="${1:-$APP_PORT}" code
    code="$(_http_code "http://127.0.0.1:${port}/")"
    [[ "$code" =~ ^(200|301|302)$ ]]
}

frontend_health_check() {
    local port="${1:-$APP_PORT}"
    log_info "Checking the frontend on port ${port}..."
    if wait_for 90 3 frontend_check_http "$port"; then
        log_ok "Frontend responding"
        return 0
    fi
    log_error "Frontend did not answer on port ${port}"
    docker logs --tail 40 "$APP_CONTAINER_NAME" 2>&1 | tail -n 40 >&2 || true
    return 1
}

# Find a free TCP port for the staging container.
_free_port() {
    local port
    for port in $(seq 39000 39050); do
        port_in_use "$port" || { printf '%s' "$port"; return 0; }
    done
    printf '39099'
}

# Deploy the new image without destroying the running one first.
#
#   verify the new image on a staging container
#        -> only then replace the live container
#        -> if the replacement is unhealthy, restore the previous image
frontend_deploy() {
    local image staging_name staging_port previous_image
    image="$(frontend_image_tag)"
    staging_name="${APP_CONTAINER_NAME}-staging"
    staging_port="$(_free_port)"
    previous_image="$(state_get APP_IMAGE '')"

    # 1. Prove the new image actually serves traffic.
    log_info "Verifying the new image on a staging container..."
    if ! frontend_run_container "$staging_name" "$image" "$staging_port"; then
        docker rm -f "$staging_name" >/dev/null 2>&1 || true
        return 1
    fi
    if ! wait_for 90 3 frontend_check_http "$staging_port"; then
        log_error "The new image failed its health check; the running deployment was left untouched."
        docker logs --tail 40 "$staging_name" 2>&1 | tail -n 40 >&2 || true
        docker rm -f "$staging_name" >/dev/null 2>&1 || true
        return 1
    fi
    log_ok "New image verified"
    docker rm -f "$staging_name" >/dev/null 2>&1 || true

    # 2. Swap the live container over.
    if container_exists "$APP_CONTAINER_NAME"; then
        log_info "Replacing the running container..."
        docker rm -f "$APP_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    if frontend_run_container "$APP_CONTAINER_NAME" "$image" "$APP_PORT" \
        && wait_for 90 3 frontend_check_http "$APP_PORT"; then
        log_ok "Sentinel Ops frontend deployed (${image})"
        state_set APP_IMAGE "$image"
        [[ -n "$previous_image" && "$previous_image" != "$image" ]] && \
            state_set PREVIOUS_APP_IMAGE "$previous_image"
        return 0
    fi

    # 3. Roll back to the previous image if we have one.
    log_error "The replacement container is unhealthy."
    if [[ -n "$previous_image" ]] && docker image inspect "$previous_image" >/dev/null 2>&1; then
        log_warn "Rolling back to ${previous_image}..."
        if frontend_run_container "$APP_CONTAINER_NAME" "$previous_image" "$APP_PORT" \
            && wait_for 60 3 frontend_check_http "$APP_PORT"; then
            log_ok "Rolled back to ${previous_image}"
        else
            log_error "Rollback also failed. The frontend is down."
        fi
    else
        log_error "No previous image recorded; cannot roll back automatically."
    fi
    return 1
}

frontend_deployed_image() { state_get APP_IMAGE ''; }
