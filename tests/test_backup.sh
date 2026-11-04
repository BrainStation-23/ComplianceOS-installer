#!/usr/bin/env bash
# Exercise the local backup logic in isolation from Docker: retention,
# checksums, metadata and listing. backup_create() itself (which shells out
# to `docker exec` for pg_dumpall) is Docker-invoking and not tested here
# - see the manual verification steps in docs/BACKUPS.md - but everything it
# delegates to for retention, free space, archiving, integrity and listing is
# asserted directly, the same split _domain_apply_settings/_domain_set use.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/supabase.sh"
source "${ROOT}/lib/disk.sh"
source "${ROOT}/lib/backup.sh"

pass=0; fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
    else
        printf 'FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
        fail=$((fail+1))
    fi
}

T="$(mktemp -d)"
config_set_paths "${T}/root"
config_make_dirs

_build_backups() {
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    local stamp
    for stamp in 2026-01-01-000000 2026-01-02-000000 2026-01-03-000000 2026-01-04-000000 2026-01-05-000000; do
        mkdir -p "${BACKUP_DIR}/${stamp}"
        printf 'sql\n' >"${BACKUP_DIR}/${stamp}/database.sql"
    done
}
_remaining() {
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | LC_ALL=C sort | xargs -n1 basename | tr '\n' ' ' | sed 's/ $//'
}

# --- backup_prune_local: keep only the N most recent cycles -----------------
BACKUP_RETENTION_COUNT=3
_build_backups
backup_prune_local
check "prune keeps only the most recent N" \
    "2026-01-03-000000 2026-01-04-000000 2026-01-05-000000" "$(_remaining)"

BACKUP_RETENTION_COUNT=10
_build_backups
backup_prune_local
check "prune is a no-op under the limit" \
    "2026-01-01-000000 2026-01-02-000000 2026-01-03-000000 2026-01-04-000000 2026-01-05-000000" \
    "$(_remaining)"

# --- backup_latest -----------------------------------------------------------
_build_backups
check "backup_latest returns the newest" "${BACKUP_DIR}/2026-01-05-000000" "$(backup_latest)"

# --- checksums: write then verify round-trip, and catch corruption ----------
D="${T}/single"
mkdir -p "$D"
printf 'hello world\n' >"${D}/database.sql"
printf 'storage data\n' >"${D}/storage.tar.gz"
_backup_checksum_write "$D"
check "checksums.txt has one line per backed-up file" "2" "$(wc -l <"${D}/checksums.txt" | tr -d ' ')"

_backup_checksum_verify "$D" >/dev/null 2>&1
check "verify passes on an untouched backup" "0" "$?"

printf 'corrupted\n' >>"${D}/database.sql"
_backup_checksum_verify "$D" >/dev/null 2>&1
check "verify fails on a corrupted file" "1" "$?"

D2="${T}/missing-checksums"
mkdir -p "$D2"
_backup_checksum_verify "$D2" >/dev/null 2>&1
check "verify fails with no checksums.txt" "1" "$?"

# --- metadata -----------------------------------------------------------
D3="${T}/meta"
mkdir -p "$D3"
printf 'sql\n' >"${D3}/database.sql"
_backup_metadata_write "$D3" "unit-test"
check "metadata records the reason" "unit-test" "$(env_get "${D3}/metadata.txt" reason)"
check "metadata records scope=full"  "full"      "$(env_get "${D3}/metadata.txt" scope)"

# --- listing: newest first, carries each backup's reason --------------------
_build_backups
printf 'reason=oldest\n' >"${BACKUP_DIR}/2026-01-01-000000/metadata.txt"
printf 'reason=newest\n' >"${BACKUP_DIR}/2026-01-05-000000/metadata.txt"
entries="$(backup_list_entries)"
check "list is newest first"    "${BACKUP_DIR}/2026-01-05-000000" "$(printf '%s\n' "$entries" | head -n1 | cut -d'|' -f1)"
check "list carries the reason" "newest"                          "$(printf '%s\n' "$entries" | head -n1 | cut -d'|' -f3)"
check "list has all five entries" "5"                             "$(printf '%s\n' "$entries" | grep -c '.')"
printf 'scope=db\n' >>"${BACKUP_DIR}/2026-01-05-000000/metadata.txt"
entries="$(backup_list_entries)"
check "list carries the scope"            "db"   "$(printf '%s\n' "$entries" | head -n1 | cut -d'|' -f4)"
check "a backup without a scope is full"  "full" "$(printf '%s\n' "$entries" | tail -n1 | cut -d'|' -f4)"

# --- scopes ----------------------------------------------------------------
D4="${T}/meta-db"
mkdir -p "$D4"
printf 'sql\n' >"${D4}/database.sql"
_backup_metadata_write "$D4" "pre-app-update" db
check "metadata records scope=db"       "db"   "$(backup_scope "$D4")"
check "no metadata at all reads as full" "full" "$(backup_scope "${T}/nowhere")"

# --- retention: count, size, and what is never removed ----------------------
# Sizes are read from a "size" file in each backup, so the size limit can be
# exercised with GiB-scale numbers and no GiB-scale files.
disk_used_bytes() { cat "${1}/size" 2>/dev/null || printf '0'; }
_build_scoped() {   # _build_scoped "<scope>:<size>" ... oldest first
    rm -rf "$BACKUP_DIR"; mkdir -p "$BACKUP_DIR"
    local spec i=1 dir
    for spec in "$@"; do
        dir="${BACKUP_DIR}/2026-02-0${i}-000000"
        mkdir -p "$dir"
        printf 'scope=%s\n' "${spec%%:*}" >"${dir}/metadata.txt"
        printf '%s' "${spec#*:}" >"${dir}/size"
        i=$((i + 1))
    done
}
_names() { xargs -rn1 basename | tr '\n' ' ' | sed 's/ $//'; }

BACKUP_RETENTION_MAX_GB=0
BACKUP_RETENTION_COUNT=2
_build_scoped full:1 db:1 db:1 db:1
check "count: the newest full backup outlives a run of db-only ones (one over the count)" \
    "2026-02-02-000000" "$(_backup_prune_candidates | _names)"

BACKUP_RETENTION_COUNT=10
BACKUP_RETENTION_MAX_GB=10
G=1073741824
_build_scoped full:$((6*G)) full:$((6*G)) db:$((1*G)) db:$((1*G))
check "size: oldest go first until the rest fit" \
    "2026-02-01-000000" "$(_backup_prune_candidates | _names)"

BACKUP_RETENTION_MAX_GB=1
_build_scoped full:$((4*G)) db:$((1*G)) full:$((3*G)) db:$((2*G))
check "size: the newest and newest full stay even over the limit" \
    "2026-02-01-000000 2026-02-02-000000" "$(_backup_prune_candidates | _names)"

BACKUP_RETENTION_MAX_GB=0
_build_scoped full:$((40*G)) full:$((40*G))
check "size: 0 means no size limit" "" "$(_backup_prune_candidates | _names)"

BACKUP_RETENTION_MAX_GB=1
BACKUP_RETENTION_COUNT=2
_build_scoped full:$((2*G)) db:1 db:1 db:1
backup_prune_local --dry-run >/dev/null 2>&1
check "a dry run removes nothing" "4" "$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
backup_prune_local >/dev/null 2>&1
check "pruning removes the candidates" "2026-02-01-000000 2026-02-04-000000" \
    "$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort | _names)"
check "pruning logs nothing to stdout (backup_create prints its path there)" "" \
    "$(_build_scoped full:1 db:1 db:1 db:1; backup_prune_local 2>/dev/null)"

BACKUP_RETENTION_COUNT="ten"
check "a non-numeric count falls back to 10" "10" "$(backup_retention_count 2>/dev/null)"
BACKUP_RETENTION_COUNT=10

# --- the size limit setting --------------------------------------------------
disk_size_bytes() { printf '%s' "$((100*G))"; }
BACKUP_RETENTION_MAX_GB=0;    check "max 0 is no limit"          ""             "$(backup_retention_max_bytes)"
BACKUP_RETENTION_MAX_GB=3;    check "max in GiB"                 "$((3*G))"     "$(backup_retention_max_bytes)"
BACKUP_RETENTION_MAX_GB=auto; check "auto is a fifth of the disk" "$((20*G))"   "$(backup_retention_max_bytes)"
BACKUP_RETENTION_MAX_GB=lots; check "junk falls back to auto"    "$((20*G))"    "$(backup_retention_max_bytes 2>/dev/null)"
disk_size_bytes() { :; }
BACKUP_RETENTION_MAX_GB=auto; check "auto with an unreadable disk is no limit" "" "$(backup_retention_max_bytes)"

# --- free space --------------------------------------------------------------
_backup_fits $((10*G)) $((20*G));       check "fits with room to spare"       "0" "$?"
_backup_fits $((10*G)) $((11*G));       check "refused without the 10% margin and reserve" "1" "$?"
_backup_fits 0 $((G - 1));              check "refused when the reserve alone is not free" "1" "$?"

# --- a failed archive fails the backup ------------------------------------
D5="${T}/archive-fail"
mkdir -p "$D5"
printf 'sql\n' >"${D5}/database.sql"
_backup_archive "$D5" storage.tar.gz -C "${T}" does-not-exist >/dev/null 2>&1
check "a failed archive returns non-zero"            "1" "$?"
check "and leaves no partial backup behind"          "0" "$([[ -d "$D5" ]] && printf 1 || printf 0)"
D6="${T}/archive-ok"
mkdir -p "$D6" "${T}/payload"
printf 'x\n' >"${T}/payload/file"
_backup_archive "$D6" storage.tar.gz -C "${T}" payload >/dev/null 2>&1
check "a good archive is kept"                       "1" "$([[ -s "${D6}/storage.tar.gz" ]] && printf 1 || printf 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
