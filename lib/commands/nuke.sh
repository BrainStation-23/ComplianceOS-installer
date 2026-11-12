#!/usr/bin/env bash
# lib/commands/nuke.sh - destroy this installation so a fresh one can be tested.
#
# This is the counterpart to `install`: it removes the containers, volumes,
# application images and the installation directory, leaving the host in a
# state where `install` runs from scratch again. It exists so a server can be
# used to test the installer repeatedly without hand-unpicking the last run.
#
# Order matters. Docker is torn down *before* the filesystem, because
# `docker compose down` needs supabase/docker-compose.yml and supabase/.env to
# still be there to know what to remove. Deleting the directory first orphans
# every container and volume.
#
# What is deliberately NOT removed:
#
#   Supabase images   Re-pulling the stack is several GB and many minutes. The
#                     point of this command is a fast reinstall loop, and a
#                     cached image cannot make an installation stale - the
#                     compose file pins what it wants.
#   Docker itself     A prerequisite, not part of the deployment.
#
# shellcheck shell=bash

NUKE_KEEP_BACKUPS="false"
NUKE_KEEP_CONFIG="false"

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

# An empty or absurd INSTALL_DIR would turn this into `rm -rf /`. The value can
# come from --dir or a hand-edited installer.env, so it is checked rather than
# trusted.
_nuke_check_install_dir() {
    [[ -n "$INSTALL_DIR" ]] || die "INSTALL_DIR is empty; refusing to remove anything."
    [[ "$INSTALL_DIR" == /* ]] || die "INSTALL_DIR (${INSTALL_DIR}) is not an absolute path."
    case "$INSTALL_DIR" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/opt|/proc|/root|/run|/sbin|/srv|/sys|/usr|/var)
            die "Refusing to remove ${INSTALL_DIR}."
            ;;
    esac
    return 0
}

# The Compose project name, used to find containers when the compose file is
# already gone or unreadable. Mirrors Compose's own default: the sanitised
# directory name.
_nuke_project_name() {
    basename "$SUPABASE_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-'
}

# ---------------------------------------------------------------------------
# What is about to be destroyed
# ---------------------------------------------------------------------------

_nuke_inventory() {
    section "About to destroy"

    status_line "Install dir" "" "$INSTALL_DIR"
    if [[ -d "$INSTALL_DIR" ]]; then
        status_line "Size" "" "$(du -sh "$INSTALL_DIR" 2>/dev/null | cut -f1 || printf 'unknown')"
    else
        status_line "Size" "warn" "Not present"
    fi

    if supabase_installed; then
        status_line "Supabase" "bad" "Stack and ALL volumes (the database)"
    else
        status_line "Supabase" "" "Not installed"
    fi

    local running=0 name
    for name in "$APP_CONTAINER_NAME" "${APP_CONTAINER_NAME}-staging" "$MDM_PROXY_CONTAINER"; do
        container_exists "$name" && running=$(( running + 1 ))
    done
    status_line "App containers" "" "${running} to remove"

    local images
    images="$(docker images -q "$APP_IMAGE_NAME" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
    status_line "App images" "" "${images} (${APP_IMAGE_NAME}:*)"

    local backups
    backups="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$NUKE_KEEP_BACKUPS" == "true" ]]; then
        status_line "Backups" "ok" "${backups} kept (--keep-backups)"
    else
        status_line "Backups" "bad" "${backups} DELETED"
    fi

    if [[ "$NUKE_KEEP_CONFIG" == "true" ]]; then
        status_line "Config" "ok" "Kept, incl. deploy key (--keep-config)"
    else
        status_line "Config" "bad" "Deleted, incl. deploy key"
    fi

    if [[ "$RESTIC_SECONDARY_ENABLED" == "true" || "$RESTIC_OFFSITE_ENABLED" == "true" ]]; then
        status_line "Offsite/secondary backups" "ok" \
            "NOT touched - separate medium; see: sentinel-ops remote status"
    fi

    printf '\n'
    return 0
}

# A y/N prompt is too easy to fumble for something that drops a database, so
# the confirmation is a typed word. Without a terminal the command refuses
# rather than falling through to a default, which is the opposite of how
# `confirm` behaves everywhere else - here the safe default is "do nothing".
#
# Exit codes are distinct on purpose: 1 is "the operator said no" (a success
# for the script that asked), 2 is "this cannot be answered here". A test
# harness running `nuke && install` must not read a missing terminal as a
# completed teardown and then install over a live stack.
_nuke_confirm() {
    if [[ "$SO_ASSUME_YES" == "true" ]]; then
        log_warn "--yes given; proceeding without confirmation."
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_error "nuke needs a terminal to confirm, or --yes to skip the prompt."
        return 2
    fi

    local answer=""
    printf '%sType %snuke%s%s to confirm, anything else to cancel: %s' \
        "$C_YELLOW" "$C_BOLD" "$C_RESET" "$C_YELLOW" "$C_RESET"
    IFS= read -r answer || answer=""
    [[ "$answer" == "nuke" ]]
}

# ---------------------------------------------------------------------------
# Teardown steps
#
# Every step is best-effort: a nuke that stops halfway because one container
# was already gone is worse than useless, since the operator then has to finish
# it by hand anyway. Failures are warned about and the run continues.
# ---------------------------------------------------------------------------

_nuke_app_containers() {
    local name
    for name in "$APP_CONTAINER_NAME" "${APP_CONTAINER_NAME}-staging" "$MDM_PROXY_CONTAINER"; do
        if container_exists "$name"; then
            docker rm -f "$name" >/dev/null 2>&1 && log_ok "Removed container ${name}" \
                || log_warn "Could not remove container ${name}"
        fi
    done
    return 0
}

_nuke_supabase() {
    if ! supabase_installed; then
        log_info "No Supabase deployment files; skipping compose teardown."
        return 0
    fi

    # -v is the whole point here: it removes the named volumes holding the
    # database. Everywhere else in this installer that flag is forbidden.
    log_info "Stopping Supabase and removing its volumes..."
    if run_logged "supabase down -v" bash -c \
        "$(_supabase_compose_cmd) down -v --remove-orphans --timeout 30"; then
        log_ok "Supabase stack and volumes removed"
    else
        log_warn "compose down failed; falling back to removing containers by project label."
    fi
    return 0
}

# Safety net for a compose file that is missing, broken, or was written by a
# different Compose version: find anything still labelled with this project.
_nuke_orphans() {
    local project ids
    project="$(_nuke_project_name)"
    [[ -n "$project" ]] || return 0

    ids="$(docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null)"
    if [[ -n "$ids" ]]; then
        log_info "Removing leftover containers from project '${project}'..."
        # shellcheck disable=SC2086
        docker rm -f $ids >/dev/null 2>&1 || log_warn "Could not remove every leftover container."
    fi

    ids="$(docker volume ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null)"
    if [[ -n "$ids" ]]; then
        log_info "Removing leftover volumes from project '${project}'..."
        # shellcheck disable=SC2086
        docker volume rm -f $ids >/dev/null 2>&1 || log_warn "Could not remove every leftover volume."
    fi

    ids="$(docker network ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null)"
    if [[ -n "$ids" ]]; then
        # shellcheck disable=SC2086
        docker network rm $ids >/dev/null 2>&1 || true
    fi
    return 0
}

_nuke_images() {
    local ids
    ids="$(docker images -q "$APP_IMAGE_NAME" 2>/dev/null | sort -u)"
    if [[ -z "$ids" ]]; then
        log_info "No ${APP_IMAGE_NAME} images to remove."
        return 0
    fi
    # shellcheck disable=SC2086
    if docker rmi -f $ids >/dev/null 2>&1; then
        log_ok "Removed ${APP_IMAGE_NAME} images"
    else
        log_warn "Could not remove every ${APP_IMAGE_NAME} image."
    fi
    return 0
}

_nuke_filesystem() {
    [[ -d "$INSTALL_DIR" ]] || { log_info "${INSTALL_DIR} does not exist."; return 0; }

    local keep=()
    [[ "$NUKE_KEEP_BACKUPS" == "true" ]] && keep+=("backups")
    [[ "$NUKE_KEEP_CONFIG" == "true" ]]  && keep+=("config")

    if (( ${#keep[@]} == 0 )); then
        rm -rf "$INSTALL_DIR" || { log_error "Could not remove ${INSTALL_DIR}"; return 1; }
        log_ok "Removed ${INSTALL_DIR}"
        return 0
    fi

    local entry base k skip
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        base="$(basename "$entry")"
        skip="false"
        for k in "${keep[@]}"; do
            [[ "$base" == "$k" ]] && skip="true"
        done
        [[ "$skip" == "true" ]] && continue
        rm -rf "$entry" || log_warn "Could not remove ${entry}"
    done < <(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)

    log_ok "Emptied ${INSTALL_DIR} (kept: ${keep[*]})"
    return 0
}

# A timer left behind would keep firing at an installation that no longer
# exists - and one firing mid-nuke would start deploying into it. Stopped
# before anything else goes; the unit files go with the installation.
_nuke_timers() {
    have_cmd systemctl || return 0
    local unit
    for unit in "$SO_AUTOUPDATE_UNIT" "$SO_BACKUP_UNIT" "$SO_MDM_CERT_UNIT" "$SO_LOGFLARE_RETENTION_UNIT"; do
        [[ -f "/etc/systemd/system/${unit}.timer" ]] || continue
        systemctl disable --now "${unit}.timer" >/dev/null 2>&1 || true
        systemctl stop "${unit}.service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${unit}.timer" "/etc/systemd/system/${unit}.service"
        log_ok "Removed ${unit} timer"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
}

# Only remove the PATH symlink if it actually points into what we just deleted.
# A link to something else is somebody else's.
_nuke_symlink() {
    [[ -L "$SO_BIN_LINK" ]] || return 0
    local target
    target="$(readlink -f "$SO_BIN_LINK" 2>/dev/null || readlink "$SO_BIN_LINK" 2>/dev/null || true)"
    if [[ "$target" == "${INSTALL_DIR}/"* ]]; then
        rm -f "$SO_BIN_LINK" && log_ok "Removed ${SO_BIN_LINK}"
    else
        log_debug "${SO_BIN_LINK} points at ${target}; left alone"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Command
# ---------------------------------------------------------------------------

cmd_nuke() {
    require_root nuke

    while (( $# )); do
        case "$1" in
            --keep-backups) NUKE_KEEP_BACKUPS="true"; shift ;;
            --keep-config)  NUKE_KEEP_CONFIG="true";  shift ;;
            --keep-all)     NUKE_KEEP_BACKUPS="true"; NUKE_KEEP_CONFIG="true"; shift ;;
            "")             shift ;;
            *)              log_error "Unknown nuke option: $1"
                            printf 'Valid: --keep-backups, --keep-config, --keep-all\n'
                            return 2 ;;
        esac
    done

    _nuke_check_install_dir
    config_load || true
    detect_compose >/dev/null 2>&1 || true

    banner "Nuke"
    printf '\n'

    if [[ ! -d "$INSTALL_DIR" ]] && ! container_exists "$APP_CONTAINER_NAME"; then
        log_info "Nothing to remove: ${INSTALL_DIR} does not exist and no containers are present."
        return 0
    fi

    _nuke_inventory

    log_warn "This destroys the database and every uploaded object. It cannot be undone."
    if [[ "$NUKE_KEEP_BACKUPS" != "true" ]]; then
        log_warn "Backups are included. Pass --keep-backups to spare them."
    fi
    printf '\n'

    local rc=0
    _nuke_confirm || rc=$?
    if (( rc != 0 )); then
        (( rc == 2 )) && return 2
        log_info "Cancelled; nothing was removed."
        return 0
    fi
    printf '\n'

    # Logging to a file under INSTALL_DIR would only delete itself a moment
    # later, so this command reports to the terminal alone.
    SO_LOG_FILE=""

    _nuke_timers

    if docker_daemon_ok; then
        phase_begin "Removing containers and volumes"
        _nuke_app_containers
        _nuke_supabase
        _nuke_orphans
        _nuke_images
        phase_end
    else
        log_warn "Docker is not responding; removing files only."
        log_warn "Containers and volumes will survive - start Docker and re-run to clear them."
    fi

    phase_begin "Removing files"
    # Safe to delete the directory this script is running from: bash holds an
    # open descriptor on the file, and unlinking on Linux leaves that readable
    # until the process exits.
    _nuke_filesystem
    _nuke_symlink
    phase_end

    printf '\n'
    log_ok "Nuked. This host is ready for a fresh install."
    if [[ "$NUKE_KEEP_CONFIG" == "true" ]]; then
        printf '  Config and deploy key kept at %s/config\n' "$INSTALL_DIR"
        printf '  Reinstall with:  sudo ./install.sh --yes\n\n'
    else
        printf '  Reinstall with:  sudo ./install.sh\n\n'
    fi
    return 0
}
