#!/usr/bin/env bash
# lib/commands/branch.sh - choose which application branch is deployed.
#
# APP_BRANCH is the single setting both `update app` and the auto-update timer
# follow, so switching branches is a config change plus an ordinary update:
# repo_update checks the new branch out and the usual backup, migrations and
# staged deploy run against it. Nothing here touches the stack directly.
#
# The one thing an update cannot undo is the schema. Migrations are only ever
# applied forward, so moving to a branch that does not contain what is
# deployed (dev back to main, say) leaves the database ahead of the code. That
# case is detected up front and has to be confirmed.
# shellcheck shell=bash

# A name Git accepts as a branch, and that cannot be mistaken for an option.
_branch_valid_name() {
    local name="$1"
    [[ -n "$name" && "$name" != -* ]] || return 1
    git check-ref-format --branch "$name" >/dev/null 2>&1
}

_branch_exists_remote() {
    GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 \
        git ls-remote --exit-code --heads "$APP_REPOSITORY" "refs/heads/$1" \
        >/dev/null 2>>"${SO_LOG_FILE:-/dev/null}"
}

_branch_status() {
    local deployed_branch deployed_commit
    deployed_branch="$(state_get APP_BRANCH '')"
    deployed_commit="$(state_get APP_COMMIT '')"

    section "Application branch"
    status_line "Repository" "" "$APP_REPOSITORY"
    if [[ -n "$deployed_branch" && "$deployed_branch" != "$APP_BRANCH" ]]; then
        status_line "Configured" "warn" "${APP_BRANCH} (not deployed yet - run: sentinel-ops update app)"
    else
        status_line "Configured" "ok" "$APP_BRANCH"
    fi
    status_line "Deployed" "" "${deployed_branch:-unknown} @ ${deployed_commit:0:7}"
    if [[ "$AUTO_UPDATE_ENABLED" == "true" ]]; then
        status_line "Auto-update" "" "on - follows ${APP_BRANCH}"
    else
        status_line "Auto-update" "" "off"
    fi
    return 0
}

# branch set <name>
_branch_set() {
    local branch="${1:-}" deployed_commit
    if [[ -z "$branch" ]]; then
        log_error "Usage: sentinel-ops branch set <name>"
        return 2
    fi
    _branch_valid_name "$branch" || die "Not a valid branch name: ${branch}"

    if [[ "$branch" == "$APP_BRANCH" && "$(state_get APP_BRANCH '')" == "$branch" ]]; then
        log_ok "Already deploying ${branch}."
        return 0
    fi

    # Held for the whole switch, so an auto-update cannot deploy the old
    # branch between the config change and the update below.
    update_lock_or_die

    deploy_key_prepare || die "Deployment key unavailable."
    deploy_key_known_hosts
    _branch_exists_remote "$branch" \
        || die "Branch '${branch}' does not exist on ${APP_REPOSITORY} (or the repository is unreachable)."

    deployed_commit="$(state_get APP_COMMIT '')"
    if repo_is_cloned && [[ -n "$deployed_commit" && "$deployed_commit" != "unknown" ]]; then
        if ! app_git fetch --quiet origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" \
                2>>"${SO_LOG_FILE:-/dev/null}"; then
            die "Could not fetch ${branch} from ${APP_REPOSITORY}."
        fi
        if ! app_git merge-base --is-ancestor "$deployed_commit" "origin/${branch}" 2>/dev/null; then
            log_warn "${branch} does not contain the deployed commit ${deployed_commit:0:7}."
            log_warn "Migrations already applied from $(state_get APP_BRANCH "the current branch") stay applied - the"
            log_warn "database is not rolled back. If ${branch} cannot run against that schema, restore"
            log_warn "a backup taken while ${branch} was deployed instead (see https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Backup-and-Restore)."
            if [[ "$SO_ASSUME_YES" != "true" ]]; then
                confirm "Switch to ${branch} anyway?" n || { log_info "Cancelled. Nothing was changed."; return 0; }
            fi
        fi
    fi

    APP_BRANCH="$branch"
    config_save
    # Any held commit belonged to the old branch's history.
    state_set AUTO_UPDATE_SKIP_COMMIT ""
    state_set AUTO_UPDATE_SKIP_REASON ""
    log_ok "Application branch set to ${branch}."

    if confirm "Deploy ${branch} now?" y; then
        cmd_update_app
        return
    fi

    printf '\n'
    if [[ "$AUTO_UPDATE_ENABLED" == "true" ]]; then
        log_info "Auto-update will deploy ${branch} at its next check, or run: sentinel-ops update app"
    else
        log_info "Deploy it with: sentinel-ops update app"
    fi
    return 0
}

cmd_branch() {
    require_root branch
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true

    banner "Application Branch"
    printf '\n'

    case "${1:-status}" in
        status) _branch_status ;;
        set)    _branch_set "${2:-}" ;;
        *)
            log_error "Unknown branch subcommand: $1"
            printf 'Valid: status, set <name>\n'
            return 2
            ;;
    esac
}
