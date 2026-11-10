#!/usr/bin/env bash
# Exercise lib/database.sh's session_replication_role grant against a fake
# `docker exec psql`, without Docker or a live Supabase stack. The fake keeps
# one bit of state - whether the grant exists - and records who ran what.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/database.sh"

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
export SUPABASE_DIR="$T"
printf 'POSTGRES_PASSWORD=secret\nPOSTGRES_DB=postgres\n' >"${T}/.env"
CALLS="${T}/calls"

_db_container() { printf 'cid'; }

# Fake state, reset per scenario. The grant lives in a file because db_psql
# runs at the end of a pipeline, in a subshell.
FAKE_VERSION=150008
FAKE_GRANTED="${T}/granted"
FAKE_GRANT_FAILS="false"

# docker exec -i -e PGPASSWORD=... cid psql -U <user> -d <db> ... ; SQL on stdin
docker() {
    local user="" a
    local args=("$@")
    for ((a = 0; a < ${#args[@]}; a++)); do
        [[ "${args[a]}" == "-U" ]] && user="${args[a+1]}"
    done
    local sql
    sql="$(cat)"
    printf '%s|%s\n' "$user" "$sql" >>"$CALLS"
    case "$sql" in
        "SHOW server_version_num;") printf '%s\n' "$FAKE_VERSION" ;;
        *has_parameter_privilege*)  [[ -e "$FAKE_GRANTED" ]] && printf 't\n' || printf 'f\n' ;;
        GRANT*)
            [[ "$user" == "supabase_admin" && "$FAKE_GRANT_FAILS" != "true" ]] || return 1
            : >"$FAKE_GRANTED"
            ;;
    esac
    return 0
}

_reset() {
    : >"$CALLS"
    rm -f "$FAKE_GRANTED"
    FAKE_VERSION=150008; FAKE_GRANT_FAILS="false"
}

grant_calls() { grep -c '|GRANT' "$CALLS"; }

# --- missing grant: granted once, as the superuser, to the migration role ---
_reset
check "status before grant" "false" "$(db_replication_role_status)"
db_ensure_replication_role_grant >/dev/null 2>&1; rc="$?"
check "missing grant: succeeds" "0" "$rc"
check "missing grant: one GRANT issued" "1" "$(grant_calls)"
check "missing grant: GRANT runs as supabase_admin" "supabase_admin" \
    "$(grep '|GRANT' "$CALLS" | cut -d'|' -f1)"
check "missing grant: grantee is the migration role" \
    'GRANT SET ON PARAMETER session_replication_role TO "postgres";' \
    "$(grep '|GRANT' "$CALLS" | cut -d'|' -f2-)"
check "missing grant: checks run as the migration role" "0" \
    "$(grep -v '|GRANT' "$CALLS" | grep -vc '^postgres|')"
check "status after grant" "true" "$(db_replication_role_status)"

# --- already granted: nothing issued (idempotent) ---------------------------
: >"$CALLS"
db_ensure_replication_role_grant >/dev/null 2>&1; rc="$?"
check "already granted: succeeds" "0" "$rc"
check "already granted: no GRANT issued" "0" "$(grant_calls)"

# --- a custom POSTGRES_USER is the grantee, and is quoted ------------------
_reset
printf 'POSTGRES_PASSWORD=secret\nPOSTGRES_USER=app"user\n' >"${T}/.env"
db_ensure_replication_role_grant >/dev/null 2>&1
check "custom user: identifier quoted" \
    'GRANT SET ON PARAMETER session_replication_role TO "app""user";' \
    "$(grep '|GRANT' "$CALLS" | cut -d'|' -f2-)"
printf 'POSTGRES_PASSWORD=secret\nPOSTGRES_DB=postgres\n' >"${T}/.env"

# --- the GRANT fails: reported, not fatal-silent ---------------------------
_reset
FAKE_GRANT_FAILS="true"
out="$(db_ensure_replication_role_grant 2>&1)"; rc="$?"
check "grant fails: returns non-zero" "1" "$rc"
check "grant fails: warns that restore will fail" "1" \
    "$(printf '%s\n' "$out" | grep -c 'backup from inside the application will fail')"

# --- PostgreSQL 14: no per-parameter grants, nothing attempted --------------
_reset
FAKE_VERSION=140011
check "pg14: status unsupported" "unsupported" "$(db_replication_role_status)"
db_ensure_replication_role_grant >/dev/null 2>&1; rc="$?"
check "pg14: returns non-zero" "1" "$rc"
check "pg14: no GRANT attempted" "0" "$(grant_calls)"

# --- unreadable version: cannot check, nothing attempted --------------------
_reset
FAKE_VERSION="garbage"
db_ensure_replication_role_grant >/dev/null 2>&1; rc="$?"
check "unreadable version: returns non-zero" "1" "$rc"
check "unreadable version: no GRANT attempted" "0" "$(grant_calls)"

# --- migration failure reports ------------------------------------------------
# psql output below is verbatim from psql 15 run with -f - -b -v VERBOSITY=verbose.
MIG="${T}/20240102000000_fk.sql"
cat >"$MIG" <<'SQL'
-- add posts
CREATE TABLE posts (
    id int,
    author int REFERENCES authors(id),
    body text
);
SQL
cat >"${T}/out" <<'OUT'
psql:<stdin>:3: NOTICE:  something harmless
psql:<stdin>:6: ERROR:  42P01: relation "authors" does not exist
LOCATION:  RangeVarGetRelidExtended, namespace.c:433
psql:<stdin>:6: STATEMENT:  CREATE TABLE posts (
    id int,
    author int REFERENCES authors(id),
    body text
);
OUT
out="$(_migration_report_failure "$MIG" "${T}/out" 3 2>&1)"
check "report: shows the error with SQLSTATE" "1" \
    "$(printf '%s\n' "$out" | grep -c 'ERROR:  42P01: relation "authors" does not exist')"
check "report: locates the statement in the file" "1" \
    "$(printf '%s\n' "$out" | grep -c 'supabase/migrations/20240102000000_fk.sql, statement on lines 2-6')"
check "report: prints the source lines" "1" \
    "$(printf '%s\n' "$out" | grep -c '4 |     author int REFERENCES authors(id),')"
check "report: hints at migration order" "1" "$(printf '%s\n' "$out" | grep -c 'Hint (42P01)')"
check "report: drops LOCATION and NOTICE noise" "0" "$(printf '%s\n' "$out" | grep -cE 'LOCATION|NOTICE')"

MIG="${T}/20240104000000_syntax.sql"
printf 'CREATE TABLE x (\n    a int,\n    b int\n    c int\n);\n' >"$MIG"
cat >"${T}/out" <<'OUT'
psql:<stdin>:5: ERROR:  42601: syntax error at or near "c"
LINE 4:     c int
            ^
LOCATION:  scanner_yyerror, scan.l:1188
psql:<stdin>:5: STATEMENT:  CREATE TABLE x (
    a int,
    b int
    c int
);
OUT
out="$(_migration_report_failure "$MIG" "${T}/out" 3 2>&1)"
check "report: LINE n points at the exact file line" "1" \
    "$(printf '%s\n' "$out" | grep -c '20240104000000_syntax.sql:4 (statement on lines 1-5)')"
check "report: marks that line" "1" "$(printf '%s\n' "$out" | grep -cE '^ +> +4 \|     c int')"

MIG="${T}/20240106000000_nosemi.sql"
printf 'CREATE TABLE users (id int)' >"$MIG"
cat >"${T}/out" <<'OUT'
psql:<stdin>:2: ERROR:  42601: syntax error at or near "INSERT"
LINE 2: INSERT INTO supabase_migrations.schema_migrations (version, ...
        ^
psql:<stdin>:2: STATEMENT:  CREATE TABLE users (id int)
INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES ('20240106000000', 'nosemi');
OUT
out="$(_migration_report_failure "$MIG" "${T}/out" 3 2>&1)"
check "report: missing final semicolon is named" "1" \
    "$(printf '%s\n' "$out" | grep -c 'missing its terminating semicolon')"

printf 'Error response from daemon: No such container: abc\n' >"${T}/out"
out="$(_migration_report_failure "$MIG" "${T}/out" 1 2>&1)"
check "report: docker failure explained" "1" "$(printf '%s\n' "$out" | grep -c 'Docker could not run psql')"
check "report: docker message shown" "1" "$(printf '%s\n' "$out" | grep -c 'No such container')"

check "duplicate versions found" "20240101000000" \
    "$(_migration_duplicate_versions /m/20240101000000_a.sql /m/20240101000000_b.sql /m/20240102000000_c.sql)"
check "no duplicate versions" "" \
    "$(_migration_duplicate_versions /m/20240101000000_a.sql /m/20240102000000_c.sql)"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
