# Supabase Analytics (Logflare)

Follows the official reference:
<https://supabase.com/docs/reference/self-hosting-analytics/introduction>

Analytics is deployed as a phase of its own. It is **not** assumed to exist just
because Supabase was installed.

```
Install Supabase → Start → Verify → Configure analytics → Enable overlay → Verify
```

## How it is enabled

Upstream ships analytics as an **optional compose overlay**, not as part of the
base stack. `run.sh config add logs` layers `docker-compose.logs.yml` on top of
`docker-compose.yml` and adds two services: **analytics** (Logflare) and
**vector** (log collection). It does this by managing `COMPOSE_FILE` in
`supabase/.env`.

That overlay is the **only** deployment path. The installer runs:

```sh
sh run.sh config add logs
sh run.sh start
```

If the Supabase release in use ships no `run.sh`, analytics is **skipped** with a
warning and the installation continues. Logflare is a log aggregator, not a
dependency of the application, and standing up a parallel compose stack to work
around a missing upstream mechanism would only create something else to keep in
sync.

> Because `COMPOSE_FILE` drives which services exist, the installer never passes
> `-f docker-compose.yml` to Compose. Doing so would silently drop the analytics
> and vector services from every `ps`, `logs`, `up` and `down`.

## The pipeline

```
Docker container stdout/stderr
        │
        ▼
     vector            reads the Docker socket, ships to Logflare
        │
        ▼
   Logflare :4000      ingest + query API  (NOT published to the host)
        │
        ▼
     Postgres          the _analytics schema
        │
        ▼
  Supabase Studio      the Logs views
```

## Where the logs are stored

Logflare always runs on this server, and its own small metadata tables (sources,
settings) always stay in the local `_supabase._analytics` schema. The backend
decides where the **log tables** go - one `log_events_<source>` table per source,
which is where all the space is.

| `LOGFLARE_BACKEND` | Logs stored in | Set up with |
|---|---|---|
| `local` (default) | this server's `_supabase` database, schema `_analytics` | nothing - upstream's own wiring |
| `remote` | the `_analytics` schema of a Postgres on another host | a `postgres://` URL |
| `bigquery` | Google BigQuery | a GCP project ID, project number and service-account key |

Chosen at install time, and changed later with:

```bash
sudo sentinel-ops logflare backend            # asks
sudo sentinel-ops logflare backend remote
sudo sentinel-ops logflare backend bigquery
sudo sentinel-ops logflare backend local
```

Switching checks the new backend first (a remote URL must connect, and the
`_analytics` schema must exist or be creatable; BigQuery needs Docker Compose
2.24+), then restarts analytics. **Logs already collected stay where they were**
and Studio stops showing them. To free that space, purge before switching.

Upstream calls the Postgres backend fine for getting started but **not optimised
for high-volume inserts**, and recommends BigQuery for production.

### How it is wired

`local` uses upstream's overlay exactly as shipped. For the others the installer
generates `docker-compose.sentinel-analytics.yml` and lists it in `COMPOSE_FILE`
**after** `docker-compose.logs.yml`, so it overrides the `analytics` service:

- **remote** sets `POSTGRES_BACKEND_URL: ${LOGFLARE_REMOTE_BACKEND_URL}`. The URL
  itself is only in `supabase/.env`; the overlay holds no secret.
- **bigquery** removes `POSTGRES_BACKEND_URL` and `POSTGRES_BACKEND_SCHEMA` with
  Compose's `!reset` tag, sets `GOOGLE_PROJECT_ID`/`GOOGLE_PROJECT_NUMBER`, and
  mounts `supabase/gcloud.json` at `/opt/app/rel/logflare/bin/gcloud.json`.
  Removing matters: Logflare picks BigQuery only when the Postgres URL is
  **absent** - an empty value still selects Postgres.

The overlay is listed only while upstream's is (it adds to a service upstream's
overlay defines), and is re-applied by `update supabase` and `repair apply`.

### Remote Postgres

The URL is `postgresql://user:password@host:5432/dbname`, optionally with
`?sslmode=require`. Percent-encode `$`, quotes and spaces in the password
(`$` becomes `%24`): Compose would read `$` as a variable. The user must be able
to create tables in the `_analytics` schema of that database, and to create the
schema unless it already exists. The connection is made from the database
container, so the host must be reachable from Docker's network.

### BigQuery

Needs a Google Cloud project with billing enabled, its project ID and project
number, and a JSON key for a service account with BigQuery access - see the
[upstream reference](https://supabase.com/docs/reference/self-hosting-analytics/introduction)
for the exact roles. The installer copies the key to `supabase/gcloud.json`
(mode 600). Purge and retention do not apply: set a table expiration on the
dataset in Google Cloud instead.

## Deleting collected logs

```bash
sudo sentinel-ops logflare purge                    # everything, asks first
sudo sentinel-ops logflare purge --older-than 30    # only older logs
sudo sentinel-ops --yes logflare purge              # no question (scripts)
```

`purge` works whether Logflare is enabled or disabled, on the local or remote
backend. It only touches the `log_events_*` tables, never Logflare's metadata, so
`enable` afterwards carries on as before. A full purge truncates, which hands the
space straight back to the disk. `--older-than` deletes rows and runs a plain
`VACUUM`, so the space is reused by new logs rather than returned. Purged logs
cannot be restored: backups already leave them out.

### Retention

```bash
sudo sentinel-ops logflare retention          # show
sudo sentinel-ops logflare retention 7        # keep a week
sudo sentinel-ops logflare retention off
sudo sentinel-ops logflare prune              # apply it now
```

The setting is `LOGFLARE_RETENTION_DAYS` in `config/installer.env`. New installs
are asked, with 7 offered. Installations from before this setting have it empty,
which means off, so nothing is deleted until someone chooses a number. When set,
a daily systemd timer (`sentinel-ops-logflare-retention.timer`) runs
`logflare prune`. It stays while Logflare is disabled, so what was collected
before still ages out, and it skips a run while an update holds the lock.

## Variables the installer owns

All in `supabase/.env`, written by `logflare_configure_supabase()` and
re-applied after every Supabase update so an upstream `.env.example` change
cannot silently revert them.

| Variable | Purpose |
|---|---|
| `LOGFLARE_SINGLE_TENANT` | `true` — no account creation; one implicit tenant |
| `LOGFLARE_SUPABASE_MODE` | `true` — seeds the Supabase log sources Studio expects |
| `LOGFLARE_PUBLIC_ACCESS_TOKEN` | Ingest token. vector authenticates with it. |
| `LOGFLARE_PRIVATE_ACCESS_TOKEN` | Query/management token. Studio reads logs with it. |
| `LOGFLARE_DB_ENCRYPTION_KEY` | **Base64** key encrypting sensitive Logflare columns. Required in production. |
| `LOGFLARE_DB_ENCRYPTION_KEY_RETIRED` | Empty except during a key rotation. |
| `POSTGRES_BACKEND_SCHEMA` | `_analytics`, unless the overlay already set it. |
| `LOGFLARE_REMOTE_BACKEND_URL` | `remote` backend only: the `postgres://` URL. |
| `GOOGLE_PROJECT_ID`, `GOOGLE_PROJECT_NUMBER` | `bigquery` backend only. |
| `DOCKER_SOCKET_LOCATION` | Socket vector mounts to collect container logs. Defaults to `/var/run/docker.sock`; differs under rootless Docker and Podman. |

Both tokens and the encryption key are generated **once**, at installation, and
never rotated automatically. They must match on both sides — vector, Logflare
and Studio all read them from this same file.

### Rotating the encryption key

Move the current value to `LOGFLARE_DB_ENCRYPTION_KEY_RETIRED`, put the new key
in `LOGFLARE_DB_ENCRYPTION_KEY`, restart, and clear the retired key once
Logflare has re-encrypted. The installer does not automate this.

## Health

Port 4000 is **not published to the host** — upstream restricts access to the
API gateway. `logflare_check()` therefore probes in layers:

1. an in-container HTTP request to `127.0.0.1:4000/health` (`curl`, then `wget`)
2. Docker's own healthcheck verdict

A Logflare that is running but not answering is reported as a **warning**, not a
failure: degraded log aggregation should never take the application offline. The
install phase as a whole is non-fatal for the same reason — a failure leaves the
phase marker unset, so re-running the installer retries it.

First boot is slow because Logflare runs its own database migrations — the
health check allows 180 seconds.

## Security

> **Logflare's `/dashboard` has no authentication of its own.** Access must be
> restricted at the network level. Do not publish port 4000 and do not proxy it
> to the internet. The installer prints this warning after every deployment.

## Turning it on or off

Answer *no* at install time to skip the phase. On a running installation:

```bash
sudo sentinel-ops logflare status    # configuration vs. what Compose runs
sudo sentinel-ops logflare disable
sudo sentinel-ops logflare enable
```

`disable`:

1. sets `ENABLE_LOGFLARE=false` in `config/installer.env`, so `status` reports
   it disabled and `update supabase` stops re-applying and health-checking it;
2. removes `docker-compose.logs.yml` from `COMPOSE_FILE` (through `run.sh config
   remove logs`, then directly if it is still listed);
3. regenerates the container log-limit overlay. It names every service, so
   left alone it would still define `analytics` and `vector` without an image
   and Compose would refuse to start the stack;
4. runs `up -d --remove-orphans`, which removes the `analytics` and `vector`
   containers. A plain `run.sh start` / `up -d` would leave them running.

It also takes `docker-compose.sentinel-analytics.yml` out of `COMPOSE_FILE`
(the file stays; `enable` lists it again).

Nothing else is removed. The logs already collected stay where they are (backups
already exclude them), the retention timer keeps ageing them out, and the
`LOGFLARE_*` secrets stay in `supabase/.env`, so `enable` picks up where it left
off. Studio's Logs pages are empty while it is off. To reclaim the space now:
`sudo sentinel-ops logflare purge`.

> Do not `DROP SCHEMA _analytics`. The schema also holds Logflare's own
> metadata, and is created by Supabase's database init scripts, which only run
> on a fresh database - so a later `enable` would fail.

`enable` needs the Supabase release's `run.sh`, exactly like the install phase.

## Troubleshooting

```bash
sentinel-ops logs logflare
sentinel-ops status
```

**No logs in Studio.** Almost always a token mismatch or the Docker socket.
Confirm `LOGFLARE_PUBLIC_ACCESS_TOKEN` is identical everywhere it appears, and
that the socket exists:

```bash
grep DOCKER_SOCKET_LOCATION /opt/sentinel-ops/supabase/.env
ls -l /var/run/docker.sock
```

**Analytics service missing from `docker compose ps`.** The overlay is not
enabled. Check `COMPOSE_FILE`:

```bash
grep COMPOSE_FILE /opt/sentinel-ops/supabase/.env
# expect: docker-compose.yml:docker-compose.logs.yml
```

**Logflare restarting in a loop.** Usually the backend — confirm the
`_analytics` schema is reachable with the configured credentials.

**Errors about decrypting columns.** `LOGFLARE_DB_ENCRYPTION_KEY` changed after
data was written. Restore the previous key, or put it in
`LOGFLARE_DB_ENCRYPTION_KEY_RETIRED` and let Logflare re-encrypt.
