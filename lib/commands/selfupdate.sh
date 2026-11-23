#!/usr/bin/env bash
# lib/commands/selfupdate.sh - update the installed copy of this tool.
#
# `install` copies bin/, lib/ and assets/ into the installation root, and that
# copy is what `sentinel-ops` runs from then on. This replaces it with a newer
# installer - from GitHub by default, or from a local checkout - without
# touching the deployed stack.
#
# It deliberately does not take the update lock (lib/commands/update.sh): an
# auto-update can be half way through a long image build, and that must not
# stand between an operator and a fix to the installer. The swap is a set of
# renames, so a process already running the old copy keeps its open files and
# finishes on the code it started with; the next one picks up the new copy.
# shellcheck shell=bash

SO_INSTALLER_REPO_URL="https://github.com/BrainStation-23/SentinelOps-installer"

# The parts of the installer that `install` copies - and so the parts that are
# replaced here.
SO_INSTALLER_TREES=(bin lib assets)

_selfupdate_branch() {
    printf '%s' "${SENTINEL_OPS_INSTALLER_BRANCH:-${INSTALLER_BRANCH:-main}}"
}

# _selfupdate_download <branch> <dest-dir>
_selfupdate_download() {
    local branch="$1" dest="$2" url
    url="${SO_INSTALLER_REPO_URL}/archive/refs/heads/${branch}.tar.gz"
    have_cmd tar || { log_error "tar is required to download the installer."; return 1; }

    log_info "Downloading the installer (${branch})..."
    if have_cmd curl; then
        curl -fsSL "$url" | tar -xz -C "$dest" --strip-components=1
    elif have_cmd wget; then
        wget -qO- "$url" | tar -xz -C "$dest" --strip-components=1
    else
        log_error "Neither curl nor wget is available."
        return 1
    fi || { log_error "Could not download ${url}"; return 1; }
}

# _selfupdate_validate <dir> - is this a complete installer that will load?
#
# Replacing a working installer with a broken one leaves nothing to run the
# fix with, so anything doubtful is refused before a single file is swapped.
_selfupdate_validate() {
    local src="$1" f sub
    for sub in "${SO_INSTALLER_TREES[@]}"; do
        [[ -d "${src}/${sub}" ]] || { log_error "${src} has no ${sub}/ - not a Sentinel Ops installer."; return 1; }
    done
    for f in bin/sentinel-ops lib/common.sh lib/config.sh lib/selfinstall.sh; do
        [[ -f "${src}/${f}" ]] || { log_error "${src} is missing ${f} - not a Sentinel Ops installer."; return 1; }
    done
    for f in "${src}/bin/sentinel-ops" "${src}"/lib/*.sh "${src}"/lib/commands/*.sh; do
        if grep -qU $'\r' "$f" 2>/dev/null; then
            log_error "${f#"${src}"/} has Windows line endings (CRLF); refusing to install it."
            return 1
        fi
        if ! bash -n "$f" 2>/dev/null; then
            log_error "${f#"${src}"/} has a syntax error; refusing to install it."
            return 1
        fi
    done
    return 0
}

# _selfupdate_changes <new-root> <current-root>
# One "added|removed|changed <path>" line per differing file; nothing when the
# two are identical. Content, not timestamps - see _installer_differs().
_selfupdate_changes() {
    local new="$1" cur="$2" f
    {
        (cd "$new" && find "${SO_INSTALLER_TREES[@]}" -type f 2>/dev/null) || true
        (cd "$cur" && find "${SO_INSTALLER_TREES[@]}" -type f 2>/dev/null) || true
    } | sort -u | while IFS= read -r f; do
        if [[ ! -f "${cur}/${f}" ]]; then
            printf 'added    %s\n' "$f"
        elif [[ ! -f "${new}/${f}" ]]; then
            printf 'removed  %s\n' "$f"
        elif [[ "$(cksum <"${new}/${f}")" != "$(cksum <"${cur}/${f}")" ]]; then
            printf 'changed  %s\n' "$f"
        fi
    done
}

# Put whatever was moved aside back. Used only when a swap fails part way.
_selfupdate_restore() {
    local prev="$1" sub
    for sub in "${SO_INSTALLER_TREES[@]}"; do
        [[ -e "${prev}/${sub}" ]] || continue
        rm -rf "${INSTALL_DIR:?}/${sub}"
        mv "${prev}/${sub}" "${INSTALL_DIR}/${sub}"
    done
}

# _selfupdate_swap <new-root>
#
# Renames, never an in-place overwrite: bash reads a running script lazily, so
# rewriting bin/sentinel-ops under a process that is executing it (a running
# auto-update, or this very command) would splice two versions together. A
# rename leaves that process holding the old file.
_selfupdate_swap() {
    local src="$1" stage="${INSTALL_DIR}/.installer-new" prev="${INSTALL_DIR}/.installer-prev" sub

    rm -rf "$stage"
    mkdir -p "$stage" || return 1
    for sub in "${SO_INSTALLER_TREES[@]}"; do
        cp -a "${src}/${sub}" "${stage}/" || { rm -rf "$stage"; return 1; }
    done
    chmod +x "${stage}/bin/sentinel-ops" 2>/dev/null || true

    # The copy being replaced is kept until the next self-update, so a bad
    # release can be put back by hand (see the wiki page Update-the-Installer).
    rm -rf "$prev"
    mkdir -p "$prev" || return 1
    for sub in "${SO_INSTALLER_TREES[@]}"; do
        if [[ -e "${INSTALL_DIR}/${sub}" ]] && ! mv "${INSTALL_DIR}/${sub}" "${prev}/${sub}"; then
            _selfupdate_restore "$prev"; rm -rf "$stage"; return 1
        fi
        if ! mv "${stage}/${sub}" "${INSTALL_DIR}/${sub}"; then
            _selfupdate_restore "$prev"; rm -rf "$stage"; return 1
        fi
    done
    rm -rf "$stage"
    return 0
}

# Run by the *new* copy straight after a swap, so anything generated from the
# installer's code (systemd units) is regenerated by the code now in place.
_selfupdate_refresh() {
    config_load || true
    if [[ "$AUTO_UPDATE_ENABLED" == "true" ]]; then
        autoupdate_refresh_units || log_warn "Could not refresh the auto-update timer; re-run: sentinel-ops auto-update enable"
    fi
    if [[ "$BACKUP_SCHEDULE_ENABLED" == "true" ]]; then
        _schedule_install_units >/dev/null 2>&1 || log_warn "Could not refresh the backup timer; re-run: sentinel-ops schedule enable"
    fi
    return 0
}

# _selfupdate_run <check|apply> [local-source-dir]
_selfupdate_run() {
    local mode="$1" from="${2:-}" src tmp="" label changes

    [[ -f "${INSTALL_DIR}/bin/sentinel-ops" ]] || \
        die "No installed copy of sentinel-ops at ${INSTALL_DIR}. Run the installer first: sudo ./install.sh"

    # Two self-updates swapping the same directories would trample each other.
    # Its own lock - never the update lock, see the top of this file.
    if have_cmd flock; then
        local fd
        mkdir -p "$STATE_DIR"
        exec {fd}>"${STATE_DIR}/self-update.lock"
        flock -n "$fd" || die "Another self-update is already running."
    fi

    if [[ -n "$from" ]]; then
        [[ -d "$from" ]] || die "${from} is not a directory."
        src="$(cd -P "$from" && pwd)"
        [[ "$src" != "$INSTALL_DIR" ]] || die "${src} is the installed copy itself; pass the checkout to update from."
        label="$src"
    else
        tmp="$(mktemp -d)"
        src="$tmp"
        label="${SO_INSTALLER_REPO_URL} ($(_selfupdate_branch))"
        _selfupdate_download "$(_selfupdate_branch)" "$tmp" || { rm -rf "$tmp"; return 1; }
    fi

    if ! _selfupdate_validate "$src"; then
        [[ -n "$tmp" ]] && rm -rf "$tmp"
        return 1
    fi

    changes="$(_selfupdate_changes "$src" "$INSTALL_DIR")"
    state_set INSTALLER_LAST_CHECK_AT "$(date -Is 2>/dev/null || date)"
    if [[ -z "$changes" ]]; then
        log_ok "The installer is already up to date with ${label}."
        [[ -n "$tmp" ]] && rm -rf "$tmp"
        return 0
    fi

    log_info "$(printf '%s\n' "$changes" | wc -l | tr -d ' ') file(s) differ from ${label}:"
    printf '%s\n' "$changes" | head -n 30 | sed 's/^/    /'
    if [[ "$mode" == "check" ]]; then
        log_info "Apply with: sudo sentinel-ops self-update${from:+ from ${from}}"
        [[ -n "$tmp" ]] && rm -rf "$tmp"
        return 0
    fi

    if ! _selfupdate_swap "$src"; then
        [[ -n "$tmp" ]] && rm -rf "$tmp"
        die "Could not replace the installer files; the previous copy was left in place."
    fi
    [[ -n "$tmp" ]] && rm -rf "$tmp"

    state_set INSTALLER_UPDATED_AT "$(date -Is 2>/dev/null || date)"
    state_set INSTALLER_SOURCE "$label"
    # Provenance for warn_if_stale(): a local checkout is now the source; after
    # a download, an older checkout recorded earlier no longer is, and would
    # only produce a misleading "differs" warning.
    state_set INSTALLED_FROM "${from:+$src}"
    log_ok "Installer updated from ${label}."
    log_info "Commands already running (including an open menu) finish on the old copy; the next one uses the new."

    "${INSTALL_DIR}/bin/sentinel-ops" --dir "$INSTALL_DIR" self-update refresh || \
        log_warn "The new installer could not refresh its systemd units."
    log_info "The application itself was not touched. To deploy a new release: sentinel-ops update app"
    return 0
}

cmd_self_update() {
    require_root self-update
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true

    case "${1:-apply}" in
        apply)      _selfupdate_run apply ;;
        check)      _selfupdate_run check ;;
        from)
            [[ -n "${2:-}" ]] || die "Usage: sentinel-ops self-update from <installer-checkout>"
            _selfupdate_run apply "$2"
            ;;
        refresh)    _selfupdate_refresh ;;
        *)
            log_error "Unknown self-update subcommand: $1"
            printf 'Valid: apply (default), check, from <path>\n'
            return 2
            ;;
    esac
}
