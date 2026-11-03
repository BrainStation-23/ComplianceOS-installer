# Sentinel Ops — Installer & Deployment

An installation and update system for the Sentinel Ops stack: self-hosted
**Supabase**, **Logflare**, and the **Sentinel Ops React frontend**, all running
under Docker.

A shell installer for Linux servers. A clean supported server plus a deployment
key becomes a working Sentinel Ops
installation with one command, and every subsequent release ships with
`sentinel-ops update app`.

---

## Quick start

Before you begin you need an **SSH deploy key** for the private Sentinel Ops
application repository, and DNS for your two hostnames already pointing at this
server. See [Before you install](#before-you-install).

Clone the installer and run it from a directory containing your `deploy_key`:

```bash
git clone https://github.com/BrainStation-23/SentinelOps-installer.git
cd SentinelOps-installer
cp /path/to/deploy_key ./deploy_key      # private SSH key for the app repo
chmod 600 ./deploy_key
chmod +x install.sh                      # git doesn't always preserve this bit - see below
sudo ./install.sh
```

`install.sh` is committed as executable, but some ways of getting the code
onto the server strip that bit anyway (a GitHub "Download ZIP", an `scp`/`rsync`
without `-p`, a corporate file-transfer tool) — `chmod +x` is a no-op if it's
already set, so it's safe to run unconditionally. If you forget it,
`./install.sh` fails with `Permission denied`; either run `chmod +x install.sh`
and retry, or run it via the interpreter instead: `sudo bash install.sh`.

After installation the `sentinel-ops` command is on `PATH`:

```bash
sentinel-ops                 # guided menu
sentinel-ops status          # what is actually running
sentinel-ops credentials     # generated Supabase credentials
```

### Non-interactive (CI, image bakes)

```bash
sudo ./install.sh --yes
```

`--yes` accepts every default. The endpoint defaults are this host's own
**LAN IP address** (detected automatically), and the frontend and Supabase API
are opened to the local network only — so a non-interactive run is reachable
from another device on the same network with no further configuration, but
not from the internet. To serve it under a real domain instead, install first
and then run `sentinel-ops domain set <hostname>` — no reinstall needed.

---

## Before you install

**Server:** Ubuntu 22.04/24.04, Debian, or RHEL/CentOS/Fedora. At least **4 GB
RAM** — the Supabase stack runs a dozen containers — and 20 GB of disk. Root or
sudo.

**Deploy key.** The application repository is private. Register an SSH deploy key
on it and put the **private** key (not the `.pub`) where the installer looks:

```
./deploy_key                        next to the installer, or the directory you run it from
/opt/sentinel-ops/deploy_key
/opt/sentinel-ops/config/deploy_key
```

```bash
chmod 600 deploy_key
```

Place it **before** running — it is needed partway through, after Supabase comes
up.

**DNS.** Only needed if you are serving this under a domain rather than on
localhost. Point both hostnames at this server before installing, so your
reverse proxy can obtain certificates:

```bash
dig +short app.your-domain.tld
dig +short supabase.your-domain.tld
```

**Firewall.** Nothing in this stack should be reachable from the public
internet except through your reverse proxy. Stock Ubuntu/Debian images ship
`ufw` installed but **inactive** — a fresh host is wide open until something
turns it on — so `sentinel-ops install` checks for this and, with your
confirmation, enables it itself: it allows the SSH port(s) actually configured
in `sshd_config` first (so it can never lock out the session doing the
install), then Supabase's gateway port and the frontend port (both scoped to
private/LAN address ranges — `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` —
not the world), then sets `default deny incoming` and enables `ufw`. Decline
the prompt and configure it yourself if you'd rather:

```bash
sudo ufw default deny incoming
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

> Supabase's compose file publishes Kong on `0.0.0.0:8000`. The `default deny
> incoming` rule above is what keeps it off the internet — do not skip it.
> On `firewalld` hosts the installer does not enable anything automatically:
> firewalld ships active by default on the distributions that use it, so an
> inactive one there is assumed to be a deliberate choice.

**Reverse proxy.** The installer does not install one. Point yours at the
upstreams it prints — see [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md).

**LAN access is on by default.** A fresh install binds the frontend to every
interface (Supabase's gateway already does — upstream's own default) and opens
both ports to private/LAN address ranges only, so it's reachable from other
devices on the same network with zero configuration. There is no TLS on either
port this way. `sentinel-ops network disable` reverts the frontend to
loopback-only at any time; `sentinel-ops network status` shows which mode is
active. Ready for a real domain instead? `sentinel-ops domain set <hostname>`
switches over with a config change and a restart — no reinstall.

---

## Commands

| Command | What it does |
|---|---|
| `sentinel-ops` | Guided menu; detects whether an installation exists |
| `sentinel-ops install` | First installation |
| `sentinel-ops update app` | Update the application only *(the common case)* |
| `sentinel-ops update supabase` | Update Supabase only |
| `sentinel-ops update all` | Update Supabase, then the application |
| `sentinel-ops self-update [check\|from <path>]` | Update this installer itself (also `update installer`); the stack is untouched - see [OPERATIONS.md](docs/OPERATIONS.md#updating-the-installer-itself) |
| `sentinel-ops auto-update [status\|enable\|disable\|run-now]` | Check the application branch on a timer and update **only** when it has a new commit - see [OPERATIONS.md](docs/OPERATIONS.md#automatic-application-updates) |
| `sentinel-ops branch [status\|set <name>]` | Choose the application branch to deploy (e.g. `dev`); `update` and auto-update follow it - see [OPERATIONS.md](docs/OPERATIONS.md#deploying-a-different-branch) |
| `sentinel-ops status` | Health and version of every component |
| `sentinel-ops credentials` | Show generated credentials (masked; `--show` to reveal) |
| `sentinel-ops backup [create\|list\|verify]` | Full-stack backups (database, Storage, functions, config) |
| `sentinel-ops restore [backup] [--scope\|--from]` | Restore a backup (latest local if omitted) - see [BACKUPS.md](docs/BACKUPS.md) |
| `sentinel-ops rollback` | Roll the application back to the previous image |
| `sentinel-ops cleanup [--dry-run]` | Remove superseded Docker images (also done after every update) - see [OPERATIONS.md](docs/OPERATIONS.md#disk-space-and-old-images) |
| `sentinel-ops logs <target>` | `app`, `supabase`, `logflare`, `installer` |
| `sentinel-ops remote [status\|secondary\|offsite]` | Configure the 3-2-1 replication targets - see [BACKUPS.md](docs/BACKUPS.md) |
| `sentinel-ops schedule [status\|enable\|disable\|run-now]` | Run backups on a systemd timer - see [BACKUPS.md](docs/BACKUPS.md) |
| `sentinel-ops network [status\|enable\|disable]` | Expose (or restrict) the frontend and Supabase API directly on the LAN |
| `sentinel-ops domain [status\|set <hostname>]` | Point the stack at a real domain (config + restart, no reinstall) |
| `sentinel-ops azure [status\|enable\|disable]` | Configure Azure AD (Microsoft Entra ID) sign-in |
| `sentinel-ops auth [status\|enable\|disable] <feature>` | Optional Supabase Auth hardening - see [AUTH-HARDENING.md](docs/AUTH-HARDENING.md) |
| `sentinel-ops mdm-proxy [status\|enable\|disable\|sync-cert]` | Windows MDM on a port of its own, for a front proxy that can't request client certificates (Zoraxy); its certificate from Zoraxy's files or from Let's Encrypt through Cloudflare DNS (`--cloudflare`) - see [WINDOWS-MDM.md](docs/WINDOWS-MDM.md) |
| `sentinel-ops repair [check\|apply]` | Validate `supabase/.env` for known mechanical mistakes and fix them; check/apply the backup restore grant |
| `sentinel-ops nuke` | **Destroy this installation** so a fresh one can be tested |

Global options: `--dir <path>`, `--yes`, `--show`, `--force`, `--debug`.

### Testing a fresh install on the same machine

`sentinel-ops nuke` is the counterpart to `install`: it removes the containers,
**all volumes including the database**, the application images and the
installation directory, leaving the host ready to install from scratch.

```bash
sudo sentinel-ops nuke                    # everything
sudo sentinel-ops nuke --keep-config      # keep installer.env and the deploy key
sudo sentinel-ops nuke --keep-backups     # keep the local backups
sudo sentinel-ops nuke --keep-all         # keep both
```

It asks you to type `nuke` to confirm. `--yes` skips that prompt for scripted
test loops; without a terminal and without `--yes` the command **refuses and
exits 2** rather than assuming an answer, so `nuke && install.sh` can never
install over a stack that is still running.

Supabase's pulled images are deliberately left on the host — re-pulling them is
several GB per cycle, and a cached image cannot make an install stale. `docker`
itself is a prerequisite, not part of the deployment, and is never touched.

`--keep-config` is the one to use for repeat runs: it preserves
`config/installer.env` and `config/deploy_key`, so the reinstall needs no
prompts and no re-copied key. Phase markers in `.state/` are always removed, so
every phase genuinely re-runs.

If a secondary or offsite backup repository is configured (see
[docs/BACKUPS.md](docs/BACKUPS.md)), nuke never touches it — those live on a
separate medium precisely so a mistake on this host can't take them out too.

---

## Supported systems

| Family | Distributions |
|---|---|
| Debian | Debian, Ubuntu (and derivatives via `ID_LIKE`) |
| RHEL | RHEL, CentOS, Fedora, Rocky, AlmaLinux |

The installer refuses to run on a non-Linux kernel. Prerequisites — `curl`,
`git`, `openssl`, `jq`, `ssh` — are verified and installed when missing.

Docker is checked at three levels, because `docker --version` succeeding proves
nothing: the **binary** exists, the **daemon** answers, and a **container
actually runs**.

---

## Layout on the server

```
/opt/sentinel-ops/
├── bin/sentinel-ops         the CLI (symlinked to /usr/local/bin)
├── lib/                     installer modules
├── assets/                  Dockerfile / compose templates
├── config/
│   ├── installer.env        persisted configuration
│   ├── deploy_key           chmod 600, used only for Git
│   ├── known_hosts          pinned Git host key
│   └── restic-<role>.pass/.env   3-2-1 repository credentials, chmod 600
├── supabase/
│   ├── .env                 ← secrets and state; never regenerated
│   ├── docker-compose.yml
│   └── volumes/             database data, storage, edge functions
├── app/                     the Sentinel Ops checkout
│   ├── .env                 generated from Supabase config
│   └── supabase/{migrations,functions}
├── backups/<timestamp>/     database.sql, storage.tar.gz, functions.tar.gz,
│                            config.tar.gz, checksums.txt, metadata.txt
├── logs/                    installer and auto-update logs
├── .installer-prev/         installer copy replaced by the last self-update
└── .state/                  deployed commit, image, versions, phase markers
```

---

## Runtime architecture

```
                Internet
                   │
                   ▼
          your reverse proxy          ← you manage this
              ┌────┴─────┐
              ▼          ▼
      127.0.0.1:8000   127.0.0.1:41820
      Supabase gateway  Sentinel Ops frontend
              │        (Node, Nitro SSR server)
              ▼
         PostgreSQL ──► Logflare / vector
```

**No reverse proxy is installed.** TLS, certificates and routing stay with the
host, to be handled however that host already does it. The installer's job is to
expose two stable upstreams and tell you what they are:

| Upstream | Default |
|---|---|
| Frontend | `127.0.0.1:41820` |
| Supabase API (Kong) | `127.0.0.1:8000` |

The frontend's default is deliberately not 3000: Supabase's own Studio always
claims that port, and Kong/Postgres/the pooler always claim 8000/5432/6543, so
those four are never offered. `sentinel-ops install` validates whatever port
you choose against this list and against anything else already listening,
before it ever tries to bind it.

Where they listen depends on the mode. A fresh install defaults to **LAN
access**: the frontend binds to every interface and the firewall opens both
ports to private address ranges only. `sentinel-ops network disable`, or moving
to a domain with `sentinel-ops domain set`, binds the frontend back to loopback
(`APP_BIND=127.0.0.1`), so only a proxy on this host reaches it. Kong always
publishes on `0.0.0.0:8000` (upstream's default), and the firewall's `default
deny incoming` is what keeps it off the internet. Supabase's own Kong gateway is
left in place rather than duplicated.

See [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md) for nginx, Caddy and Traefik
examples, and the WebSocket/upload-size gotchas worth knowing about.

---

## What is safe across updates

`sentinel-ops update app` never touches Supabase's version, secrets,
configuration or volumes. `sentinel-ops update supabase` refreshes the
deployment scaffolding and images while preserving:

- `supabase/.env` — secrets are generated once and never regenerated
- `supabase/volumes/db/data` — the database
- `supabase/volumes/storage` — uploaded objects
- `supabase/volumes/functions` — deployed edge functions

A database backup is **mandatory** before a Supabase update; the update aborts
if the backup fails.

---

## Idempotency

Every expensive installation phase is guarded by a marker in `.state/phases/`.
If an install fails at the frontend build, fixing the problem and re-running
resumes from there: Supabase is not reinstalled, secrets are not regenerated,
volumes are not deleted and the repository is not re-cloned. `--force` re-runs
completed phases deliberately.

---

## Deployment safety

Application updates never destroy the running deployment before the replacement
is proven:

```
build new image (tagged :<git-sha>)
      ↓
verify it on a staging container
      ↓
run migrations, deploy functions
      ↓
swap the live container
      ↓
health check ──fail──► automatic rollback to the previous image
```

Images are tagged `sentinel-ops:<git-sha>` as well as `:latest`, so there is
always a known-good image to roll back to.

`sentinel-ops rollback` restores the previous image and commit. It deliberately
does **not** revert database migrations — silently reversing schema is more
destructive than leaving it — and names the relevant backup instead.

---

## Secrets

- Secrets are generated by Supabase's own setup, or by the installer on the
  fallback path. They are **never** requested from the operator, with one
  exception: an Azure AD client secret, if you choose to enable that sign-in
  provider, is a real external credential and has to come from you — see
  [Azure AD sign-in](#azure-ad-sign-in) below. It is entered with the terminal
  echo off, written only to `supabase/.env`, and never logged.
- Nothing secret is printed during installation or written to installer logs.
  `sentinel-ops credentials` is the one disclosure point, masked by default.
- The **service-role key is never given to the frontend**. Only the publishable
  (anon) key reaches the build, because anything in a Vite bundle is shipped to
  the browser.
- `config/deploy_key` is `chmod 600`, used only via `GIT_SSH_COMMAND`, and
  excluded from the Docker build context.

---

## Analytics (Logflare)

Deployed via Supabase's own optional overlay (`run.sh config add logs`), which
adds the **analytics** and **vector** services on the Postgres backend. That
overlay is the only path: if the Supabase release in use does not ship it,
analytics is **skipped with a warning** and the install continues. There is no
parallel compose stack to fall back to, because a log aggregator is not worth a
second deployment mechanism to keep in sync.

Tokens and the base64 `LOGFLARE_DB_ENCRYPTION_KEY` are generated once and
re-applied after every Supabase update. Port 4000 is never published — Logflare's
dashboard has no authentication of its own.

Full detail in [docs/LOGFLARE.md](docs/LOGFLARE.md).

---

## Azure AD sign-in

Off by default. `sentinel-ops azure enable` (or the install-time prompt) asks
for the Entra ID application's Client ID, client secret and, optionally, a
tenant ID, then wires Supabase Auth (`gotrue`) to accept it — including
uncommenting the `GOTRUE_EXTERNAL_AZURE_*` lines in `docker-compose.yml`, which
upstream ships disabled and which setting `.env` alone does not turn on.

The redirect URI to register on the app registration is
`<API_EXTERNAL_URL>/auth/v1/callback`, printed by `sentinel-ops azure status` and by
the install summary when enabled at install time. Re-applied automatically
after `sentinel-ops update supabase`, which otherwise resets the compose file
to upstream's commented-out default. Full detail in
[docs/AZURE-AD.md](docs/AZURE-AD.md).

## Auth hardening

Five optional Supabase Auth settings, **all off by default**:
admin-created accounts only (`signup`), a strong password policy
(`password-policy`), rejecting breached passwords (`hibp`), a Cloudflare
Turnstile CAPTCHA on sign-in (`captcha`), and per-IP rate limiting behind a
reverse proxy (`rate-limit`). You can turn each one on with an install-time
prompt or later with `sentinel-ops auth enable <feature>`. They reach gotrue
through a generated Compose overlay,
`supabase/docker-compose.sentinel-auth.yml`, which survives
`update supabase`. Full detail, including the egress and reverse-proxy
requirements, is in [docs/AUTH-HARDENING.md](docs/AUTH-HARDENING.md).

## Repairing supabase/.env

`sentinel-ops repair check` scans `supabase/.env` for the class of mistake
that silently corrupts a value Compose or gotrue read literally: CRLF line
endings, trailing whitespace, spaces around `=` (`SITE_URL = http://x` is not
the same value as `SITE_URL=http://x`), duplicate keys, and a trailing slash
on `SUPABASE_PUBLIC_URL`/`API_EXTERNAL_URL`/`SITE_URL`. `sentinel-ops repair
apply` fixes what it can (keeping a timestamped backup alongside the file),
re-wires Azure AD if its compose wiring drifted back to upstream's broken
redirect URI, and restarts Kong/Auth so the fixes actually take effect — a
container already has the old environment loaded; editing the file alone
changes nothing until it is recreated. It never touches a real configuration
choice (a custom domain, a disabled provider), only mechanical formatting.

Both also cover one database grant. Restoring a backup from inside the
application loads tables with `session_replication_role = replica`, which the
migration role (`postgres`, not a superuser on self-hosted Supabase) may only
set once `supabase_admin` grants it. Every install and update applies that
grant; `repair check` reports it as "Restore grant" and `repair apply` adds it
if it is missing. It needs PostgreSQL 15 or newer.

## Frontend build

The default build mode is **`docker`**: dependency install and the build run
inside a multi-stage image, so the server needs no JavaScript toolchain and the
build is reproducible.

Dependencies are installed from whichever lockfile the repository actually
maintains — `bun.lock`, `pnpm-lock.yaml`, `yarn.lock`, then `package-lock.json`,
most specific first — and always from the lock rather than resolving afresh. The
builder is `node:22-alpine`, which several of the application's dependencies
require.

The application is a **TanStack Start / Nitro** app: it server-renders its HTML,
so there is no static bundle to host. The build pins Nitro's `node-server`
preset (the repository targets `netlify`; the override applies inside the build
layer only) and the runtime image runs `node .output/server/index.mjs` as an
unprivileged user — no source, no `node_modules`, no build toolchain.

`assets/app/Dockerfile` and `.dockerignore` belong in the application
repository. Until they are committed there, the installer copies its own
templates into the checkout; a `Dockerfile` already present in the repo always
wins.

---

## Updating the installer itself

To install from a branch instead of `main`, clone it directly:

```bash
git clone --branch my-branch https://github.com/BrainStation-23/SentinelOps-installer.git
cd SentinelOps-installer
sudo ./install.sh
```

On an existing server, update the installed `sentinel-ops` command in place:

```bash
sudo sentinel-ops self-update          # latest installer from GitHub
sudo sentinel-ops self-update check    # show what would change first
```

This never touches the deployed stack. Installations made before
`self-update` existed need one last `git pull` and `sudo ./install.sh`, which
is safe because completed phases are skipped. See
[docs/OPERATIONS.md](docs/OPERATIONS.md#updating-the-installer-itself).

---

## Development

```bash
./tests/run.sh
```

Runs shell syntax checks, a CRLF guard, shellcheck (when installed) and the unit
tests for the helpers that the deployment logic depends on.

> **Line endings:** these scripts must ship with LF, which matters if you edit
> them from a Windows checkout. `.gitattributes` enforces it; `install.sh` also
> refuses to run a CRLF-contaminated checkout rather than failing with an
> unhelpful `bad interpreter` error.

---

## Further reading

- [docs/OPERATIONS.md](docs/OPERATIONS.md) — day-two runbook and troubleshooting
- [docs/BACKUPS.md](docs/BACKUPS.md) — full-stack backup layout, restore flags and 3-2-1 setup
- [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md) — upstreams and example proxy configs
- [docs/WINDOWS-MDM.md](docs/WINDOWS-MDM.md) — Windows MDM: what to set up, and what to ask IT
- [docs/LOGFLARE.md](docs/LOGFLARE.md) — analytics setup, backends and variables
- [docs/AZURE-AD.md](docs/AZURE-AD.md) — Azure AD sign-in setup and variables
- [docs/AUTH-HARDENING.md](docs/AUTH-HARDENING.md) — optional sign-up, password, CAPTCHA and rate-limit hardening
- [docs/DECISIONS.md](docs/DECISIONS.md) — why the implementation deviates from
  the original plan where it does
