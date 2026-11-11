# Operations runbook

## Deploying a new application release

```bash
sentinel-ops update app
```

What happens, in order:

1. Verify the installation and that **Supabase is healthy** — nothing proceeds otherwise
2. Fetch and fast-forward the application checkout
3. Regenerate `app/.env` from the live Supabase configuration
4. Build the image, tagged `sentinel-ops:<git-sha>`
5. Back up the database
6. Apply pending migrations, with background jobs paused (see below)
7. Deploy edge functions
8. Verify the new image on a staging container, then swap the live one
9. Health-check; roll back automatically on failure
10. Record the deployed commit and image in `.state/`

Steps 1–4 make no changes to the running deployment. A build failure or an
inaccessible repository costs nothing.

### Ordering

The frontend is never considered deployed until the database and functions are
ready:

```
Supabase → migrations → edge functions → frontend image → frontend container
```

### Background jobs and locks during migrations

The application's pg_cron jobs keep writing while migrations run: the agent
ingest drains (`agent-ingest-drain-1m`, `agent-ingest-audit-logs-1m`) handle a
batch per run in one transaction, which can take tens of seconds. A migration
that needs a strong lock on one of their tables (a policy, `ALTER TABLE`, an
index build) used to wait for them, and every later query on that table queued
behind it: the console stalled and the update looked hung.

Now, when there are pending migrations:

1. Every active pg_cron job is paused, and runs already in progress are given
   up to `SO_MIGRATION_JOB_WAIT` seconds (120) to finish. Agents keep sending;
   their data waits in pgmq and is drained after the update.
2. Each migration runs with `lock_timeout = SO_MIGRATION_LOCK_TIMEOUT` (15s).
   One that can't get a lock in time, or loses a deadlock, is rolled back and
   retried up to `SO_MIGRATION_LOCK_RETRIES` times (5), waiting
   `SO_MIGRATION_RETRY_DELAY` seconds (5) doubled each time. Each retry names
   the session holding the lock:

   ```
   [WARN]    A lock was not free within 15s; rolled back, retry 1/5 in 5s
   [WARN]      waiting on pid 4123 (pg_cron: agent-ingest-drain-1m, 22s): select public._agent_ingest_drain(...)
   ```
3. The paused jobs are resumed, whether the migrations succeeded or not. Jobs
   that were already inactive stay inactive.

The paused job ids are kept in `.state/migrations-paused-cron-jobs` until they
are resumed. If an update is killed half-way, the next update or
`sentinel-ops repair apply` resumes them; `sentinel-ops repair check` reports
them.

The settings are environment variables, e.g.
`sudo SO_MIGRATION_LOCK_TIMEOUT=60s sentinel-ops update app`.

## Automatic application updates

```bash
sentinel-ops auto-update enable     # prompts for how often to check (default: hourly)
sentinel-ops auto-update status     # last check, last result, next check, any held commit
sentinel-ops auto-update run-now    # check now; update only if the branch has moved
sentinel-ops auto-update disable
```

A systemd timer (`sentinel-ops-autoupdate.timer`) checks the configured
branch. When it points at the commit already deployed, nothing else happens.
When it has moved, the timer runs exactly `sentinel-ops update app`, with the
backup, staged deploy and health checks described above. Each day's checks
are logged to `logs/auto-update-<date>.log`, and the systemd journal has them
too (`journalctl -u sentinel-ops-autoupdate`).

- **A failed auto-update is not retried** for the same commit. It waits for a
  newer commit or a manual `sentinel-ops update app`.
- **`rollback` is respected.** The commit you rolled back from is not
  redeployed. Auto-update resumes when the branch moves past it.
- **Only one update runs at a time.** A manual `update`/`rollback` started
  while an auto-update is running refuses with a message rather than
  interleaving with it. An auto-update that finds a manual one running skips
  that cycle.
- **Low disk space skips the update.** While less than
  `AUTO_UPDATE_MIN_FREE_GB` (default 5) is free on the installation's or
  Docker's filesystem, the cycle logs an error and does nothing. It tries
  again on the next cycle. `0` turns this check off.
- Disabling stops future checks. An update already in progress is left to
  finish.

Auto-update deploys the application only. Supabase updates and installer
updates stay manual.

## Deploying a different branch

```bash
sentinel-ops branch                 # configured vs deployed branch
sentinel-ops branch set dev         # switch, then offers to deploy it now
```

`branch set` checks that the branch exists on the repository, saves
`APP_BRANCH` in `config/installer.env` and offers to run
`sentinel-ops update app`, which checks the branch out and deploys it with the
usual backup and migrations. If you decline, the next `update app` deploys it,
and so does auto-update at its next check: auto-update always follows the
configured branch.

Migrations are only ever applied forward. If the new branch does not contain
the deployed commit (going from `dev` back to `main`, for example), the
command warns and asks first. Migrations the old branch applied stay applied,
so if the new branch cannot run against that schema, restore a backup taken
while it was deployed (see [BACKUPS.md](BACKUPS.md)).

This only chooses the application branch. The installer's own branch is
`INSTALLER_BRANCH` (see below).

## Updating the installer itself

```bash
sentinel-ops self-update            # same as: sentinel-ops update installer
sentinel-ops self-update check      # show what would change, change nothing
sentinel-ops self-update from /path/to/SentinelOps-installer   # from a local checkout
```

This replaces the installed copy of this tool (`bin/`, `lib/`, `assets/` under
the installation directory) with the latest from the installer repository's
`main` branch. To track another branch, set `INSTALLER_BRANCH` in
`config/installer.env`, or set `SENTINEL_OPS_INSTALLER_BRANCH` for one run.
The deployed stack is not touched. Run `sentinel-ops update app` afterwards if
you also want a new release.

It can run at any time, including while an auto-update is in progress. That
update finishes on the installer code it started with, and the next check uses
the new copy. Downloads are checked for completeness and shell syntax before
anything is replaced.

Installations made before this command existed need one last refresh the old
way: `sudo ./install.sh` from an up-to-date checkout.

**Putting the previous installer back.** The replaced copy is kept until the
next self-update:

```bash
cd /opt/sentinel-ops
for d in bin lib assets; do sudo rm -rf "$d" && sudo mv ".installer-prev/$d" "$d"; done
```

## Updating Supabase

```bash
sentinel-ops update supabase
```

Takes a **mandatory** backup first and aborts if it fails. Refreshes the
deployment files while preserving `.env`, the database, storage and the deployed
edge functions, re-applies the installer-owned configuration, pulls images,
restarts, health-checks, and verifies Logflare.

If the stack does not come back healthy, the failure message names the
pre-update backup directory.

## Backups

```bash
sentinel-ops backup create
sentinel-ops backup list
sentinel-ops restore 2026-09-11-121500     # or omit for the latest
```

Backups are taken automatically before the first migration run, before every
application update, before every Supabase update and before any restore. A
full backup captures the whole stack (database, Storage files, edge functions
and the config needed to rebuild the install). The backups before an
application update leave Storage out, since those updates never touch it.
No backup takes log or telemetry data (Logflare's log store, Supabase's
housekeeping logs, the application's rolling telemetry). Those tables come
back empty after a restore. `sentinel-ops backup size` shows what is large.

> `restore` replaces the current database contents. It takes a safety copy of
> the current state first, so a bad restore is still recoverable.

See [BACKUPS.md](BACKUPS.md) for the full backup layout, retention, restore
flags, and setting up a real 3-2-1 setup (a second local/attached copy plus an
offsite one, both replicated by [restic](https://restic.net) on a schedule).

## Disk space

Everything the installation writes has a limit:

| What | Limit | Setting (`config/installer.env`) |
|---|---|---|
| Local backups | count and total size, oldest removed first - see [BACKUPS.md](BACKUPS.md#retention) | `BACKUP_RETENTION_COUNT` (10), `BACKUP_RETENTION_MAX_GB` (`auto`: a fifth of the disk) |
| Container logs (Supabase, frontend, MDM proxy) | files per container, each at most this size | `CONTAINER_LOG_MAX_FILES` (3), `CONTAINER_LOG_MAX_SIZE` (`50m`) |
| Installer logs in `logs/` | removed after this many days | `LOG_RETENTION_DAYS` (30; `0` keeps them) |
| Docker images and build cache | see below | `IMAGE_CLEANUP_ENABLED`, `IMAGE_BUILD_CACHE_MAX_AGE` |

`sentinel-ops cleanup` applies all of them at once: it prunes backups past
retention, removes old installer logs and removes superseded images.
`--dry-run` shows what would go. Updates do the same after they succeed.

```bash
sudo sentinel-ops cleanup --dry-run
sudo sentinel-ops cleanup
```

`sentinel-ops status` shows free space where Docker keeps its data (and warns
below 10%), how much of the image store is reclaimable, and how much
`backups/` and `logs/` hold.

### Container logs

Docker keeps a container's output forever unless told otherwise, and Supabase's
containers write a lot of it. The Supabase stack gets its limit from a
generated Compose overlay, `supabase/docker-compose.sentinel-logging.yml`,
registered in `COMPOSE_FILE` like the storage and auth overlays. The frontend
and MDM proxy containers get it on their `docker run` command line.
`/etc/docker/daemon.json` is not changed, so other containers on the host keep
their own settings.

A changed limit only applies to a recreated container. `install`,
`update supabase` and `repair apply` regenerate the overlay and recreate what
changed. The frontend picks up a change on its next deployment.
`sentinel-ops repair check` reports a missing overlay.

On an installation from before the limit existed:

```bash
sudo sentinel-ops self-update
sudo sentinel-ops repair apply     # writes the overlay and recreates the Supabase containers
sudo sentinel-ops cleanup
```

Recreating the containers starts their logs from empty. The old, unlimited log
files are removed along with the old containers.

### Old images

Every update leaves images behind: each application build is tagged
`sentinel-ops:<commit>`, and each Supabase update pulls new versions of a dozen
service images. With auto-update on, that adds up quickly, so both updates
clean up after themselves once they have succeeded:

| After | Removed | Kept |
|---|---|---|
| `update app` | every other `sentinel-ops:*` tag; untagged leftovers of this installer's own builds; build cache unused for `IMAGE_BUILD_CACHE_MAX_AGE` (default `168h`) | the deployed image, the image `rollback` returns to, `:latest` |
| `update supabase` | older tags of each image repository the Supabase compose files use | the versions the compose files name now |

Anything a container still uses - running or stopped - is never removed, and
removal is never forced. Images from other repositories (your reverse proxy,
other workloads) are never touched. A failed update removes nothing, and a
cleanup problem is only a warning: it never fails the update.

An installation that built up images before this existed is cleaned up by
`sentinel-ops cleanup` as above.

Two things to know on a shared host:

- **Build cache** cannot be told apart by project, so the age-based prune
  applies to every build on the host. It is only cache: nothing breaks, an
  unrelated build that has not run for a week just starts cold.
- **Other Supabase stacks** use the same image repositories (`supabase/gotrue`,
  `supabase/storage-api`, ...). Their older versions are removed after
  `update supabase` unless a container still uses them.

To manage images yourself instead, set `IMAGE_CLEANUP_ENABLED=false` in
`config/installer.env`; `sentinel-ops cleanup` still works on demand.

## Rolling back

```bash
sentinel-ops rollback
```

Restores the previous image and moves the checkout back to the previous commit.

**Migrations are not reverted.** If the release included a breaking schema
change, restore the matching backup explicitly — `rollback` prints its path.

## Troubleshooting

Always start here:

```bash
sentinel-ops status
```

| Symptom | Where to look |
|---|---|
| Install failed mid-way | `sentinel-ops logs installer`, then re-run — completed phases are skipped |
| Frontend not responding | `sentinel-ops logs app` |
| Supabase unhealthy | `sentinel-ops logs supabase` |
| TLS / routing not working | Your reverse proxy — see [REVERSE-PROXY.md](REVERSE-PROXY.md). Realtime needs WebSocket headers. |
| Large uploads fail (App Catalog installers) | `sentinel-ops status` (Storage's upload limit), then `sentinel-ops domain status` (the proxy) — see [REVERSE-PROXY.md](REVERSE-PROXY.md#things-that-will-bite-you) |
| No logs in Studio | [docs/LOGFLARE.md](LOGFLARE.md) |

### "Supabase health check failed"

Installation stops rather than deploying an application against a broken
database. Common causes: insufficient memory (the stack wants ~4 GB), a port
already bound on 8000, or images that failed to pull.

```bash
cd /opt/sentinel-ops/supabase && docker compose ps
```

### "Cannot fast-forward … to origin/main"

The checkout at `/opt/sentinel-ops/app` was edited locally. The installer
refuses to discard that silently.

```bash
git -C /opt/sentinel-ops/app status
git -C /opt/sentinel-ops/app stash      # or reset --hard origin/main to discard
```

### "Cannot access …repository with the supplied deployment key"

```bash
GIT_SSH_COMMAND="ssh -i /opt/sentinel-ops/config/deploy_key -o IdentitiesOnly=yes" \
    git ls-remote git@github.com:BrainStation-23/sentinel-ops.git
```

Check the key is registered as a deploy key on the repository, and that it is
the private key rather than the `.pub`.

### A migration failed

Each migration runs in a single transaction together with the row recording it,
so a failure leaves neither partial schema changes nor a bogus tracking entry.

The failure report on the console shows PostgreSQL's error (with its SQLSTATE,
`DETAIL`, `HINT` and, for functions and `DO` blocks, `CONTEXT`), the failing
statement with its line numbers in the migration file, the exact line when
PostgreSQL gives a position, and a hint for common causes (object already
exists, missing dependency, permission, existing data violating a new
constraint, lock timeout). psql's complete output is in the run's log under
`logs/`, path printed at the end of the report.

```
[ERROR] Migration failed: 20240104000000_add_x.sql
        ERROR:  42601: syntax error at or near "c"
        LINE 4:     c int
                    ^
[ERROR] At supabase/migrations/20240104000000_add_x.sql:4 (statement on lines 1-5):
           1 | CREATE TABLE x (
           2 |     a int,
           3 |     b int
     >     4 |     c int
           5 | );
```

A migration still blocked after every retry fails with `55P03` (lock timeout)
or `40P01` (deadlock), and the report names the session that held the lock.
Wait for it to finish, or stop it, and run the update again. Background jobs
are resumed either way.

Which migrations are pending is worked out by the database (the file versions
not in `supabase_migrations.schema_migrations`), and each migration checks again
in its own transaction, before any of its SQL runs, that its version isn't
recorded yet. One that is gets `Already recorded; skipped without running it.`
instead of running a second time.

Two migration files with the same version prefix are refused before anything
runs. Otherwise the second would look already applied and never run.

Fix the migration in the repository and re-run `sentinel-ops update app`;
already-applied migrations are skipped.

Tracking lives in `supabase_migrations.schema_migrations` — the same table the
Supabase CLI uses, so `supabase db push` stays compatible.

### Re-running a failed install

Just run it again. Phase markers in `.state/phases/` mean Supabase is not
reinstalled, secrets are not regenerated, volumes are not deleted and the
repository is not re-cloned.

```bash
sudo sentinel-ops install            # resume
sudo sentinel-ops install --force    # re-run completed phases too
```

## Changing configuration

Edit `/opt/sentinel-ops/config/installer.env`, then apply:

| Changed | Apply with |
|---|---|
| `SUPABASE_PUBLIC_URL`, `SITE_URL`, `API_EXTERNAL_URL` | `sentinel-ops update app` (restarts the container with the new values — read from `process.env` at runtime, not baked into the bundle) |
| `APP_BRANCH` | `sentinel-ops branch set <name>` (saves and deploys in one step) |
| `APP_REPOSITORY` | `sentinel-ops update app` |
| `APP_BIND`, `APP_PORT` | `sentinel-ops update app` |
| `ENABLE_LOGFLARE` | `sentinel-ops logflare enable` / `disable` (sets it and applies it) |
| `STORAGE_FILE_SIZE_LIMIT` | `sentinel-ops repair apply` (rewrites the storage overlay and recreates `storage`) |
| `IMAGE_CLEANUP_ENABLED`, `IMAGE_BUILD_CACHE_MAX_AGE` | Nothing - read by the next update or `sentinel-ops cleanup` |

Changing a URL requires a **restart**, not a rebuild: the app reads
`SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` from `process.env` at runtime via
`/runtime-config.js`.

### Storage on S3

The installer deploys Storage with its file backend (`supabase/volumes/storage`).
If you move it to an S3 backend yourself, add a lifecycle rule to that bucket
that aborts incomplete multipart uploads after a couple of days
(`AbortIncompleteMultipartUpload`, `DaysAfterInitiation: 2`). A resumable
upload that is abandoned half way - a closed tab, a dropped connection - leaves
its parts behind as an incomplete multipart upload, which neither Storage nor
the application lists or cleans up, and the provider bills for them.

## Stopping without destroying anything

```bash
cd /opt/sentinel-ops/supabase && docker compose down      # keeps volumes
docker rm -f sentinel-ops-frontend
```

The database survives; `sentinel-ops install` brings it all back.

## Uninstalling, and testing a fresh install

```bash
sudo sentinel-ops nuke
```

This is the counterpart to `install`. In order, it:

1. Stops and removes the auto-update and backup timers, so neither fires
   during or after the teardown
2. Removes the frontend container and its staging container
3. Runs `docker compose down -v --remove-orphans` — **this destroys the
   database and all uploaded objects**
4. Sweeps up anything still labelled with the Compose project, in case the
   compose file was already missing or unreadable
5. Removes the `sentinel-ops:*` images
6. Deletes `/opt/sentinel-ops` and the `/usr/local/bin/sentinel-ops` symlink

Docker is torn down **before** the filesystem on purpose: `compose down` needs
`supabase/docker-compose.yml` and `supabase/.env` to know what to remove, so
deleting the directory first would orphan every container and volume.

| Flag | Effect |
|---|---|
| `--keep-backups` | Keeps `backups/` |
| `--keep-config` | Keeps `config/` — `installer.env` and the deploy key |
| `--keep-all` | Both |
| `--yes` | Skips the typed confirmation (for scripted loops) |

Confirmation is the typed word `nuke`, not a y/N prompt. Without a terminal and
without `--yes` it refuses and exits **2**, so a script that runs
`sentinel-ops nuke && ./install.sh` cannot mistake a missing terminal for a
completed teardown.

**Not removed:** Supabase's pulled images (re-pulling is several GB per cycle
and a cached image cannot make an install stale) and Docker itself (a
prerequisite, not part of the deployment).

### The reinstall loop

```bash
sudo sentinel-ops nuke --keep-config --yes
sudo ./install.sh --yes
sentinel-ops status
```

`--keep-config` preserves `installer.env` and `deploy_key`, so the reinstall
needs no prompts and no re-copied key. Phase markers under `.state/` are always
removed, so every phase genuinely re-runs rather than reporting *already
completed*.

If Docker is not running when you nuke, the files are removed but the
containers and volumes survive — the command says so. Start Docker and run it
again to clear them.
