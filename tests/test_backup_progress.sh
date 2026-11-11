#!/usr/bin/env bash
# Progress while the database dump runs, against a fake `docker exec`: the
# helpers that read dd's and pg_dump's progress, the line format, and
# _backup_dump_with_progress on and off a terminal (stdout stays clean, the
# dump is intact, pg_dump's --verbose output stays out of the log).
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/supabase.sh"
source "${ROOT}/lib/disk.sh"
source "${ROOT}/lib/database.sh"
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
export SUPABASE_DIR="$T" SO_LOG_FILE="${T}/run.log"
printf 'POSTGRES_PASSWORD=secret\nPOSTGRES_DB=postgres\n' >"${T}/.env"

# --- reading dd's and pg_dump's progress -------------------------------------
printf '1048576 bytes (1.0 MB, 1.0 MiB) copied, 1 s, 1.0 MB/s\r52428800 bytes (52 MB, 50 MiB) copied, 2 s, 26 MB/s\r' >"${T}/dd"
check "dd: the latest byte count" "52428800" "$(_backup_counted_bytes "${T}/dd")"
printf '0+60 records in\n0+60 records out\n62914560 bytes (63 MB, 60 MiB) copied, 2.4 s, 26 MB/s\n' >>"${T}/dd"
check "dd: the final summary" "62914560" "$(_backup_counted_bytes "${T}/dd")"
check "dd: no report yet" "" "$(_backup_counted_bytes "${T}/missing")"

cat >"${T}/pgdump" <<'LOG'
pg_dump: last built-in OID is 16383
pg_dump: dumping contents of table "public.agents"
pg_dump: dumping contents of table "public.audit_logs_y2026m11d10"
LOG
check "pg_dump: the table being dumped" "public.audit_logs_y2026m11d10" "$(_backup_current_table "${T}/pgdump")"
check "pg_dump: nothing yet" "" "$(_backup_current_table "${T}/missing")"

check "duration: seconds" "42s" "$(_backup_duration 42)"
check "duration: minutes" "3m05s" "$(_backup_duration 185)"
check "duration: hours" "1h02m" "$(_backup_duration 3725)"

# --- the progress line --------------------------------------------------------
check "line: all known" \
    "512.0 MiB dumped of about 2.0 GiB (25%), 80.0 MiB written, 8.5 MiB/s, 1m00s - postgres (1/2): public.audit_logs" \
    "$(_backup_progress_line 536870912 2147483648 83886080 60 'postgres (1/2)' public.audit_logs)"
check "line: past the estimate stays below 100%" \
    "3.0 GiB dumped of about 2.0 GiB (99%), 1.0 GiB written, 1.0 GiB/s, 3s" \
    "$(_backup_progress_line 3221225472 2147483648 1073741824 3 '' '')"
check "line: no estimate" \
    "1.0 MiB dumped, 512.0 KiB written, 1.0 MiB/s, 1s - postgres (1/1)" \
    "$(_backup_progress_line 1048576 '' 524288 1 'postgres (1/1)' '')"
check "line: no byte count (dd without status=progress)" \
    "512.0 KiB written, 10s - postgres (1/1): public.x" \
    "$(_backup_progress_line '' 2147483648 524288 10 'postgres (1/1)' public.x)"

# --- the dump, against a fake docker ------------------------------------------
# Two databases; pg_dump writes a COPY block slowly and --verbose to stderr.
docker() {
    local args=("$@") a sql="$*"
    case " ${args[*]} " in
        *" pg_dumpall "*) printf -- '-- roles\n' ;;
        *" pg_dump "*)
            local db="" v="false"
            for ((a = 0; a < ${#args[@]}; a++)); do
                [[ "${args[a]}" == "-d" ]] && db="${args[a+1]}"
                [[ "${args[a]}" == "--verbose" ]] && v="true"
            done
            [[ "$v" == "true" ]] && printf 'pg_dump: dumping contents of table "public.big_%s"\n' "$db" >&2
            printf 'COPY public.big_%s (id) FROM stdin;\n' "$db"
            sleep 2
            seq 1 20000
            printf '\\.\n'
            ;;
        *" psql "*)
            case "$sql" in
                *pg_database*) printf 'postgres\nother\n' ;;
                *pg_table_size*) printf 'public.big|200000\nauth.audit_log_entries|999999999\n' ;;
            esac
            ;;
    esac
    return 0
}

out="$(BACKUP_PROGRESS_TTY=false BACKUP_PROGRESS_INTERVAL=1 _backup_dump_with_progress cid "${T}/db.sql.gz" 2>"${T}/err")"; rc=$?
check "dump: succeeds" "0" "$rc"
check "dump: nothing on stdout (callers read the backup path from it)" "" "$out"
check "dump: both databases, complete" "2 40000" \
    "$(gzip -dc "${T}/db.sql.gz" | grep -c '^COPY') $(gzip -dc "${T}/db.sql.gz" | grep -cE '^[0-9]+$')"
check "dump: progress lines while it runs" "true" \
    "$([[ "$(grep -c 'dumped of about' "${T}/err")" -ge 1 ]] && echo true || echo false)"
check "dump: names the table" "true" "$(grep -q 'public.big_' "${T}/err" && echo true || echo false)"
check "dump: summary at the end" "1" "$(grep -c 'Dumped .* in .* compressed' "${T}/err")"
check "dump: pg_dump --verbose kept out of the log" "0" "$(grep -c 'dumping contents' "$SO_LOG_FILE" 2>/dev/null || true)"
check "dump: no terminal control codes off a terminal" "0" "$(grep -c $'\033' "${T}/err" || true)"

out="$(BACKUP_PROGRESS_TTY=true _backup_dump_with_progress cid "${T}/db2.sql.gz" 2>"${T}/err")"; rc=$?
check "terminal: succeeds" "0" "$rc"
check "terminal: redraws one line in place" "true" "$(grep -q $'\r\033\[K' "${T}/err" && echo true || echo false)"

# A failure in the dump is still a failure.
docker() { case " $* " in *" psql "*) printf 'postgres\n' ;; *" pg_dump "*) printf 'pg_dump: error: connection failed\n' >&2; return 1 ;; esac; return 0; }
BACKUP_PROGRESS_TTY=false _backup_dump_with_progress cid "${T}/bad.sql.gz" >/dev/null 2>"${T}/err"; rc=$?
check "failure: returns non-zero" "true" "$([[ "$rc" -ne 0 ]] && echo true || echo false)"
check "failure: shows pg_dump's error" "1" "$(grep -c 'connection failed' "${T}/err")"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
