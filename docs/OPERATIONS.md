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
6. Apply pending migrations
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
application update, before every Supabase update and before any restore, and
capture the whole stack (database, Storage files, edge functions and the
config needed to rebuild the install) — not just the database.

> `restore` replaces the current database contents. It takes a safety copy of
> the current state first, so a bad restore is still recoverable.

See [BACKUPS.md](BACKUPS.md) for the full backup layout, retention, restore
flags, and setting up a real 3-2-1 setup (a second local/attached copy plus an
offsite one, both replicated by [restic](https://restic.net) on a schedule).

## Disk space and old images

### Where the disk goes

```bash
sudo sentinel-ops disk
```

Measures everything and draws it as bars:

- **Filesystem:** how full it is, and how the used space splits between
  *Sentinel Ops* (everything this installation owns, files and Docker alike),
  *other Docker workloads and build cache*, and *the rest of the system*. This
  answers "is it us?" at a glance.
- **Sentinel Ops in detail:** database, its write-ahead log, Storage files,
  local backups, installer logs, edge functions, the application checkout;
  then in Docker the application and Supabase images (with how many are
  superseded), each container's log file and whether it is rotated, and
  container layers.
- **Inside the database:** size per database, so Logflare's analytics events
  (database `_supabase`) show up apart from the application's data, and the
  largest tables, with the known self-growing ones named
  (`cron.job_run_details`, `auth.audit_log_entries`, ...).
- **Outside Sentinel Ops:** the systemd journal, `/var/log`, `/tmp` and
  `/home`, for comparison only.
- **Can be reclaimed**, numbered. At a terminal you are then asked which to
  clean up (`1 3`, `a` for all of them, Enter for none).

Measuring runs `du` over the database and Storage, so it takes a while on a
large installation. It reads only; nothing is removed without asking.

### Reclaiming space

```bash
sudo sentinel-ops disk prune all --dry-run   # what would go
sudo sentinel-ops disk prune all             # images, logs, backups
sudo sentinel-ops disk prune container-logs  # only when named
```

| Target | Removes | Keeps |
|---|---|---|
| `images` | the same as `cleanup` below: old application builds, superseded Supabase images, build cache unused for `IMAGE_BUILD_CACHE_MAX_AGE` | deployed, rollback and `:latest` images; anything a container uses |
| `logs` | installer logs in `logs/` older than `LOG_RETENTION_DAYS` (default 30) | newer logs, and the log of the run in progress |
| `backups` | local backups beyond `BACKUP_RETENTION_COUNT` (normally already enforced after each backup) | the newest `BACKUP_RETENTION_COUNT` |
| `container-logs` | empties the JSON log file of each of this stack's containers | other workloads' containers; the containers themselves |

`all` is `images logs backups`. `container-logs` is not part of it because it
throws away what the services have printed so far; ask for it by name. Pruning
takes the update lock, so it never runs alongside an update or a backup.

The database and Storage are never pruned: they are your data. If they are
what is large, the report tells you which table, and that is a decision for
the application, not the installer.

If container logs keep coming back, they are not rotated. The report says
so; set a default in `/etc/docker/daemon.json`, restart Docker and recreate
the containers, since the setting only applies to new ones
(`docker compose up -d --force-recreate` in `supabase/`, and
`sentinel-ops update app` for the frontend):

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "3" } }
```

### Old images after updates

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

To see what would go, or to clean up an installation that built up images
before this existed:

```bash
sudo sentinel-ops cleanup --dry-run
sudo sentinel-ops cleanup
```

`sentinel-ops status` shows free space where Docker keeps its data (and warns
below 10%) along with how much of the image store is reclaimable.

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
| `ENABLE_LOGFLARE` | `sentinel-ops install` (re-runs the analytics phase) |
| `STORAGE_FILE_SIZE_LIMIT` | `sentinel-ops repair apply` (rewrites the storage overlay and recreates `storage`) |
| `IMAGE_CLEANUP_ENABLED`, `IMAGE_BUILD_CACHE_MAX_AGE` | Nothing - read by the next update or `sentinel-ops cleanup` |
| `LOG_RETENTION_DAYS` | Nothing - read by the next `sentinel-ops disk` |

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
