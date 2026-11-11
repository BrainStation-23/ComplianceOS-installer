#!/usr/bin/env bash
# deploy_migrations with background jobs and locks (#33), against a fake
# `docker exec psql`: pg_cron jobs are paused for the migrations and resumed
# afterwards (also after a failure, and after a killed run), and a migration
# that times out on a lock is rolled back and retried.
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
export SUPABASE_DIR="$T" STATE_DIR="${T}/state" APP_DIR="${T}/app"
MIGS="${APP_DIR}/supabase/migrations"
mkdir -p "$MIGS"
printf 'POSTGRES_PASSWORD=secret\nPOSTGRES_DB=postgres\n' >"${T}/.env"

_db_container() { printf 'cid'; }
sleep() { printf '%s\n' "$1" >>"${T}/sleeps"; }

# Fake state lives in files: db_psql runs at the end of pipelines (subshells).
JOBS="${T}/jobs"          # "<jobid> <t|f>" per line
APPLIED="${T}/applied"    # recorded versions
ATTEMPTS="${T}/attempts"  # one line per migration transaction: "<pgoptions>|<active jobs at the time>"
CRON_OPS="${T}/cron_ops"  # "<user>|pause|resume"
LOCK_FAILS="${T}/lock_fails"  # how many more migration attempts fail with 55P03
FAKE_CRON="true"
RUNNING="${T}/running"    # what _cron_running_jobs returns; one line per check ("always:" repeats)
FAKE_SYNTAX_ERROR="false"

_active_jobs() { awk '$2 == "t" { print $1 }' "$JOBS" | paste -sd, -; }
_set_jobs() {  # _set_jobs <t|f> <comma ids>
    local state="$1" id
    for id in ${2//,/ }; do
        awk -v id="$id" -v s="$state" '$1 == id { $2 = s } { print }' "$JOBS" >"${JOBS}.tmp" && mv "${JOBS}.tmp" "$JOBS"
    done
}

docker() {
    local user="" pgoptions="" a
    local args=("$@")
    for ((a = 0; a < ${#args[@]}; a++)); do
        [[ "${args[a]}" == "-U" ]] && user="${args[a+1]}"
        [[ "${args[a]}" == PGOPTIONS=* ]] && pgoptions="${args[a]#PGOPTIONS=}"
    done
    local sql ids
    sql="$(cat)"
    case "$sql" in
        "SHOW server_version_num;") printf '150008\n' ;;
        *has_parameter_privilege*)  printf 't\n' ;;
        *"to_regclass('cron.job')"*) [[ "$FAKE_CRON" == "true" ]] && printf 't\n' || printf 'f\n' ;;
        *"FROM cron.job WHERE active"*) awk '$2 == "t" { print $1 }' "$JOBS" ;;
        *"active := false"*|*"active := true"*)
            ids="$(sed -nE 's/.*jobid IN \(([0-9,]+)\).*/\1/p' <<<"$sql")"
            if [[ "$sql" == *"active := false"* ]]; then
                _set_jobs f "$ids"; printf '%s|pause|%s\n' "$user" "$ids" >>"$CRON_OPS"
            else
                _set_jobs t "$ids"; printf '%s|resume|%s\n' "$user" "$ids" >>"$CRON_OPS"
            fi
            awk -F, '{ print NF }' <<<"$ids"
            ;;
        *"JOIN pg_stat_activity a ON a.pid = d.job_pid"*)
            if [[ "$(head -1 "$RUNNING")" == always:* ]]; then
                head -1 "$RUNNING" | cut -d: -f2-
            elif [[ -s "$RUNNING" ]]; then
                head -1 "$RUNNING"; sed -i '1d' "$RUNNING"
            fi
            ;;
        *pg_locks*) printf '4123|pg_cron: agent-ingest-drain-1m|22|select public._agent_ingest_drain()\n' ;;
        "SELECT version FROM supabase_migrations.schema_migrations;") cat "$APPLIED" ;;
        *"INSERT INTO supabase_migrations.schema_migrations"*)
            printf '%s|%s\n' "$pgoptions" "$(_active_jobs)" >>"$ATTEMPTS"
            local left
            left="$(cat "$LOCK_FAILS")"
            if (( left > 0 )); then
                printf '%s\n' "$(( left - 1 ))" >"$LOCK_FAILS"
                printf 'psql:<stdin>:1: ERROR:  55P03: canceling statement due to lock timeout\n'
                return 3
            fi
            if [[ "$FAKE_SYNTAX_ERROR" == "true" ]]; then
                printf 'psql:<stdin>:1: ERROR:  42601: syntax error at or near "x"\n'
                return 3
            fi
            sed -nE "s/.*VALUES \('([0-9]+)'.*/\1/p" <<<"$sql" >>"$APPLIED"
            ;;
    esac
    return 0
}

_reset() {
    printf '1 t\n2 t\n3 f\n' >"$JOBS"
    : >"$APPLIED"; : >"$ATTEMPTS"; : >"$CRON_OPS"; : >"${T}/sleeps"
    printf '0\n' >"$LOCK_FAILS"
    rm -rf "$STATE_DIR" "${MIGS:?}"/*
    : >"$RUNNING"
    FAKE_CRON="true"; FAKE_SYNTAX_ERROR="false"
    SO_MIGRATION_JOB_WAIT=120
    SO_MIGRATION_LOCK_TIMEOUT=15s; SO_MIGRATION_LOCK_RETRIES=5; SO_MIGRATION_RETRY_DELAY=5
}
jobs_state() { paste -sd' ' "$JOBS"; }
add_migration() { printf 'ALTER TABLE agents ADD COLUMN x int;\n' >"${MIGS}/$1.sql"; }

# --- a migration that applies first time ------------------------------------
_reset
add_migration 20990101000000_one
out="$(deploy_migrations 2>&1)"; rc=$?
check "applies: succeeds" "0" "$rc"
check "applies: recorded once" "20990101000000" "$(cat "$APPLIED")"
check "applies: no job active while migrating" "" "$(cut -d'|' -f2 "$ATTEMPTS")"
check "applies: lock_timeout passed to psql" "-c lock_timeout=15s" "$(cut -d'|' -f1 "$ATTEMPTS")"
check "applies: active jobs paused, as supabase_admin" "supabase_admin|pause|1,2" "$(grep '|pause|' "$CRON_OPS")"
check "applies: the same jobs resumed" "supabase_admin|resume|1,2" "$(grep '|resume|' "$CRON_OPS")"
check "applies: jobs as before (inactive one untouched)" "1 t 2 t 3 f" "$(jobs_state)"
check "applies: state file removed" "absent" "$([[ -e "$(_cron_paused_file)" ]] && echo present || echo absent)"
check "applies: says what it paused" "1" "$(printf '%s\n' "$out" | grep -c 'Paused 2 background job(s) while migrating')"
check "applies: says it resumed them" "1" "$(printf '%s\n' "$out" | grep -c 'Resumed 2 background job(s)')"

# --- a running job is waited for --------------------------------------------
_reset
add_migration 20990101000000_one
printf 'agent-ingest-drain-1m|4123|9\nagent-ingest-drain-1m|4123|11\n' >"$RUNNING"
out="$(deploy_migrations 2>&1)"; rc=$?
check "running job: succeeds" "0" "$rc"
check "running job: named once while waiting" "1" "$(printf '%s\n' "$out" | grep -c 'agent-ingest-drain-1m (pid 4123, running 9s)')"
check "running job: polled until it finished" "2 2" "$(paste -sd' ' "${T}/sleeps")"
check "running job: migration ran after it" "20990101000000" "$(cat "$APPLIED")"

# --- a job still running at the wait limit: migrate anyway -------------------
_reset
add_migration 20990101000000_one
printf 'always:agent-ingest-drain-1m|4123|30\n' >"$RUNNING"
SO_MIGRATION_JOB_WAIT=6
out="$(deploy_migrations 2>&1)"; rc=$?
check "wait limit: succeeds" "0" "$rc"
check "wait limit: says it migrates anyway" "1" "$(printf '%s\n' "$out" | grep -c 'still running after 6s; migrating anyway')"
check "wait limit: stopped waiting at the limit" "3" "$(wc -l <"${T}/sleeps" | tr -d ' ')"

# --- lock timeouts: retried, then applied once ------------------------------
_reset
add_migration 20990101000000_one
printf '2\n' >"$LOCK_FAILS"
out="$(deploy_migrations 2>&1)"; rc=$?
check "lock retry: succeeds" "0" "$rc"
check "lock retry: three attempts" "3" "$(wc -l <"$ATTEMPTS" | tr -d ' ')"
check "lock retry: recorded once" "20990101000000" "$(cat "$APPLIED")"
check "lock retry: backoff doubles" "5 10" "$(paste -sd' ' "${T}/sleeps")"
check "lock retry: names the blocker" "2" \
    "$(printf '%s\n' "$out" | grep -c 'waiting on pid 4123 (pg_cron: agent-ingest-drain-1m, 22s)')"
check "lock retry: jobs as before" "1 t 2 t 3 f" "$(jobs_state)"

# --- still blocked after every retry: fails, jobs resumed -------------------
_reset
add_migration 20990101000000_one
add_migration 20990102000000_two
printf '99\n' >"$LOCK_FAILS"
SO_MIGRATION_LOCK_RETRIES=2
out="$(deploy_migrations 2>&1)"; rc=$?
check "blocked: fails" "1" "$rc"
check "blocked: 1 + 2 retries, later migrations not tried" "3" "$(wc -l <"$ATTEMPTS" | tr -d ' ')"
check "blocked: nothing recorded" "" "$(cat "$APPLIED")"
check "blocked: lock timeout reported" "1" "$(printf '%s\n' "$out" | grep -c 'Hint (55P03)')"
check "blocked: jobs resumed after the failure" "1 t 2 t 3 f" "$(jobs_state)"
check "blocked: state file removed" "absent" "$([[ -e "$(_cron_paused_file)" ]] && echo present || echo absent)"

# --- other errors are not retried -------------------------------------------
_reset
add_migration 20990101000000_one
FAKE_SYNTAX_ERROR="true"
deploy_migrations >/dev/null 2>&1; rc=$?
check "syntax error: fails" "1" "$rc"
check "syntax error: one attempt" "1" "$(wc -l <"$ATTEMPTS" | tr -d ' ')"
check "syntax error: jobs resumed" "1 t 2 t 3 f" "$(jobs_state)"

# --- a killed run left jobs paused: resumed, even with nothing pending ------
_reset
printf '1 f\n2 f\n3 f\n' >"$JOBS"
mkdir -p "$STATE_DIR"; printf '1\n2\n' >"$(_cron_paused_file)"
out="$(deploy_migrations 2>&1)"; rc=$?
check "leftover: succeeds" "0" "$rc"
check "leftover: the recorded jobs resumed" "1 t 2 t 3 f" "$(jobs_state)"
check "leftover: state file removed" "absent" "$([[ -e "$(_cron_paused_file)" ]] && echo present || echo absent)"

# --- the leftover jobs are put back before a new pause ----------------------
_reset
add_migration 20990101000000_one
printf '1 t\n2 f\n3 f\n' >"$JOBS"
mkdir -p "$STATE_DIR"; printf '2\n' >"$(_cron_paused_file)"
deploy_migrations >/dev/null 2>&1
check "leftover + pending: job 2 counted as active again, then restored" "1 t 2 t 3 f" "$(jobs_state)"
check "leftover + pending: paused both" "supabase_admin|pause|1,2" "$(grep '|pause|' "$CRON_OPS")"

# --- without pg_cron: nothing paused, migrations still applied --------------
_reset
add_migration 20990101000000_one
FAKE_CRON="false"
deploy_migrations >/dev/null 2>&1; rc=$?
check "no pg_cron: succeeds" "0" "$rc"
check "no pg_cron: nothing paused" "" "$(cat "$CRON_OPS")"
check "no pg_cron: recorded" "20990101000000" "$(cat "$APPLIED")"

# --- nothing pending: jobs untouched -----------------------------------------
_reset
deploy_migrations >/dev/null 2>&1; rc=$?
check "nothing pending: succeeds" "0" "$rc"
check "nothing pending: jobs untouched" "" "$(cat "$CRON_OPS")"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
