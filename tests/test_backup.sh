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

# --- what the dump leaves out --------------------------------------------
BACKUP_EXCLUDE_DATA=""; BACKUP_INCLUDE_LOG_DATA="false"
entries="$(backup_exclude_data_entries)"
check "Logflare's log store is left out by default" "1" \
    "$(printf '%s\n' "$entries" | grep -cxF '_supabase:_analytics.*')"
check "auth's audit log is left out by default" "1" \
    "$(printf '%s\n' "$entries" | grep -cxF 'postgres:auth.audit_log_entries')"

_ex() { _backup_table_excluded "$1" "$2" 2>/dev/null && printf 'out' || printf 'in'; }
check "a Logflare table is excluded"              "out" "$(_ex _supabase _analytics.log_events_8e2f)"
check "a realtime partition is excluded"          "out" "$(_ex postgres realtime.messages_2026_11_10)"
check "a pgmq archive is excluded"                "out" "$(_ex postgres pgmq.a_backup_table_queue)"
check "a derived app table is excluded"           "out" "$(_ex postgres public.agent_power_windows)"
check "pgmq queues themselves are kept"           "in"  "$(_ex postgres pgmq.q_backup_table_queue)"
check "audit_logs is kept (compliance evidence)"  "in"  "$(_ex postgres public.audit_logs)"
check "user_activity_logs is kept"                "in"  "$(_ex postgres public.user_activity_logs)"
check "command_audit_logs is kept"                "in"  "$(_ex postgres public.command_audit_logs)"
check "auth.users is kept"                        "in"  "$(_ex postgres auth.users)"
check "vault.secrets is kept"                     "in"  "$(_ex postgres vault.secrets)"
check "the MDM CA is kept"                        "in"  "$(_ex postgres public.mdm_certificate_authorities)"
check "agents is kept (no prefix match)"          "in"  "$(_ex postgres public.agents)"
check "patterns are per database"                 "in"  "$(_ex postgres _analytics.log_events_8e2f)"

check "pg_dump flags for _supabase" "--exclude-table-data=_analytics.*" "$(_backup_exclude_args _supabase)"
check "no flags for a database with no exclusions" "" "$(_backup_exclude_args other_db)"

BACKUP_EXCLUDE_DATA="postgres:public.alert_events bogus postgres:public.dlp_events"
check "BACKUP_EXCLUDE_DATA adds to the list"       "out" "$(_ex postgres public.alert_events)"
check "and keeps the built-in list"                "out" "$(_ex postgres auth.audit_log_entries)"
check "a malformed entry is ignored"               "0" \
    "$(backup_exclude_data_entries 2>/dev/null | grep -cx 'bogus')"
check "a malformed entry is reported" "1" \
    "$(backup_exclude_data_entries 2>&1 >/dev/null | grep -c "bogus")"
BACKUP_EXCLUDE_DATA=""

BACKUP_INCLUDE_LOG_DATA="true"
check "BACKUP_INCLUDE_LOG_DATA=true leaves nothing out" "" "$(backup_exclude_data_entries)"
check "and passes pg_dump no flags"                    "" "$(_backup_exclude_args postgres)"
BACKUP_INCLUDE_LOG_DATA="false"

# --- the dump stream, against a fake docker --------------------------------
DOCKER_LOG="${T}/docker-calls"
DUMP_FAIL_DB=""
docker() {
    local a args=("$@") db="" tool=""
    for a in "${args[@]}"; do
        case "$a" in pg_dumpall|pg_dump|psql) tool="$a" ;; esac
    done
    for ((a = 0; a < ${#args[@]}; a++)); do
        [[ "${args[a]}" == "-d" ]] && db="${args[a+1]}"
    done
    printf '%s\n' "$*" >>"$DOCKER_LOG"
    case "$tool" in
        psql)       printf 'postgres\r\n_supabase\r\n' ;;
        pg_dumpall) printf -- '-- roles\n' ;;
        pg_dump)    [[ "$db" == "$DUMP_FAIL_DB" ]] && return 1
                    printf -- '-- dump of %s\n' "$db" ;;
    esac
}
_db_pass() { printf 'pw'; }
_db_user() { printf 'postgres'; }
_db_name() { printf 'postgres'; }

: >"$DOCKER_LOG"
stream="$(_backup_dump_stream cid)"
check "the dump starts with the roles"  "-- roles" "$(printf '%s\n' "$stream" | head -n1)"
check "each database follows a \\connect" '\connect "postgres"|-- dump of postgres|\connect "_supabase"|-- dump of _supabase' \
    "$(printf '%s\n' "$stream" | grep -v '^$' | tail -n4 | tr '\n' '|' | sed 's/|$//')"
check "roles only, from pg_dumpall" "1" "$(grep -c 'pg_dumpall -U postgres --globals-only --clean --if-exists' "$DOCKER_LOG")"
check "pg_dump gets the _supabase exclusions" "1" \
    "$(grep 'pg_dump -U postgres -d _supabase' "$DOCKER_LOG" | grep -c -- '--exclude-table-data=_analytics.\*')"
check "pg_dump gets the postgres exclusions" "1" \
    "$(grep 'pg_dump -U postgres -d postgres' "$DOCKER_LOG" | grep -c -- '--exclude-table-data=auth.audit_log_entries')"
check "no database is dumped with --create" "0" "$(grep -c -- '--create' "$DOCKER_LOG")"

DUMP_FAIL_DB="_supabase"
_backup_dump_stream cid >/dev/null 2>&1
check "a failed pg_dump fails the stream" "1" "$?"
DUMP_FAIL_DB=""

# The compressed dump round-trips, and pipefail catches a failure upstream.
D7="${T}/dump"
mkdir -p "$D7"
( set -o pipefail; _backup_dump_stream cid | _backup_gzip >"${D7}/${BACKUP_DB_FILE}" )
check "the dump is written compressed" "$(_backup_dump_stream cid)" "$(gzip -dc "${D7}/${BACKUP_DB_FILE}")"
DUMP_FAIL_DB="postgres"
( set -o pipefail; _backup_dump_stream cid | _backup_gzip >"${D7}/failed.gz" ) 2>/dev/null
check "a failed dump fails the pipeline" "1" "$?"
DUMP_FAIL_DB=""

# --- dump file: new name, legacy name, checksums ----------------------------
check "the backup's dump is the compressed one" "${D7}/${BACKUP_DB_FILE}" "$(_backup_db_file "$D7")"
check "_backup_db_cat decompresses" "-- roles" "$(_backup_db_cat "${D7}/${BACKUP_DB_FILE}" | head -n1)"
_backup_checksum_write "$D7"
check "checksums cover the compressed dump" "1" "$(grep -c " ${BACKUP_DB_FILE}\$" "${D7}/checksums.txt")"
_backup_checksum_verify "$D7" >/dev/null 2>&1
check "and verify" "0" "$?"
check "a legacy backup's dump is database.sql" "${D3}/database.sql" "$(_backup_db_file "$D3")"
check "_backup_db_cat passes plain SQL through" "sql" "$(_backup_db_cat "${D3}/database.sql")"
_backup_db_file "${T}/nowhere" >/dev/null
check "no dump at all is an error" "1" "$?"

# --- metadata records what was left out ---------------------------------
D8="${T}/meta-excluded"
mkdir -p "$D8"
printf 'x' | gzip -c >"${D8}/${BACKUP_DB_FILE}"
_backup_metadata_write "$D8" "unit-test" full
check "metadata lists the excluded table data" "1" \
    "$(env_get "${D8}/metadata.txt" excluded_data | tr ' ' '\n' | grep -cxF '_supabase:_analytics.*')"
check "metadata lists the excluded buckets" "backups" "$(env_get "${D8}/metadata.txt" excluded_storage_buckets)"
_backup_metadata_write "$D8" "unit-test" db
check "a db backup records no buckets" "" "$(env_get "${D8}/metadata.txt" excluded_storage_buckets 2>/dev/null)"

# --- the size estimate leaves the excluded data out -------------------------
_backup_table_sizes() {
    case "$2" in
        _supabase) printf '_analytics.log_events_1|700\n_analytics.sources|100\npublic.keep|50\n' ;;
        postgres)  printf 'public.audit_logs|300\nauth.audit_log_entries|20\npublic.agents|10\n' ;;
    esac
}
check "excluded bytes in _supabase" "800" "$(_backup_excluded_db_bytes cid _supabase)"
check "excluded bytes in postgres"  "20"  "$(_backup_excluded_db_bytes cid postgres)"
BACKUP_INCLUDE_LOG_DATA="true"
check "nothing excluded when log data is included" "0" "$(_backup_excluded_db_bytes cid _supabase)"
BACKUP_INCLUDE_LOG_DATA="false"

# --- Storage: the in-app backups bucket stays out ----------------------------
SUPABASE_DIR="${T}/supabase"
VOL="${SUPABASE_DIR}/volumes/storage/stub/stub"
mkdir -p "${VOL}/backups/2026-11-01" "${VOL}/app-installers/x/backups"
printf 'dump\n' >"${VOL}/backups/2026-11-01/part-0001.jsonl"
printf 'msi\n'  >"${VOL}/app-installers/x/backups/setup.msi"
printf 'msi\n'  >"${VOL}/app-installers/agent.msi"
D9="${T}/storage-archive"
mkdir -p "$D9"
mapfile -t sargs < <(_backup_storage_exclude_args)
_backup_archive "$D9" storage.tar.gz "${sargs[@]}" -C "${SUPABASE_DIR}/volumes" storage >/dev/null 2>&1
listing="$(tar -tzf "${D9}/storage.tar.gz")"
check "the backups bucket is not archived" "0" \
    "$(printf '%s\n' "$listing" | grep -c '^storage/stub/stub/backups')"
check "other buckets are"                  "1" \
    "$(printf '%s\n' "$listing" | grep -cx 'storage/stub/stub/app-installers/agent.msi')"
check "a folder named backups inside another bucket is kept" "1" \
    "$(printf '%s\n' "$listing" | grep -cx 'storage/stub/stub/app-installers/x/backups/setup.msi')"
printf '%s' "$((5*G))" >"${VOL}/backups/size"
check "the bucket's size is left out of the estimate" "$((5*G))" "$(_backup_storage_excluded_bytes)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
