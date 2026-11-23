#!/usr/bin/env bash
# lib/repair.sh - validate and auto-fix known-bad supabase/.env formatting and
# values.
#
# Deliberately narrow: it fixes mechanical mistakes (CRLF, stray whitespace
# around "=", duplicate keys, a trailing slash on a URL) that silently corrupt
# a value Compose or gotrue read literally - the same class of bug as the
# Azure redirect URI (wiki: Azure-AD-Sign-In, azure_patch_compose() in lib/azure.sh).
# It never second-guesses a real configuration choice (a custom domain, a
# disabled provider) - those stay exactly as the operator set them. Restarting
# the affected containers so a fix actually takes effect is the caller's job;
# see lib/commands/repair.sh.
# shellcheck shell=bash

# Keys whose value must not carry a trailing slash - Kong and gotrue compare
# them byte-for-byte against redirect URIs and CORS origins.
_REPAIR_NO_TRAILING_SLASH_KEYS=(SUPABASE_PUBLIC_URL API_EXTERNAL_URL SITE_URL)

# Names that appear more than once as a KEY= assignment in an env file.
_env_duplicate_keys() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$file" | sed 's/=$//' | sort | uniq -d
}

# Print a human-readable list of problems found in an env file, one per line,
# without modifying it. No output means the file is clean.
env_lint() {
    local file="$1"
    [[ -f "$file" ]] || { printf 'missing: %s\n' "$file"; return 0; }

    # -U: read in binary mode so a CRLF is not silently normalized away before
    # grep ever sees it (matters on Git-for-Windows' grep; harmless on Linux).
    grep -qU $'\r$' "$file" && printf 'CRLF line endings\n'
    grep -qE '[[:space:]]+$' "$file" && printf 'trailing whitespace on one or more lines\n'
    grep -qE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+=|^[A-Za-z_][A-Za-z0-9_]*=[[:space:]]' "$file" \
        && printf 'whitespace around one or more "=" assignments\n'

    local dupes
    dupes="$(_env_duplicate_keys "$file")"
    if [[ -n "$dupes" ]]; then
        while IFS= read -r k; do
            printf 'duplicate key: %s (last occurrence wins; earlier ones are dead weight)\n' "$k"
        done <<<"$dupes"
    fi

    local key val
    for key in "${_REPAIR_NO_TRAILING_SLASH_KEYS[@]}"; do
        val="$(env_get "$file" "$key" 2>/dev/null || true)"
        [[ "$val" == */ ]] && printf '%s has a trailing slash (%s)\n' "$key" "$val"
    done
    return 0
}

# Apply every known-safe fix to an env file in place. Echoes nothing; returns
# 0 if the file was changed, 1 if it was already clean. Writes a
# .bak-<timestamp> copy first when a change is about to be made - this is a
# mechanical rewrite, not a review, so keep a way back.
env_repair_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    local tmp
    tmp="$(mktemp)"
    # CRLF -> LF, trim trailing whitespace, then tighten "KEY = value" down to
    # "KEY=value". The anchored KEY pattern never matches a "#" comment or a
    # blank/indented line, so only real assignments are touched.
    sed -E 's/\r$//; s/[[:space:]]+$//' "$file" \
        | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*/\1=/' \
        >"$tmp"

    # Duplicate keys: keep the last occurrence, matching what Docker Compose's
    # own .env substitution honors, and drop the earlier, now-misleading ones.
    local deduped
    deduped="$(mktemp)"
    tac "$tmp" | awk '
        /^[A-Za-z_][A-Za-z0-9_]*=/ {
            key = $0; sub(/=.*/, "", key)
            if (seen[key]++) next
        }
        { print }
    ' | tac >"$deduped"
    mv "$deduped" "$tmp"

    local changed="false" backed_up="false"
    if ! cmp -s "$tmp" "$file"; then
        cp -p "$file" "${file}.bak-$(timestamp)" 2>/dev/null || true
        backed_up="true"
        changed="true"
        cat "$tmp" >"$file"
    fi
    rm -f "$tmp"

    # Known-bad values: a trailing slash on a URL gotrue/Kong compare exactly.
    local key val
    for key in "${_REPAIR_NO_TRAILING_SLASH_KEYS[@]}"; do
        val="$(env_get "$file" "$key" 2>/dev/null || true)"
        if [[ "$val" == */ ]]; then
            [[ "$backed_up" == "true" ]] || { cp -p "$file" "${file}.bak-$(timestamp)" 2>/dev/null; backed_up="true"; }
            env_set "$file" "$key" "$(strip_trailing_slash "$val")"
            changed="true"
        fi
    done

    [[ "$changed" == "true" ]]
}
