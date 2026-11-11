#!/usr/bin/env bash
# lib/database.sh - low-level database access, migrations and edge functions.
#
# Full-stack backup/restore lives in lib/backup.sh, which calls the
# _db_container/_db_user/_db_pass helpers below - it is not a database-only
# concern any more (it also archives Storage, edge functions and config).
#
# These operations are shared verbatim by first install, application update and
# full update. There is exactly one implementation of each.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Low-level database access
# ---------------------------------------------------------------------------

_db_container() {
    local cid
    cid="$(supabase_container_id "$(supabase_db_service)")"
    [[ -n "$cid" ]] || { log_error "The Supabase database container is not running."; return 1; }
    printf '%s' "$cid"
}

_db_user() { env_get "${SUPABASE_DIR}/.env" POSTGRES_USER 2>/dev/null || printf 'postgres'; }
_db_name() { env_get "${SUPABASE_DIR}/.env" POSTGRES_DB   2>/dev/null || printf 'postgres'; }
_db_pass() { env_get "${SUPABASE_DIR}/.env" POSTGRES_PASSWORD 2>/dev/null || printf ''; }

# The bootstrap superuser of the self-hosted Supabase image. Its password is
# POSTGRES_PASSWORD, like every other role the image creates.
DB_SUPERUSER="supabase_admin"

# Run SQL from stdin inside the database container, as the given role.
_db_psql_as() {
    local user="$1"; shift
    local cid
    cid="$(_db_container)" || return 1
    # SO_DB_PGOPTIONS sets session settings (e.g. -c lock_timeout=15s)
    # without adding lines to the SQL, so psql's line numbers still match the
    # migration file.
    docker exec -i -e PGPASSWORD="$(_db_pass)" ${SO_DB_PGOPTIONS:+-e "PGOPTIONS=${SO_DB_PGOPTIONS}"} "$cid" \
        psql -U "$user" -d "$(_db_name)" -v ON_ERROR_STOP=1 "$@"
}

# Run SQL from stdin inside the database container.
db_psql() {
    _db_psql_as "$(_db_user)" "$@"
}

# Run SQL from stdin as the superuser. Reserved for the few grants the
# migration role cannot give itself; everything else runs through db_psql so
# the objects it creates stay owned by the migration role.
db_psql_superuser() {
    _db_psql_as "$DB_SUPERUSER" "$@"
}

# Run a single query and print the bare result.
db_query() {
    printf '%s' "$1" | db_psql -tAq 2>/dev/null
}

_sql_ident() { printf '"%s"' "${1//\"/\"\"}"; }

# Does the migration role hold SET on session_replication_role? Prints
# "true", "false", or "unsupported" before PostgreSQL 15, where per-parameter
# grants do not exist.
db_replication_role_status() {
    local ver
    ver="$(db_query "SHOW server_version_num;")" || return 1
    [[ "$ver" =~ ^[0-9]+$ ]] || return 1
    if (( ver < 150000 )); then
        printf 'unsupported'
        return 0
    fi
    local has
    has="$(db_query "SELECT has_parameter_privilege(current_user, 'session_replication_role', 'SET');")" || return 1
    case "$has" in
        t) printf 'true' ;;
        f) printf 'false' ;;
        *) return 1 ;;
    esac
}

# Let the migration role set session_replication_role. The application's
# restore loads tables with foreign keys and triggers suspended, and on a
# self-hosted stack the migration role (postgres) is not a superuser, so it
# needs this one grant - which only the superuser can give. Idempotent.
#
# Never fails the caller's run: a missing grant breaks backup restore inside
# the application, not the deployment, so it is reported loudly instead.
db_ensure_replication_role_grant() {
    local status
    if ! status="$(db_replication_role_status)"; then
        log_warn "Could not check whether $(_db_user) may set session_replication_role."
        return 1
    fi

    case "$status" in
        true)
            log_debug "$(_db_user) may already set session_replication_role"
            return 0
            ;;
        unsupported)
            log_warn "PostgreSQL is older than 15; cannot grant SET on session_replication_role."
            log_warn "Restoring a backup from inside the application will fail."
            return 1
            ;;
    esac

    if printf 'GRANT SET ON PARAMETER session_replication_role TO %s;\n' "$(_sql_ident "$(_db_user)")" \
            | db_psql_superuser -q >>"${SO_LOG_FILE:-/dev/null}" 2>&1 \
        && [[ "$(db_replication_role_status)" == "true" ]]; then
        log_ok "Granted $(_db_user) SET on session_replication_role (needed by backup restore)"
        return 0
    fi

    log_warn "Could not grant $(_db_user) SET on session_replication_role as ${DB_SUPERUSER}."
    log_warn "Restoring a backup from inside the application will fail until it is granted."
    log_warn "Retry with: sentinel-ops repair apply"
    return 1
}

# ---------------------------------------------------------------------------
# Migrations
#
# The tracking table is the same one the Supabase CLI uses
# (supabase_migrations.schema_migrations), so a database migrated by this
# installer stays compatible with `supabase db push` and vice versa.
# ---------------------------------------------------------------------------

_migrations_ensure_table() {
    # psql's error goes to the console and the log, not to /dev/null.
    db_psql -q <<'SQL' 2>&1 >/dev/null | tee -a "${SO_LOG_FILE:-/dev/null}" | sed 's/^/        /' >&2
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
    version    text NOT NULL PRIMARY KEY,
    statements text[],
    name       text
);
SQL
    return "${PIPESTATUS[0]}"
}

# The version is the leading numeric timestamp of the filename, matching the
# Supabase CLI's convention: 20240101120000_add_users.sql -> 20240101120000
_migration_version() {
    local base="$1"
    base="${base%.sql}"
    printf '%s' "${base%%_*}"
}

_migration_name() {
    local base="$1"
    base="${base%.sql}"
    if [[ "$base" == *_* ]]; then printf '%s' "${base#*_}"; else printf '%s' "$base"; fi
}

_sql_quote() { printf "%s" "${1//\'/\'\'}"; }

# Print every version that more than one migration file claims. Two files with
# one version cannot both be recorded: the second fails on the tracking row's
# primary key, however correct its SQL is.
_migration_duplicate_versions() {
    local f
    for f in "$@"; do _migration_version "$(basename "$f")"; printf '\n'; done \
        | LC_ALL=C sort | uniq -d
}

# A one-line explanation for the SQLSTATEs migrations actually hit.
_migration_hint() {
    case "$1" in
        42P07|42710|42723|42P06)
            printf '%s' "The object already exists. It was probably created outside the migrations (by hand, in Studio, or by a restore), or an earlier migration already creates it. Make the statement idempotent (IF NOT EXISTS / OR REPLACE) or drop the stray object." ;;
        42P01|42883|42704|3F000)
            printf '%s' "The migration depends on an object that does not exist yet. Check that the migration creating it sorts earlier by filename, and that it was not skipped or deleted." ;;
        42703)
            printf '%s' "A column the migration refers to does not exist - the table's live shape differs from what the migration expects." ;;
        42501)
            printf '%s' "Permission denied. Migrations run as $(_db_user), which is not a superuser on self-hosted Supabase: objects owned by supabase_admin or another role cannot be altered, and superuser-only commands are refused." ;;
        42601)
            printf '%s' "SQL syntax error - see the statement and position above." ;;
        23505)
            printf '%s' "Existing rows violate a unique constraint (or a duplicate row is being inserted). Clean the data first or make the insert conditional (ON CONFLICT)." ;;
        23502|23503|23514|23P01)
            printf '%s' "Rows already in the table violate the new constraint. Backfill or clean the data in the migration before adding it." ;;
        22*)
            printf '%s' "A value does not fit its type (format, length or range). In an ALTER COLUMN ... TYPE or a backfill this is usually existing data." ;;
        55P03|57014)
            printf '%s' "Timed out waiting for a lock or for the statement: another session held the table through every retry (see 'waiting on' above). Background jobs were paused and are resumed; wait for that session to finish, or stop it, and run the update again. SO_MIGRATION_LOCK_TIMEOUT and SO_MIGRATION_LOCK_RETRIES allow longer waits." ;;
        40P01)
            printf '%s' "Deadlock with another session on every retry. Wait for the other session (see 'waiting on' above) and run the update again." ;;
        0A000)
            printf '%s' "Feature not supported here - often an extension or command the self-hosted image does not provide." ;;
        25*)
            printf '%s' "Transaction-state problem. Each migration already runs in one transaction; remove its own BEGIN/COMMIT, and move statements that cannot run in a transaction (e.g. CREATE INDEX CONCURRENTLY) out of it." ;;
    esac
}

# Explain a failed migration on the console. psql ran with -f - (every message
# carries its input line), -b (the failing statement is echoed) and verbose
# errors (the SQLSTATE is included); the complete output is in the log file.
#
#   _migration_report_failure <migration file> <psql output file> <exit code>
_migration_report_failure() {
    local file="$1" out="$2" rc="$3"
    local base rel
    base="$(basename "$file")"
    rel="supabase/migrations/${base}"

    log_error "Migration failed: ${base}"

    # Not an SQL error: docker could not run psql, or the connection broke.
    # Show psql's own words; there is no statement to point at.
    if (( rc != 3 )) || ! grep -qE '^psql:<stdin>:[0-9]+: (ERROR|FATAL|PANIC):' "$out"; then
        if grep -q 'Error response from daemon' "$out"; then
            log_error "Docker could not run psql in the database container."
        elif (( rc == 2 )); then
            log_error "The connection to the database failed or was lost (did the database container restart or run out of memory?)."
        fi
        sed -n '1,20p' "$out" | sed 's/^/        /' >&2
        return 0
    fi

    # The first error, its continuation lines (DETAIL, HINT, LINE, QUERY,
    # CONTEXT ...), and the echoed STATEMENT that follows it.
    # Regexes live in variables: quoted characters inside [[ =~ ]] are
    # passed to regcomp escaped, and \< is a GNU word boundary.
    local re_err='^psql:<stdin>:([0-9]+): (ERROR|FATAL|PANIC): +(([0-9A-Z]{5}): )?'
    local re_stmt='^psql:<stdin>:[0-9]+: STATEMENT:  (.*)$'
    local re_pos='^LINE ([0-9]+):'
    local err_line="" sqlstate="" pos="" in_err=false in_stmt=false
    local msg=() stmt=() l
    while IFS= read -r l || [[ -n "$l" ]]; do
        if $in_stmt; then
            [[ "$l" == "psql:<stdin>:"* ]] && break
            stmt+=("$l"); continue
        fi
        if ! $in_err; then
            if [[ "$l" =~ $re_err ]]; then
                err_line="${BASH_REMATCH[1]}"; sqlstate="${BASH_REMATCH[4]}"
                in_err=true
                msg+=("${l#psql:<stdin>:*: }")
            fi
            continue
        fi
        if [[ "$l" =~ $re_stmt ]]; then
            stmt+=("${BASH_REMATCH[1]}"); in_stmt=true; continue
        fi
        [[ "$l" == "psql:<stdin>:"* ]] && break
        [[ "$l" == LOCATION:* ]] && continue
        # LINE n: refers to the statement itself unless an inner QUERY (from a
        # function or DO block) is being reported.
        [[ "$l" == QUERY:* ]] && pos="inner"
        if [[ -z "$pos" && "$l" =~ $re_pos ]]; then pos="${BASH_REMATCH[1]}"; fi
        msg+=("$l")
    done <"$out"

    printf '%s\n' "${msg[@]:0:25}" | sed 's/^/        /' >&2

    # psql reports the line the statement ends on; the echoed statement gives
    # its length, and so where it starts.
    local file_lines end start
    file_lines="$(awk 'END { print NR }' "$file")"
    end="$err_line"
    if (( end > file_lines )); then
        if [[ "${stmt[0]:-}" == "INSERT INTO supabase_migrations.schema_migrations"* ]]; then
            log_error "The SQL itself succeeded; recording it in supabase_migrations.schema_migrations failed."
            [[ "$sqlstate" == "23505" ]] && \
                log_error "Version $(_migration_version "$base") is already recorded - another migration file has the same version prefix. Rename one of them."
            return 0
        fi
        # The file's last statement has no ';', so psql ran it and the
        # tracking row as one statement.
        log_error "The last statement in ${rel} is missing its terminating semicolon."
    fi
    start=$(( end - ${#stmt[@]} + 1 ))
    (( ${#stmt[@]} > 0 && start >= 1 )) || start="$end"
    (( end > file_lines )) && end="$file_lines"
    (( start > end )) && start="$end"

    local mark=""
    [[ "$pos" =~ ^[0-9]+$ ]] && mark=$(( start + pos - 1 ))
    [[ -n "$mark" ]] && (( mark > end )) && mark=""

    # Show the statement - or, if it is long, a window around the error.
    local from="$start" to="$end"
    if (( to - from > 14 )); then
        if [[ -n "$mark" ]]; then from=$(( mark - 5 )); to=$(( mark + 5 )); else to=$(( from + 14 )); fi
        (( from < start )) && from="$start"
        (( to > end )) && to="$end"
    fi

    if [[ -n "$mark" ]]; then
        log_error "At ${rel}:${mark} (statement on lines ${start}-${end}):"
    else
        log_error "In ${rel}, statement on lines ${start}-${end}:"
    fi
    awk -v from="$from" -v to="$to" -v mark="${mark:-0}" \
        'NR >= from && NR <= to { printf "     %s %5d | %s\n", (NR == mark ? ">" : " "), NR, $0 }' \
        "$file" >&2
    (( to < end )) && printf '              | ... (%d more line(s))\n' $(( end - to )) >&2

    local hint
    hint="$(_migration_hint "$sqlstate")"
    [[ -n "$hint" ]] && log_error "Hint${sqlstate:+ (${sqlstate})}: ${hint}"
    return 0
}

# ---------------------------------------------------------------------------
# Background jobs and locks while migrating (#33)
#
# The application's pg_cron jobs keep writing while migrations run: the
# agent-ingest drains every minute, in one transaction of up to ~30 s per
# batch, plus the 1-minute summary jobs. A migration that needs a strong lock
# (CREATE POLICY, ALTER TABLE, an index build) on one of their tables waits
# for them, and every later query on that table - console reads, agent writes,
# the next drain - queues behind it. So:
#
#   * every active job is paused for the migrations and resumed afterwards.
#     Agents keep sending; their messages wait in pgmq and drain on resume.
#     The paused job ids are written to a state file first, so a run that is
#     killed half-way is undone by the next update (or `repair apply`);
#   * each migration runs with a lock_timeout, and one that times out on a
#     lock (or loses a deadlock) is rolled back and retried with backoff;
#   * whoever held the lock is named.
# ---------------------------------------------------------------------------

SO_MIGRATION_LOCK_TIMEOUT="${SO_MIGRATION_LOCK_TIMEOUT:-15s}"
SO_MIGRATION_LOCK_RETRIES="${SO_MIGRATION_LOCK_RETRIES:-5}"
SO_MIGRATION_RETRY_DELAY="${SO_MIGRATION_RETRY_DELAY:-5}"    # seconds, doubled per retry
SO_MIGRATION_JOB_WAIT="${SO_MIGRATION_JOB_WAIT:-120}"        # seconds

_cron_paused_file() { printf '%s/migrations-paused-cron-jobs' "${STATE_DIR:-${INSTALL_DIR:-/opt/sentinel-ops}/.state}"; }

# Run a single query as the superuser and print the bare result. cron.job
# belongs to supabase_admin, not to the migration role.
_db_query_superuser() {
    printf '%s' "$1" | db_psql_superuser -tAq 2>/dev/null
}

_cron_available() {
    [[ "$(_db_query_superuser "SELECT to_regclass('cron.job') IS NOT NULL;")" == "t" ]]
}

# Comma-separated job ids from the state file; nothing when absent or empty.
_cron_paused_ids() {
    local file
    file="$(_cron_paused_file)"
    [[ -s "$file" ]] || return 0
    grep -E '^[0-9]+$' "$file" | paste -sd, -
}

# Resume the jobs a migration run paused. Safe to call at any time: without a
# state file it does nothing. Jobs deleted in the meantime are skipped.
cron_jobs_resume_paused() {
    local file ids n
    file="$(_cron_paused_file)"
    [[ -e "$file" ]] || return 0
    ids="$(_cron_paused_ids)"
    if [[ -z "$ids" ]]; then
        rm -f "$file"
        return 0
    fi
    if ! n="$(_db_query_superuser "SELECT count(cron.alter_job(jobid, active := true)) FROM cron.job WHERE jobid IN (${ids});")" \
        || [[ -z "$n" ]]; then
        log_warn "Could not resume the background jobs paused for migrations (ids ${ids}). They stay paused; run \`sentinel-ops repair apply\` to resume them."
        return 1
    fi
    rm -f "$file"
    log_ok "Resumed ${n} background job(s)"
    return 0
}

# Job runs still in progress, one per line: "<jobname>|<pid>|<seconds>".
_cron_running_jobs() {
    _db_query_superuser "SELECT j.jobname, d.job_pid, extract(epoch FROM now() - d.start_time)::int
                           FROM cron.job_run_details d
                           JOIN cron.job j ON j.jobid = d.jobid
                           JOIN pg_stat_activity a ON a.pid = d.job_pid
                          WHERE d.status = 'running'
                          ORDER BY d.start_time;"
}

# Pause every active pg_cron job, then wait (bounded) for runs in progress.
# Returns non-zero only when jobs could not be paused; migrations then run as
# before, with the lock timeout and retries still in place.
cron_jobs_pause_for_migrations() {
    # A killed earlier run left its jobs paused: put them back first, so they
    # are recorded as active again below.
    cron_jobs_resume_paused || return 1
    _cron_available || return 0

    local ids file n
    ids="$(_db_query_superuser "SELECT jobid FROM cron.job WHERE active ORDER BY jobid;")" || {
        log_warn "Could not read the background jobs; migrating with them running."
        return 1
    }
    [[ -n "$ids" ]] || return 0

    file="$(_cron_paused_file)"
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    # Written before pausing: if this run dies after the update below, the
    # next one knows what to resume.
    if ! printf '%s\n' "$ids" >"$file"; then
        log_warn "Could not write ${file}; migrating with background jobs running."
        return 1
    fi
    if ! n="$(_db_query_superuser "SELECT count(cron.alter_job(jobid, active := false)) FROM cron.job WHERE jobid IN ($(_cron_paused_ids));")" \
        || [[ -z "$n" ]]; then
        rm -f "$file"
        log_warn "Could not pause the background jobs; migrating with them running."
        return 1
    fi
    log_info "Paused ${n} background job(s) while migrating"

    # pg_cron does not stop a run in progress. Wait for it, within a limit:
    # past it, the lock timeout below keeps a migration from queueing forever.
    local waited=0 running
    while :; do
        running="$(_cron_running_jobs)" || running=""
        [[ -z "$running" ]] && break
        if (( waited >= SO_MIGRATION_JOB_WAIT )); then
            log_warn "Background jobs still running after ${SO_MIGRATION_JOB_WAIT}s; migrating anyway:"
            _cron_print_running "$running"
            break
        fi
        if (( waited == 0 )); then
            log_info "Waiting for running background jobs to finish:"
            _cron_print_running "$running"
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done
    return 0
}

_cron_print_running() {
    local name pid secs
    while IFS='|' read -r name pid secs; do
        [[ -n "$name" ]] && log_info "    ${name} (pid ${pid}, running ${secs}s)"
    done <<<"$1"
}

# The SQLSTATE of the first error in a psql output file (run with
# VERBOSITY=verbose), or nothing.
_migration_sqlstate() {
    grep -m1 -oE 'ERROR:  [0-9A-Z]{5}:' "$1" 2>/dev/null | sed -E 's/ERROR:  ([0-9A-Z]{5}):/\1/'
}

# Sessions in a transaction that hold locks on tables, oldest first: after a
# lock timeout the migration's own transaction is gone, so pg_blocking_pids()
# can't name the blocker any more, but the session that held the lock usually
# still does. Names the pg_cron job when the session is one.
_migration_report_blockers() {
    local cron_join="" cron_name="NULL"
    if _cron_available; then
        cron_join="LEFT JOIN cron.job_run_details d ON d.job_pid = a.pid AND d.status = 'running'
                    LEFT JOIN cron.job j ON j.jobid = d.jobid"
        cron_name="'pg_cron: ' || j.jobname"
    fi
    local rows
    rows="$(_db_query_superuser "SELECT a.pid,
                                        coalesce(${cron_name}, nullif(a.application_name, ''), a.backend_type, '?'),
                                        extract(epoch FROM now() - a.xact_start)::int,
                                        left(regexp_replace(coalesce(a.query, ''), '\s+', ' ', 'g'), 120)
                                   FROM pg_stat_activity a
                                   ${cron_join}
                                  WHERE a.xact_start IS NOT NULL
                                    AND a.pid <> pg_backend_pid()
                                    AND a.datname = current_database()
                                    AND EXISTS (SELECT 1 FROM pg_locks l
                                                 WHERE l.pid = a.pid AND l.granted
                                                   AND l.locktype = 'relation')
                                  ORDER BY a.xact_start
                                  LIMIT 5;")" || rows=""
    if [[ -z "$rows" ]]; then
        log_warn "    No session holds table locks now; it has finished."
        return 0
    fi
    local pid who secs query
    while IFS='|' read -r pid who secs query; do
        [[ -n "$pid" ]] && log_warn "    waiting on pid ${pid} (${who}, ${secs}s): ${query}"
    done <<<"$rows"
}

# Apply every pending migration, in filename order.
#
# Each migration runs in a single transaction together with the row that
# records it, so a failed migration leaves neither partial schema changes nor a
# bogus tracking entry. Background jobs are paused for the duration (#33).
deploy_migrations() {
    local dir="${APP_DIR}/supabase/migrations"
    [[ -d "$dir" ]] || { log_error "No migrations directory at ${dir}"; return 1; }

    _db_container >/dev/null || return 1

    if ! _migrations_ensure_table; then
        log_error "Could not create the migration tracking table."
        return 1
    fi

    # Before the early return below, so an already-current database still gets
    # it. Not fatal: see db_ensure_replication_role_grant.
    db_ensure_replication_role_grant || true

    # Background jobs a killed earlier run left paused, also when nothing is
    # pending now (#33).
    cron_jobs_resume_paused || true

    local applied_list
    applied_list="$(db_query "SELECT version FROM supabase_migrations.schema_migrations;")" || applied_list=""

    local files=() f
    while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -name '*.sql' -type f | LC_ALL=C sort)

    if (( ${#files[@]} == 0 )); then
        log_warn "No migration files found in ${dir}"
        return 0
    fi

    # Two files sharing a version would leave one silently unapplied: the
    # first is recorded, and the second then looks already applied.
    local dups
    dups="$(_migration_duplicate_versions "${files[@]}")"
    if [[ -n "$dups" ]]; then
        log_error "Several migration files share a version prefix; each version must be unique:"
        local v
        while IFS= read -r v; do
            for f in "${files[@]}"; do
                [[ "$(_migration_version "$(basename "$f")")" == "$v" ]] && printf '        %s\n' "$(basename "$f")" >&2
            done
        done <<<"$dups"
        log_error "Give one file of each pair a new, later version (keep the one already applied) and retry. Nothing was applied."
        return 1
    fi

    local pending=() base version
    for f in "${files[@]}"; do
        base="$(basename "$f")"
        version="$(_migration_version "$base")"
        if printf '%s\n' "$applied_list" | grep -qx "$version"; then
            log_debug "already applied: ${base}"
        else
            pending+=("$f")
        fi
    done

    if (( ${#pending[@]} == 0 )); then
        log_ok "Database schema up to date (${#files[@]} migrations already applied)"
        return 0
    fi

    cron_jobs_pause_for_migrations || true
    log_info "Applying ${#pending[@]} pending migration(s)..."
    local rc=0
    _apply_pending_migrations "${pending[@]}" || rc=$?
    # Whatever happened above. A failure here leaves the state file for the
    # next update or `repair apply`.
    cron_jobs_resume_paused || true
    return "$rc"
}

# Apply the given migration files in order; stops at the first failure.
_apply_pending_migrations() {
    local count=0 out rc f base version attempt sqlstate delay
    out="$(mktemp)"
    for f in "$@"; do
        base="$(basename "$f")"
        version="$(_migration_version "$base")"
        local name
        name="$(_migration_name "$base")"

        log_info "  ${base}"
        attempt=0
        while :; do
            # -f - makes psql prefix each message with the input line, -b
            # echoes the failing statement, and verbose errors carry the
            # SQLSTATE. A lock wait longer than the timeout fails the
            # transaction (55P03) instead of queueing everyone behind it.
            rc=0
            {
                cat "$f"
                printf '\nINSERT INTO supabase_migrations.schema_migrations (version, name) VALUES (%s%s%s, %s%s%s);\n' \
                    "'" "$(_sql_quote "$version")" "'" "'" "$(_sql_quote "$name")" "'"
            } | SO_DB_PGOPTIONS="-c lock_timeout=${SO_MIGRATION_LOCK_TIMEOUT}" \
                db_psql --single-transaction -q -b -v VERBOSITY=verbose -f - >"$out" 2>&1 || rc=$?

            if [[ -s "$out" ]]; then
                _log_to_file "[DEBUG] psql output for ${base} (exit ${rc}, attempt $(( attempt + 1 ))):"
                [[ -n "$SO_LOG_FILE" ]] && sed 's/^/    /' "$out" 2>/dev/null >>"$SO_LOG_FILE"
            fi
            (( rc == 0 )) && break

            sqlstate="$(_migration_sqlstate "$out")"
            [[ "$sqlstate" == "55P03" || "$sqlstate" == "40P01" ]] || break
            if (( attempt >= SO_MIGRATION_LOCK_RETRIES )); then
                log_error "  Still blocked after ${SO_MIGRATION_LOCK_RETRIES} retries:"
                _migration_report_blockers
                break
            fi
            attempt=$(( attempt + 1 ))
            delay=$(( SO_MIGRATION_RETRY_DELAY * (1 << (attempt - 1)) ))
            if [[ "$sqlstate" == "55P03" ]]; then
                log_warn "  A lock was not free within ${SO_MIGRATION_LOCK_TIMEOUT}; rolled back, retry ${attempt}/${SO_MIGRATION_LOCK_RETRIES} in ${delay}s"
            else
                log_warn "  Deadlock with another session; rolled back, retry ${attempt}/${SO_MIGRATION_LOCK_RETRIES} in ${delay}s"
            fi
            _migration_report_blockers
            sleep "$delay"
        done

        if (( rc != 0 )); then
            _migration_report_failure "$f" "$out" "$rc"
            log_error "The transaction was rolled back; the database is unchanged by this migration."
            log_error "Applied before the failure: ${count} migration(s)."
            [[ -n "$SO_LOG_FILE" ]] && log_error "Full psql output: ${SO_LOG_FILE}"
            rm -f "$out"
            return 1
        fi
        count=$(( count + 1 ))
    done
    rm -f "$out"

    log_ok "Applied ${count} migration(s)"
    return 0
}

migrations_applied_count() {
    db_query "SELECT count(*) FROM supabase_migrations.schema_migrations;" 2>/dev/null || printf '?'
}

# ---------------------------------------------------------------------------
# Edge functions
#
# On a self-hosted stack the edge runtime serves whatever is mounted at
# supabase/volumes/functions. Deploying therefore means syncing the repository's
# functions into that volume and restarting the runtime - `supabase functions
# deploy` targets the hosted platform and does not apply here.
# ---------------------------------------------------------------------------

_functions_service() {
    local s
    for s in functions edge-runtime deno-relay; do
        if supabase_compose config --services 2>/dev/null | grep -qx "$s"; then
            printf '%s' "$s"; return 0
        fi
    done
    printf 'functions'
}

deploy_functions() {
    local src="${APP_DIR}/supabase/functions"
    local dest="${SUPABASE_DIR}/volumes/functions"

    [[ -d "$src" ]] || { log_error "No functions directory at ${src}"; return 1; }
    mkdir -p "$dest"

    # Enumerate the functions: every immediate subdirectory holding an entry
    # point. Directories starting with _ are shared code, not functions.
    local names=() d base
    while IFS= read -r d; do
        base="$(basename "$d")"
        [[ "$base" == _* ]] && continue
        if [[ -f "${d}/index.ts" || -f "${d}/index.js" || -f "${d}/mod.ts" ]]; then
            names+=("$base")
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

    if (( ${#names[@]} == 0 )); then
        log_warn "No deployable edge functions found in ${src}"
    else
        log_info "Deploying ${#names[@]} edge function(s): ${names[*]}"
    fi

    # The stack ships a `main` bootstrap function that routes requests to the
    # others. It is infrastructure, not application code, so it is preserved.
    local preserved=""
    if [[ -d "${dest}/main" && ! -d "${src}/main" ]]; then
        preserved="$(mktemp -d)"
        cp -a "${dest}/main" "${preserved}/main"
    fi

    # Replace the application functions wholesale so a function deleted from
    # the repository also disappears from the deployment.
    local keep
    for d in "$dest"/*/; do
        [[ -d "$d" ]] || continue
        keep="$(basename "$d")"
        [[ "$keep" == "main" ]] && continue
        rm -rf "$d"
    done

    cp -a "${src}/." "${dest}/" || { log_error "Could not copy functions into ${dest}"; return 1; }

    if [[ -n "$preserved" && -d "${preserved}/main" && ! -d "${dest}/main" ]]; then
        cp -a "${preserved}/main" "${dest}/main"
    fi
    [[ -n "$preserved" ]] && rm -rf "$preserved"

    # Restart the runtime so it picks up the new code.
    local svc
    svc="$(_functions_service)"
    log_info "Restarting the edge runtime (${svc})..."
    if ! run_logged "restart ${svc}" bash -c \
        "$(_supabase_compose_cmd) up -d --force-recreate ${svc}"; then
        log_error "Could not restart the edge runtime."
        return 1
    fi

    # Confirm it actually came back up; a syntax error in a function can stop
    # the runtime from booting at all.
    if ! wait_for 60 3 supabase_service_running "$svc"; then
        log_error "The edge runtime did not stay running after deployment."
        docker logs --tail 40 "$(supabase_container_id "$svc")" 2>&1 | tail -n 40 >&2 || true
        return 1
    fi

    state_set APP_FUNCTIONS "${names[*]:-none}"
    log_ok "Edge functions deployed"
    return 0
}
