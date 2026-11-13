#!/usr/bin/env bash
# lib/commands/disk.sh - where the disk goes, and giving some of it back.
#
#   sentinel-ops disk                     the breakdown; on a terminal, then
#                                         offers what can be reclaimed
#   sentinel-ops disk prune <target...|all> [--dry-run]
#
# Targets: images, logs, backups (all three are `all`), and container-logs,
# which only runs when named. Measuring is in lib/disk.sh.
# shellcheck shell=bash

_disk_usage() {
    printf 'Usage: sentinel-ops disk [usage]\n'
    printf '       sentinel-ops disk prune <images|logs|backups|container-logs|all>... [--dry-run]\n'
}

_disk_preflight() {
    require_root disk
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
}

cmd_disk() {
    local sub="${1:-usage}"
    [[ $# -gt 0 ]] && shift
    case "$sub" in
        usage|show|"") _disk_preflight; _disk_report ;;
        prune|clean)   _disk_preflight; _disk_prune "$@" ;;
        help|-h|--help) _disk_usage ;;
        *)
            log_error "Unknown disk command: ${sub}"
            _disk_usage
            return 2
            ;;
    esac
}

_disk_report() {
    banner "Disk usage"
    disk_measure_all
    disk_render_all

    # The report is all a script or `--yes` gets; only a person at a terminal
    # is asked whether to clean anything up.
    [[ -t 0 && "$SO_ASSUME_YES" != "true" ]] || {
        [[ -n "$(disk_reclaimable_rows)" ]] && \
            printf 'To clean up: sudo sentinel-ops disk prune all [--dry-run]\n\n'
        return 0
    }
    _disk_offer
}

# Ask which of the reclaimable items to clean up, by number.
_disk_offer() {
    local rows answer n targets=() picked _disk_offer_targets=()
    rows="$(disk_reclaimable_rows)"
    [[ -n "$rows" ]] || return 0
    mapfile -t _disk_offer_targets < <(cut -d'|' -f1 <<<"$rows")

    printf 'Clean up which? Numbers separated by spaces, "a" for 1-%s, Enter for none: ' "${#_disk_offer_targets[@]}"
    IFS= read -r answer || answer=""
    [[ -n "${answer// /}" ]] || { log_info "Nothing cleaned up."; return 0; }

    if [[ "$answer" =~ ^[[:space:]]*[Aa]([Ll][Ll])?[[:space:]]*$ ]]; then
        targets=("${_disk_offer_targets[@]}")
    else
        for n in $answer; do
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#_disk_offer_targets[@]} )); then
                targets+=("${_disk_offer_targets[$((n - 1))]}")
            else
                log_warn "Ignoring '${n}': not one of the numbers listed."
            fi
        done
    fi
    (( ${#targets[@]} )) || return 0

    picked="$(printf '%s ' "${targets[@]}")"
    if [[ " $picked " == *" container-logs "* ]]; then
        log_warn "Emptying container logs loses what the services have printed so far."
    fi
    confirm "Clean up: ${picked% }?" y || { log_info "Cancelled."; return 0; }
    _disk_prune "${targets[@]}"
}

_disk_prune() {
    local args=() t targets
    SO_DISK_DRY_RUN="false"
    for t in "$@"; do
        case "$t" in
            --dry-run|-n) SO_DISK_DRY_RUN="true" ;;
            *) args+=("$t") ;;
        esac
    done
    if (( ${#args[@]} == 0 )); then
        log_error "Say what to prune."
        _disk_usage
        return 2
    fi
    targets="$(disk_resolve_targets "${args[@]}")" || { _disk_usage; return 2; }

    # Images and backups must not be removed from under an update or a
    # backup that is half way through.
    update_lock_or_die
    SO_LOG_FILE="${LOG_DIR}/disk-prune-$(timestamp).log"

    if grep -qxE 'images|container-logs' <<<"$targets"; then
        docker_daemon_ok || die "Docker is not available."
    fi

    local before after
    before="$(_disk_fs_used "$INSTALL_DIR")"

    printf '\n'
    [[ "$SO_DISK_DRY_RUN" == "true" ]] && log_info "Dry run: nothing will be removed."
    while IFS= read -r t; do
        [[ -n "$t" ]] && disk_prune_target "$t"
    done <<<"$targets"

    if [[ "$SO_DISK_DRY_RUN" != "true" ]]; then
        after="$(_disk_fs_used "$INSTALL_DIR")"
        if [[ -n "$before" && -n "$after" ]] && (( before > after )); then
            printf '\n'
            log_ok "Freed $(human_bytes $(( before - after ))) on the filesystem holding ${INSTALL_DIR}."
        fi
    fi
    printf '\n'
    return 0
}

# Bytes used on the filesystem holding a path ("" when unreadable).
_disk_fs_used() {
    df -PB1 "$1" 2>/dev/null | awk 'NR == 2 { print $3 }' || true
}
