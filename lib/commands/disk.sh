#!/usr/bin/env bash
# lib/commands/disk.sh - where the disk goes, and giving some of it back.
#
#   sentinel-ops disk                 the breakdown; at a terminal, then offers
#                                     what can be reclaimed, by number
#   sentinel-ops disk prune <backups|logs|images|all>... [--dry-run]
#
# `cleanup` stays the one-shot "apply every limit"; this is the same pruning
# with a picture first and a choice of what goes. Measuring and drawing are
# in lib/disk_report.sh.
# shellcheck shell=bash

_disk_usage() {
    printf 'Usage: sentinel-ops disk [usage]\n'
    printf '       sentinel-ops disk prune <backups|logs|images|all>... [--dry-run]\n'
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
        usage|show)     _disk_preflight; _disk_report ;;
        prune)          _disk_preflight; _disk_prune "$@" ;;
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
    dr_measure_all
    dr_render_all

    # A script or --yes gets the report only; a person at a terminal is asked.
    if [[ ! -t 0 || "$SO_ASSUME_YES" == "true" ]]; then
        [[ -n "$(dr_reclaimable_rows)" ]] && \
            printf 'To reclaim: sudo sentinel-ops disk prune all [--dry-run]\n\n'
        return 0
    fi
    _disk_offer
}

# Ask which of the reclaimable items to clean up, by number.
_disk_offer() {
    local rows answer n targets=() picked offered=()
    rows="$(dr_reclaimable_rows)"
    [[ -n "$rows" ]] || return 0
    mapfile -t offered < <(cut -d'|' -f1 <<<"$rows")

    printf 'Reclaim which? Numbers separated by spaces, "a" for all, Enter for none: '
    IFS= read -r answer || answer=""
    [[ -n "${answer// /}" ]] || { log_info "Nothing removed."; return 0; }

    if [[ "$answer" =~ ^[[:space:]]*[Aa]([Ll][Ll])?[[:space:]]*$ ]]; then
        targets=("${offered[@]}")
    else
        for n in $answer; do
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#offered[@]} )); then
                targets+=("${offered[$((n - 1))]}")
            else
                log_warn "Ignoring '${n}': not one of the numbers listed."
            fi
        done
    fi
    (( ${#targets[@]} )) || return 0

    picked="$(printf '%s ' "${targets[@]}")"
    confirm "Reclaim: ${picked% }?" y || { log_info "Cancelled."; return 0; }
    _disk_prune "${targets[@]}"
}

_disk_prune() {
    local args=() t targets dry=""
    for t in "$@"; do
        case "$t" in
            --dry-run|-n) dry="--dry-run" ;;
            *) args+=("$t") ;;
        esac
    done
    if (( ${#args[@]} == 0 )); then
        log_error "Say what to prune."
        _disk_usage
        return 2
    fi
    targets="$(dr_resolve_targets "${args[@]}")" || { _disk_usage; return 2; }

    # Images and backups must not be removed from under an update or a backup
    # that is half way through.
    update_lock_or_die
    SO_LOG_FILE="${LOG_DIR}/disk-prune-$(timestamp).log"

    local before after
    before="$(disk_free_bytes "$INSTALL_DIR")"

    printf '\n'
    [[ -n "$dry" ]] && log_info "Dry run: nothing will be removed."
    while IFS= read -r t; do
        [[ -n "$t" ]] && dr_prune_target "$t" "$dry"
    done <<<"$targets"

    if [[ -z "$dry" ]]; then
        after="$(disk_free_bytes "$INSTALL_DIR")"
        if [[ -n "$before" && -n "$after" ]] && (( after > before )); then
            printf '\n'
            log_ok "Freed $(human_bytes $(( after - before ))) on the filesystem holding ${INSTALL_DIR}."
        fi
    fi
    printf '\n'
    return 0
}
