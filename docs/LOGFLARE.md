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

## Backend

The Postgres backend, which is what the upstream overlay wires up by default.
`POSTGRES_BACKEND_URL` is supplied by the overlay itself; the installer only
sets `POSTGRES_BACKEND_SCHEMA` (to `_analytics`) when the overlay has not
already set it.

Upstream notes that this backend is **not optimised for high-volume inserts or
heavy querying**, and offers BigQuery as a production alternative. Configuring
BigQuery is not automated here: it needs a Google Cloud project with billing
enabled and a service-account key, which is an operator decision rather than
something an installer should prompt for. To use it, set `GOOGLE_PROJECT_ID`,
`GOOGLE_PROJECT_NUMBER` and mount `gcloud.json` in `supabase/.env` per the
upstream reference — those variables are read by the overlay, not by this
installer, so nothing here fights the change.

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

Nothing else is removed. The logs already collected stay in the `_analytics`
schema of the `_supabase` database (backups already exclude them), and the
`LOGFLARE_*` secrets stay in `supabase/.env`, so `enable` picks up where it
left off. Studio's Logs pages are empty while it is off. To reclaim the space
for good:

```bash
cd /opt/sentinel-ops/supabase
docker compose exec db psql -U postgres -d _supabase -c 'DROP SCHEMA _analytics CASCADE;'
```

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
