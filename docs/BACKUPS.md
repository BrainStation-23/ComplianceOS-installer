# Backups and 3-2-1

A default install takes local backups automatically: a full-stack one before
every Supabase update, and a database-only one before every migration run and
application update (see [Full and database-only
backups](#full-and-database-only-backups)). This page
covers the full layout, how to restore any scope from any copy, and how to
turn that into a real **3-2-1** setup: 3 copies of your backups, on 2
different media, with 1 of them offsite.

```bash
sentinel-ops backup create              # take one now (--scope=db to leave Storage out)
sentinel-ops backup list                # what's on disk: size, scope, reason
sentinel-ops backup verify              # checksum the latest (or a given one)
sentinel-ops restore                    # restore the latest local backup
```

## What's in a backup

Each backup is one directory under `backups/<timestamp>/`, and captures
enough to rebuild the whole install on a fresh box — not just the database:

```
/opt/sentinel-ops/backups/2026-09-11-121500/
├── database.sql.gz     roles + every database, less log data (gzip)
├── storage.tar.gz      Supabase Storage's uploaded objects, less in-app backups (full backups only)
├── functions.tar.gz    the deployed edge functions
├── config.tar.gz        supabase/.env + installer.env + the deploy key (chmod 600)
├── checksums.txt        sha256 of every file above
└── metadata.txt         timestamp, reason, versions, sizes
```

`config.tar.gz` holds real secrets (`JWT_SECRET`, `POSTGRES_PASSWORD`, API
keys) — it's chmod 600 the moment it's written, and restoring it is a
separate, explicitly-confirmed step (see below) because it invalidates every
current session and issued token.

If any archive cannot be written (a full disk, say), the whole backup is
discarded and the backup fails. A truncated archive is never kept with a
checksum that vouches for it.

Backups from before the dump was compressed hold `database.sql` instead.
Restore reads either.

### What a backup leaves out

A backup is for bringing an install back, not for keeping its logs. So the
dump keeps every table's **definition**, and leaves the **data** of these
tables out. After a restore they exist, empty, and fill up again on their
own.

| Database | Tables | What they are |
|---|---|---|
| `_supabase` | `_analytics.*` | Logflare's log store: every container's log lines |
| `postgres` | `auth.audit_log_entries`, `net._http_response`, `cron.job_run_details`, `pgmq.a_*`, `realtime.messages*` | Supabase housekeeping logs and archives |
| `postgres` | `public.agent_power_windows`, `agent_awake_hours`, `dlp_file_health_samples`, `dlp_event_merges`, `yara_event_receipts`, `yara_agent_event_counters`, `compliance_*_results`, `compliance_eval_pending`, `storage_sweep_runs`, `software_catalog_enrich_runs`, `integration_sync_runs` | Rolling telemetry and derived state the application rebuilds |
| `postgres` | `public.audit_logs*`: the table and all its daily partitions | Agent log ingest, which the application itself drops after 7 days |

Everything else is kept, including users, Vault secrets, MDM certificates
and recovery keys, and the audit trails (`user_activity_logs`,
`command_audit_logs`, `*_change_audit`). This is a disaster-recovery copy,
so it does not follow the in-app backup's table selection, which leaves
secrets out on purpose (see [DECISIONS.md](DECISIONS.md) #35).

Full backups also leave out Storage's `backups` bucket, where the in-app
backups keep their files. Those are already copies, sent to their own
destinations. After a full restore, restore in-app backups from there.

To see what takes the space and tune the list:

```bash
sentinel-ops backup size        # largest tables per database, and whether backups take their data
```

In `config/installer.env`:

- `BACKUP_EXCLUDE_DATA`: more tables to leave out, space-separated
  `<database>:<schema>.<table>` patterns with `*`, for example
  `"postgres:public.alert_events postgres:public.dlp_events"`.
- `BACKUP_INCLUDE_LOG_DATA=true`: take every table's data, as backups did
  before.

`metadata.txt` records what each backup left out (`excluded_data`,
`excluded_storage_buckets`), and a restore prints it.

### Full and database-only backups

`storage.tar.gz` grows with everything uploaded to Storage, including App
Catalog installers, which can be up to 4 GiB each (see
`STORAGE_FILE_SIZE_LIMIT`). Copying all of it before every application update,
which only changes the database, edge functions and frontend, is what used to
fill disks, so backups come in two scopes:

| Scope | Contains | Taken |
|---|---|---|
| `full` | everything above | before `update supabase`, on the schedule, `backup create`, before a `--scope=full` restore |
| `db` | everything but `storage.tar.gz` | before `update app` (and so every auto-update), before the first migration run, before a database restore |

`backup list` shows each backup's scope. Restoring `--scope=full` from a
database-only backup restores the database, functions and (if confirmed)
config, and leaves Storage files as they are, with a warning.

### Retention

Two limits in `config/installer.env` apply after every backup, and on
`sentinel-ops cleanup`:

- `BACKUP_RETENTION_COUNT` (default 10): keep at most this many.
- `BACKUP_RETENTION_MAX_GB` (default `auto`): keep at most this many GiB in
  total, removing the oldest first. `auto` is a fifth of the filesystem the
  backups live on, and `0` turns the size limit off.

The newest backup and the newest **full** backup are never removed. The
newest full backup is the only local copy of Storage, and a run of
database-only backups before updates must not push it out. So the count can
be exceeded by one, and the size limit by those two backups.

A backup also checks free space before it starts. It needs room for about the
size of the databases (plus Storage for a full one), 10% on top, and 1 GiB to
spare. Otherwise it fails with a message saying how much it needs. Before an
application update that is a warning and the update continues, as with any
other backup failure. Before a Supabase update the update is refused. Free
space with `sentinel-ops cleanup`, or by lowering the limits above.

restic deduplicates unchanged objects across its own snapshots, so the 3-2-1
copies grow by what changed, not by the full size each time.

## Restoring

```bash
sentinel-ops restore                                    # latest local backup, database only
sentinel-ops restore 2026-09-11-121500                   # a specific local backup
sentinel-ops restore --scope=full                        # + Storage, functions and (on confirmation) config
sentinel-ops restore --from=secondary --scope=full        # from the secondary repository
sentinel-ops restore --from=offsite --snapshot=<id>       # a specific offsite snapshot (default: latest)
```

Every restore, regardless of source:

1. Verifies the backup's checksums before touching anything live.
2. Shows its metadata and asks for confirmation.
3. Takes a fresh safety backup of the current state first, of the same scope
   as the restore.
4. Restores the database.
5. With `--scope=full`, also restores Storage and edge functions, then asks
   a **second, separate** confirmation before restoring `config.tar.gz` (it
   overwrites live secrets).
6. Restarts Supabase and health-checks it.

`--from=secondary`/`--from=offsite` pulls the chosen snapshot down from that
restic repository into a temporary staging directory first, then runs the
exact same restore steps above — a restic-sourced restore is not a different
code path, just a different source directory.

## Setting up 3-2-1

| Copy | What | Command |
|---|---|---|
| 1 | Local backups under `backups/` (this host, same disk) | on by default |
| 2 | **Secondary** — a different local/attached medium (second disk, NAS mount, ...) | `sentinel-ops remote secondary configure` |
| 3 | **Offsite** — a remote/cloud target | `sentinel-ops remote offsite configure` |

Both replication targets are [restic](https://restic.net) repositories:
restic handles encryption, deduplication and retention, so nothing here
implements its own crypto. A repository is just a URL — restic supports a
local path, `s3:...`, `b2:...`, `sftp:...` and more; see [restic's own
docs](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
for the full list and what credentials each backend needs.

```bash
sentinel-ops remote secondary configure   # e.g. a mounted second disk or NAS share
sentinel-ops remote offsite configure     # e.g. an S3-compatible bucket
sentinel-ops remote status                # both roles at a glance
```

`configure` prompts for:

- the repository URL
- a repository password (generated for you if left blank — this is what
  encrypts the repository; **write it down**, restic cannot recover a
  repository without it)
- any backend credentials the URL needs (e.g. `AWS_ACCESS_KEY_ID`/
  `AWS_SECRET_ACCESS_KEY` for an S3 URL) — entered as `KEY=VALUE` pairs,
  blank to finish
- retention: how many daily/weekly/monthly snapshots to keep (`restic forget
  --prune` applies this on every scheduled cycle)

Credentials never appear in `config/installer.env`. They live in:

```
config/restic-<role>.pass   the repository password       chmod 600
config/restic-<role>.env    backend credentials (KEY=VALUE) chmod 600
```

`sentinel-ops remote secondary check` / `offsite check` runs `restic check`
against that repository on demand; `... forget` re-applies the retention
policy on demand. Both run automatically as part of the scheduled cycle
below.

## Scheduling

```bash
sentinel-ops schedule enable     # prompts for a systemd OnCalendar expression (default: daily)
sentinel-ops schedule status
sentinel-ops schedule disable
sentinel-ops schedule run-now    # run a full cycle immediately, without waiting for the timer
```

`schedule enable` installs a `sentinel-ops-backup.timer`/`.service` pair
(`systemctl status sentinel-ops-backup.timer`, logs via `journalctl -u
sentinel-ops-backup.service`). Each scheduled cycle:

1. Takes a full local backup (**fatal** if this fails — nothing else runs).
2. Replicates it to `secondary`/`offsite`, for each that's configured
   (**a replication failure is a loud warning, not fatal** — the local
   backup must survive even if the network or cloud target is down).
3. Applies the configured retention policy to each configured repository.
4. Verifies the local backup's checksums.
5. On the configured check day (`BACKUP_SCHEDULE_CHECK_DAY`, default `Sun`),
   runs `restic check` against each configured repository. This is
   deliberately not every night — a full repository check reads more data
   and takes longer than a plain backup, so it runs weekly by default.

If this host has no `systemd` (containers, WSL), `schedule enable` warns and
does nothing further — run `sentinel-ops schedule run-now` by hand instead
(from your own cron, if you want it scheduled anyway).

`sentinel-ops status` and `sentinel-ops remote status` both show the last
replication and check time for each configured role, so a silent offsite
failure doesn't go unnoticed.

## Verification: what this does and doesn't check

Every backup is checksummed (`checksums.txt`), and `sentinel-ops backup
verify` / the scheduled cycle both recompute and compare those hashes before
trusting a backup. Configured repositories get a periodic `restic check`,
which verifies the repository's internal structure and that its data is
readable.

This is **not** an automated restore drill — nothing spins up a scratch
database to prove a backup actually restores end-to-end. Periodically test a
real restore yourself, ideally on a disposable install (`sentinel-ops nuke &&
sentinel-ops install`, then restore into it), especially after changing
Postgres versions or the backup layout.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `remote ... configure` fails to install restic | No network access, or an unsupported architecture for the static-binary fallback — install `restic` yourself and re-run `configure`. |
| `restic_init`/`configure` fails | The repository URL or backend credentials are wrong. Re-run `configure` to update them. |
| Scheduled cycle logs a replication warning | `sentinel-ops remote <role> status` — check the last-backup time, then `sentinel-ops remote <role> check` for a repository-level check. |
| `schedule enable` warns "systemctl not available" | No systemd on this host. Run `sentinel-ops schedule run-now` from your own cron instead. |
| Rotating a leaked/expired backend credential | `sentinel-ops remote <role> configure` again — it overwrites `config/restic-<role>.env`. |
| Backup verification fails | The backup is corrupt — do not restore it. Fall back to an older local backup, or a secondary/offsite snapshot: `sentinel-ops restore --from=secondary`. |
| "Not enough free space for a ... backup" | `sudo sentinel-ops cleanup --dry-run` to see what retention would free, then `sudo sentinel-ops cleanup`. If that is not enough, lower `BACKUP_RETENTION_COUNT`/`BACKUP_RETENTION_MAX_GB` and run cleanup again, or see [OPERATIONS.md](OPERATIONS.md#disk-space). |
| Logs or telemetry are empty after a restore | Expected: their data is not backed up (see [What a backup leaves out](#what-a-backup-leaves-out)). They fill up again on their own. |
| `backups/` is much bigger than expected | `sentinel-ops backup size` shows which tables are large and whether backups take them; add the large regenerable ones to `BACKUP_EXCLUDE_DATA`. `sentinel-ops backup list` shows each backup's size and scope. Backups taken before database-only backups existed are all full; retention removes them as newer ones arrive, or straight away with `sentinel-ops cleanup`. |
