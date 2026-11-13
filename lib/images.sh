#!/usr/bin/env bash
# lib/images.sh - remove the Docker images updates leave behind.
#
# Every deployment leaves something on disk, and auto-update adds to it
# unattended:
#
#   - each build is tagged sentinel-ops:<sha>, and the old tags are never
#     removed - by far the largest share, and not "dangling", so
#     `docker image prune` alone does not touch them;
#   - rebuilding a commit untags the previous build (dangling);
#   - BuildKit keeps layer cache from every build, failed ones included;
#   - `update supabase` pulls each service's new tag and leaves the old one.
#
# What is kept: the deployed image (APP_IMAGE), the one `rollback` returns to
# (PREVIOUS_APP_IMAGE), :latest, the images the Supabase compose config names,
# and anything a container - running or stopped - still uses. Nothing outside
# those repositories is touched: this host may run other workloads (a Zoraxy
# container, say), so there is no `docker system prune` and no
# `image prune -a` here. See docs/DECISIONS.md #33.
# shellcheck shell=bash

# Non-secret config, persisted in installer.env.
IMAGE_CLEANUP_ENABLED="true"
IMAGE_BUILD_CACHE_MAX_AGE="168h"

# Set by `sentinel-ops cleanup --dry-run`: list what would go, remove nothing.
SO_IMAGES_DRY_RUN="false"

images_cleanup_enabled() { [[ "$IMAGE_CLEANUP_ENABLED" != "false" ]]; }

# The build-cache age as a Go duration docker accepts; anything else falls
# back to the default rather than reaching the docker command line.
images_build_cache_max_age() {
    if [[ "$IMAGE_BUILD_CACHE_MAX_AGE" =~ ^[1-9][0-9]*[hm]$ ]]; then
        printf '%s' "$IMAGE_BUILD_CACHE_MAX_AGE"
    else
        log_warn "IMAGE_BUILD_CACHE_MAX_AGE='${IMAGE_BUILD_CACHE_MAX_AGE}' is not a duration like 168h; using 168h."
        printf '168h'
    fi
}

# Full image ids used by any container, running or stopped, one per line.
_images_in_use_ids() {
    local ids
    ids="$(docker ps -aq 2>/dev/null || true)"
    [[ -n "$ids" ]] || return 0
    # shellcheck disable=SC2086
    docker inspect -f '{{.Image}}' $ids 2>/dev/null | sort -u || true
}

# Full id of an image reference ("" when it is not present).
_images_id_of() {
    [[ -n "$1" ]] || return 0
    docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true
}

# "repo:tag id" for every tagged image of a repository.
_images_list_repo() {
    docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' "$1" 2>/dev/null \
        | grep -v ':<none> ' || true
}

# Split "registry:5000/org/name:tag" into its repository: everything before
# the last ':' that comes after the last '/'.
_images_repo_of() {
    local ref="$1" name="${1##*/}"
    if [[ "$name" == *:* ]]; then
        printf '%s' "${ref%:*}"
    else
        printf '%s' "$ref"
    fi
}

# Print "ref" for every tagged image of <repo> that is not kept: not in the
# keep list (refs, one per line), not the same image as a kept ref, and not
# used by a container. _images_stale <repo> <keep-refs>
_images_stale() {
    local repo="$1" keep_refs="$2" keep_ids="" in_use ref id
    while IFS= read -r ref; do
        [[ -n "$ref" ]] && keep_ids+="$(_images_id_of "$ref")"$'\n'
    done <<<"$keep_refs"
    in_use="$(_images_in_use_ids)"

    while IFS=' ' read -r ref id; do
        [[ -n "$ref" ]] || continue
        grep -qxF -- "$ref" <<<"$keep_refs" && continue
        grep -qxF -- "$id" <<<"$keep_ids" && continue
        grep -qxF -- "$id" <<<"$in_use" && continue
        printf '%s\n' "$ref"
    done < <(_images_list_repo "$repo")
}

# Remove image references (newline-separated); in a dry run, list them.
# Plain `docker rmi`, never -f: an image something still needs is refused,
# not forced out. Prints how many were removed.
_images_remove() {
    local refs="$1" ref removed=0
    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        if [[ "$SO_IMAGES_DRY_RUN" == "true" ]]; then
            printf '  would remove %s\n' "$ref" >&2
            removed=$((removed + 1))
        elif docker rmi "$ref" >/dev/null 2>&1; then
            log_debug "removed image ${ref}"
            removed=$((removed + 1))
        else
            log_warn "Could not remove ${ref}; leaving it."
        fi
    done <<<"$refs"
    printf '%s' "$removed"
}

# Old application builds: every sentinel-ops tag except the deployed one, the
# rollback target and :latest; then untagged leftovers of our own builds.
images_prune_app() {
    local keep stale n dangling
    keep="$(printf '%s\n%s\n%s:latest\n' \
        "$(state_get APP_IMAGE '')" "$(state_get PREVIOUS_APP_IMAGE '')" "$APP_IMAGE_NAME")"
    stale="$(_images_stale "$APP_IMAGE_NAME" "$keep")"
    n="$(_images_remove "$stale")"

    # Untagged images carrying our build label - only ever our own builds.
    dangling="$(docker images -q --filter dangling=true --filter "label=${APP_IMAGE_LABEL}" 2>/dev/null | sort -u || true)"
    if [[ -n "$dangling" ]]; then
        if [[ "$SO_IMAGES_DRY_RUN" == "true" ]]; then
            printf '  would remove %s untagged %s build(s)\n' "$(wc -l <<<"$dangling" | tr -d ' ')" "$APP_IMAGE_NAME" >&2
        else
            docker image prune -f --filter "label=${APP_IMAGE_LABEL}" >/dev/null 2>&1 || \
                log_warn "Could not remove untagged ${APP_IMAGE_NAME} builds."
        fi
    fi
    log_ok "Application images: $(_images_verb) ${n} old build(s); kept the deployed and rollback images"
    return 0
}

# BuildKit cache unused for longer than IMAGE_BUILD_CACHE_MAX_AGE. Build cache
# cannot be told apart by project, so this one is host-wide - but it is only
# cache: removing it never breaks anything, it only makes an unrelated build
# that has not run for a week start cold.
images_prune_build_cache() {
    local age
    age="$(images_build_cache_max_age)"
    if [[ "$SO_IMAGES_DRY_RUN" == "true" ]]; then
        printf '  would remove build cache unused for %s\n' "$age" >&2
        return 0
    fi
    if docker builder prune -f --filter "until=${age}" >/dev/null 2>&1; then
        log_ok "Build cache: removed entries unused for ${age}"
    else
        log_warn "Could not prune the build cache."
    fi
    return 0
}

# Superseded Supabase images: for each repository the compose config uses,
# every local tag the config no longer names. Repositories the config does not
# mention are left alone. Only run after a healthy `update supabase`.
images_prune_supabase() {
    local wanted repo stale="" n
    wanted="$(supabase_compose config --images 2>/dev/null | sort -u || true)"
    if [[ -z "$wanted" ]]; then
        log_warn "Could not read the Supabase compose config; no Supabase images removed."
        return 0
    fi
    while IFS= read -r repo; do
        # A digest-pinned reference says nothing about which tags are old.
        [[ -n "$repo" && "$repo" != *@* ]] || continue
        stale+="$(_images_stale "$repo" "$wanted")"$'\n'
    done < <(while IFS= read -r ref; do _images_repo_of "$ref"; printf '\n'; done <<<"$wanted" | sort -u)
    n="$(_images_remove "$stale")"
    log_ok "Supabase images: $(_images_verb) ${n} superseded image(s)"
    return 0
}

_images_verb() {
    if [[ "$SO_IMAGES_DRY_RUN" == "true" ]]; then printf 'would remove'; else printf 'removed'; fi
}

# What the image store holds now, from `docker system df`, e.g.
# "12.3GB, 8.1GB (65%) reclaimable".
images_disk_usage() {
    docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null \
        | awk -F'|' '$1 == "Images" { printf "%s, %s reclaimable", $2, $3 }' || true
}

# Status line for free space where Docker keeps its data; warns below 10%.
images_disk_status() {
    local root line avail_kb size_kb pct usage
    root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
    [[ -n "$root" && -d "$root" ]] || root="/"
    line="$(df -Pk "$root" 2>/dev/null | awk 'NR == 2 { print $2, $4 }' || true)"
    usage="$(images_disk_usage)"
    read -r size_kb avail_kb <<<"$line"
    if [[ ! "$size_kb" =~ ^[0-9]+$ || ! "$avail_kb" =~ ^[0-9]+$ ]]; then
        status_line "Disk" "warn" "Could not read free space for ${root}"
        return 0
    fi
    pct=$(( size_kb > 0 ? avail_kb * 100 / size_kb : 0 ))
    local text
    text="$(human_bytes $((avail_kb * 1024))) free (${pct}%) on ${root}${usage:+; images ${usage}}"
    if (( pct < 10 )); then
        status_line "Disk" "warn" "${text} - see: sentinel-ops disk"
    else
        status_line "Disk" "ok" "$text"
    fi
    return 0
}

# After a successful `update app`. Never fails the update.
images_cleanup_after_app_update() {
    images_cleanup_enabled || { log_info "Image cleanup is off (IMAGE_CLEANUP_ENABLED=false)."; return 0; }
    images_prune_app || true
    images_prune_build_cache || true
    return 0
}

# After a successful, healthy `update supabase`. Never fails the update.
images_cleanup_after_supabase_update() {
    images_cleanup_enabled || { log_info "Image cleanup is off (IMAGE_CLEANUP_ENABLED=false)."; return 0; }
    images_prune_supabase || true
    return 0
}
