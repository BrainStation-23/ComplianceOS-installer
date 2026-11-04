# Implementation decisions

Where the implementation departs from the original plan, and why. Each of these
is a deliberate choice, not an omission.

---

## 1. Edge functions are deployed by syncing the runtime volume

**Plan:** `deploy_functions()` deploys everything under `supabase/functions/`.

**Implementation:** the functions are copied into
`supabase/volumes/functions/` and the edge-runtime container is recreated.

`supabase functions deploy` targets the **hosted** Supabase platform — it
expects a project ref and an access token, and has nothing to deploy to on a
self-hosted stack. Self-hosted, the `edge-runtime` container serves whatever is
mounted at `volumes/functions`, so syncing that directory *is* the deployment.

Details worth knowing:

- Functions removed from the repository are removed from the deployment.
- The `main` bootstrap function that the stack ships is infrastructure, not
  application code, and is preserved.
- Directories beginning with `_` (e.g. `_shared`) are copied but not counted as
  functions.
- The runtime is verified to still be running afterwards — a syntax error in a
  function can stop it booting, which would otherwise pass silently.

---

## 2. Migrations are applied with psql, not the Supabase CLI

**Plan:** detect applied migrations, apply pending ones, fail safely.

**Implementation:** exactly that, via `psql` inside the database container,
tracking state in `supabase_migrations.schema_migrations`.

This is the same table the Supabase CLI uses, so a database migrated by this
installer stays compatible with `supabase db push` and vice versa. Using psql
directly avoids adding the CLI as a prerequisite — one less versioned binary to
install, pin and keep working on five distributions.

Each migration is applied in a **single transaction together with the row that
records it**, so a failure can leave neither half-applied schema nor a tracking
entry for a migration that did not run.

---

## 3. The frontend is built inside Docker by default

**Plan:** step 19 `npm ci`, step 20 `npm run build`, step 21 build the Docker
image. The plan also states a multi-stage build is preferred.

**Implementation:** multi-stage by default — dependency install and the build
run *inside* stage 1 of the image build.

These two readings conflict, and the multi-stage one is better:

- the server needs **no JavaScript toolchain at all**
- the build cannot be contaminated by whatever Node version the host happens to
  have
- Docker layer caching makes dependency installs free when only source changed

See §11 for why the install step is not simply `npm ci`, and §15 for why the
runtime image is Node rather than nginx.

---

## 4. The Dockerfile ships with the installer

**Plan:** Phase 5 adds `Dockerfile` and `.dockerignore` to the Sentinel Ops
application repository.

**Implementation:** they live in `assets/app/` and are copied into the checkout
when it does not already contain them. A `Dockerfile` present in the repository
always takes precedence.

`nginx.conf` used to ship alongside them and no longer does — see §15.

The application repository is a separate repository that this installer only has
read access to, so the files cannot be committed there from here. **These
templates should be moved into the application repository** — at that point the
installer will simply use them and stop copying anything.

---

## 5. Supabase installation has a fallback path

**Plan:** `curl -fsSL https://supabase.link/setup.sh | sh`.

**Implementation:** that first. If the script is unreachable or produces no
usable deployment, the installer falls back to a sparse checkout of the
`docker/` directory from the Supabase repository.

A single unreachable URL should not make a fresh install impossible. On the
fallback path the setup script's secret generation is missing, so the installer
generates the secrets itself — including signing the `anon` and `service_role`
JWTs with HS256 against the generated `JWT_SECRET`. Those are unit-tested in
`tests/test_secrets.sh`.

Secrets are only ever generated when absent or still at an upstream
placeholder. Regenerating `JWT_SECRET` on an existing installation would
invalidate every issued token and lock all users out.

---

## 6. Logflare uses Supabase's own optional overlay

**Plan:** Logflare is deployed separately because the default Supabase setup does
not include it.

**Implementation:** correct — it is not in the base stack — but upstream already
provides the mechanism for adding it, and reimplementing that would have been a
mistake.

Per the [self-hosting analytics
reference](https://supabase.com/docs/reference/self-hosting-analytics/introduction),
`run.sh config add logs` layers `docker-compose.logs.yml` onto the base stack and
starts two services: **analytics** (Logflare) and **vector** (log collection).
That overlay is the **only** path the installer implements.

An earlier version had four: the `run.sh` route, setting `COMPOSE_FILE` by hand,
starting a bundled `analytics` service, and finally a standalone compose file of
our own. Every one of those after the first was a guess about a Supabase layout
that might never ship, each with its own env file, network attachment, container
lookup and health probe to keep working. That is a lot of machinery defending a
**log aggregator** — something whose absence does not stop the application
serving a single request.

So: if `supabase/run.sh` exists, analytics is deployed through it. If it does
not, analytics is skipped with a warning and the install continues. The phase is
non-fatal and leaves its marker unset, so re-running the installer retries it
once upstream does ship the overlay.

Three things this surfaced that the original plan did not account for:

- **`LOGFLARE_DB_ENCRYPTION_KEY`** is a required base64 key encrypting sensitive
  Logflare columns. It was missing from the first implementation. It is now
  generated once, unit-tested for round-trip integrity through the env file, and
  re-applied after Supabase updates.
- **Port 4000 is not published.** Upstream restricts access to the Kong gateway,
  so the health check probes from inside the container rather than via
  `localhost:4000`.
- **The dashboard has no authentication.** The installer warns about this after
  every deployment, and the reverse-proxy guide says not to expose it.

The Postgres backend the overlay wires up by default is the one used. Upstream is
explicit that it "is not optimized for high-volume inserts or heavy querying" and
recommends BigQuery for production — but BigQuery needs a Google Cloud project
with billing enabled and a service-account key, which is an operator decision,
not an installer prompt. Its variables are read by the overlay rather than by
this installer, so an operator who wants it can set them in `supabase/.env`
without fighting anything here.

---

## 7. No reverse proxy is installed

**Plan:** Caddy in front of Supabase and the frontend.

**Implementation:** removed entirely. TLS termination, certificates and routing
belong to the host, which usually already has a proxy, a certificate workflow and
opinions about both. Installing a second one that binds :80 and :443 would
conflict with whatever is already there.

What the installer owns instead is a stable contract: the frontend on
`APP_BIND:APP_PORT` (default `127.0.0.1:41820`) and Supabase Kong on
`127.0.0.1:8000`, both loopback-bound so nothing is publicly exposed by accident.
`sentinel-ops status` and the post-install summary print both, and
[REVERSE-PROXY.md](REVERSE-PROXY.md) carries worked nginx, Caddy and Traefik
configurations plus the two failure modes that actually bite — missing WebSocket
headers breaking Realtime, and nginx's 1 MB body limit rejecting Storage uploads.
Because the proxy is not ours, the installer checks it instead of configuring
it: `sentinel-ops domain status` pushes one upload chunk through the public URL
and reports a 413 (see 32).

Supabase's Kong gateway is untouched. It was never the thing that needed
replacing.

---

## 8. `app/.env` is not passed to the container with `--env-file`

The plan's format for `app/.env` quotes its values
(`SUPABASE_URL="https://..."`). Docker's `--env-file` does **not** strip quotes,
so the container would receive a value with literal `"` characters around it.

The file is written in the specified format — it is what the application's own
tooling reads — and the container's runtime environment is passed explicitly
with `-e` instead.

The client-side Supabase settings are also passed this way: the app reads
`SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` from `process.env` at runtime via
`/runtime-config.js`, rather than having Vite inline them into the bundle at
build time. `frontend_run_container` passes both (plus
`SUPABASE_SERVICE_ROLE_KEY` for the server) as container env vars, so changing
a URL only requires a restart, not a rebuild.

---

## 9. Additional commands

`restore` and `logs` are not in the planned CLI. Both proved necessary while
building the rest: a backup mechanism with no restore path is not a backup
mechanism, and `status` telling you something is unhealthy is only useful if you
can then read that component's logs.

---

## 10. Rollback does not revert the database

`sentinel-ops rollback` restores the previous image and commit, and leaves the
schema alone.

Reverting migrations automatically would mean either running unknown `down`
migrations or restoring a whole-database backup — silently discarding every
write since the deployment. Rolling application code back onto a slightly newer
schema is usually fine; silently destroying data is never fine. The command
prints the relevant backup path so the operator can make that call explicitly.

---

## 11. The build uses the lockfile the repository actually maintains

The Dockerfile template installs with `bun`, `pnpm`, `yarn` or `npm`, chosen by
which lockfile is present — most specific first — and always from the lock
rather than resolving afresh.

Assuming npm looked safe and was not. The Sentinel Ops application repository
carries a `package-lock.json` alongside `bun.lock`, and only the bun lockfile
tracks `package.json`; the npm one had drifted five weeks out of date. `npm ci`
correctly refused, with a wall of `Missing: X from lock file` that reads like a
registry problem rather than a stale lockfile.

The builder image is `node:22-alpine`, not 20: several dependencies declare
`"engines": { "node": ">=22.12.0" }`.

Deliberately **not** done: falling back to `npm install` when `npm ci` fails.
That would paper over lockfile drift and produce a build nobody can reproduce.
A failed `npm ci` is a real signal and should stop the deployment.

---

## 12. Gateway health probes send an API key

Supabase replaced Kong with Envoy as the stack's API gateway. Envoy's RBAC
filter rejects every route without an `apikey` — including `/auth/v1/health`,
which Kong served unauthenticated.

A probe that omits the key therefore gets a flat `401` from a completely healthy
stack, so the installer's own health check failed an otherwise successful
install. The probes now send the publishable key, and the auth check falls back
to asking the GoTrue container directly when the gateway refuses us: the gateway
declining to authorize a probe says nothing about whether auth is up.

The API and Studio probes accept `403` for the same reason.

---

## 13. `known_hosts` is validated, not assumed

`ssh-keyscan` can fail while exiting successfully — some builds cannot negotiate
with GitHub and return no keys at all. Appending its output blindly produces a
`known_hosts` that parses but holds no usable key, which surfaces much later as
`Host key verification failed` and looks like a deploy-key problem.

The installer now keeps only lines shaped `<host> <keytype> <base64>`, and falls
back to `StrictHostKeyChecking=accept-new` when no key could be retrieved.

---

## 14. Placeholder secrets are matched against a list, not a pattern

`_is_placeholder` decides which of upstream's `.env.example` values get
replaced. A substring heuristic (`*your-super-secret*` and friends) missed three
of them, because Supabase does not mark them as placeholders:

| Key | Upstream value |
|---|---|
| `SECRET_KEY_BASE` | `UpNVntn3cDxHJpq99YMc1T1AQgQpc8kf...` — looks generated |
| `VAULT_ENC_KEY` | `your-32-character-encryption-key` |
| `DASHBOARD_PASSWORD` | `this_password_is_insecure_and_should_be_updated` |

Every install therefore shipped with the Phoenix signing key, the Vault
encryption key and the Studio password that are published in Supabase's own
repository. The check is now an explicit table, including the literal
`SECRET_KEY_BASE` string and a decoder for the demo `supabase-demo` JWTs, and
`tests/test_secrets.sh` asserts each one.

---

## 15. The frontend runs as a Node server, not static files behind nginx

**Original implementation:** build with Vite, copy `dist/` into an nginx image,
serve it as a static single-page application.

That cannot work for this application. Sentinel Ops is a **TanStack Start /
Nitro** app: it server-renders its HTML. `vite build` emits hashed client assets
into `dist/` and a *server bundle* elsewhere — there is no `index.html` at all,
because the HTML is produced per request.

The failure mode was the dangerous kind. Copying that `dist/` into nginx
produced a web root full of assets that nothing referenced, and nginx quietly
served its own `Welcome to nginx!` page. The container was healthy, `/` returned
`200`, `sentinel-ops status` reported **HTTP health ✓ Healthy**, and the
installer printed *Installation Complete* — while serving no application at all.

The runtime image is now `node:22-alpine` running
`node .output/server/index.mjs` as an unprivileged user. Nitro bundles every
runtime dependency into `.output/`, so the image still carries no source and no
`node_modules`.

Two supporting details:

- **The preset is pinned at build time.** The repository's `vite.config.ts`
  sets `nitro: { preset: "netlify" }`, and `NITRO_PRESET` does *not* override an
  explicit preset. The build rewrites it to `node-server` in the copied source
  inside the build layer, so the repository stays deployable to Netlify
  unchanged.
- **The build asserts its own output.** Missing `.output/`, or a missing
  `.output/server/index.mjs`, fails the build with an explicit message. A
  deployment that serves nothing must never report success again.

---

## 16. The generated application env goes to `.env.local`

The application repository **tracks** `.env`. Writing the generated Supabase
settings there left the checkout permanently dirty, so the `git merge --ff-only`
in `sentinel-ops update app` would abort with "the local checkout has diverged"
the first time an upstream commit touched that file — a failure with no visible
connection to its cause.

Vite reads `.env.local` at higher precedence than `.env`, and the repository's
`.gitignore` already covers `*.local`. Writing there overrides the committed
values and leaves version control alone. The installer warns once if it finds
local modifications to the tracked `.env` left by an earlier version.

---

## 17. The deployment key is normalised to LF

A private key that has been through Windows — created there, emailed, pasted
into Notepad, or copied out of a Windows checkout — carries CRLF line endings.
OpenSSH rejects it with:

```
Load key "/opt/sentinel-ops/config/deploy_key": error in libcrypto
git@github.com: Permission denied (publickey).
```

That message reads like a corrupt or unregistered key, and sends operators off
regenerating and re-registering a deploy key that was fine all along. The
installer strips the CRs after validating the key and before using it.

---

## 18. A `docker` on PATH is not proof of a usable Docker

`docker_binary_ok` checked only that the command existed. On WSL with Windows
PATH interop that is satisfied by Docker Desktop's `docker.exe`, which cannot
drive containers from inside the distro unless WSL integration is enabled — it
exits non-zero with an explanatory message instead of printing a version.

The installer therefore reported `[OK] Docker installed ()` — note the empty
parentheses where the version should be — skipped installing Docker, and failed
several steps later on the daemon check with nothing pointing at the real cause.

The check now requires `docker --version` to actually succeed, and when the
binary turns out to be a Windows executable the installer says so and offers to
install Docker natively instead.

---

## 19. The deployment target is Linux only

A native PowerShell port of the whole installer used to live under `windows/` —
nearly 5,000 lines reimplementing every module, plus a `docs/WINDOWS.md`
cataloguing the places the two builds had to diverge: a generated
`docker-compose.windows.yml` to move bind mounts off the Windows/Linux boundary,
its own Compose file-list handling because upstream's `run.sh` cannot run there,
its own prerequisite and privilege checks, its own crypto via .NET because there
is no `openssl`, and its own `ssh-keyscan` fallback.

It has been removed. Sentinel Ops is deployed to Linux servers; the Windows port
existed for local experimentation, and the price was a second implementation of
every deployment decision that had to be kept in step with the first — including
the analytics overlay and the secret generation that `tests/test_secrets.sh`
guards. Two implementations of the same logic means one of them is quietly wrong.

Developing on Windows is unaffected: the scripts are LF-enforced by
`.gitattributes` and `install.sh` rejects a CRLF-contaminated checkout, and WSL
runs the installer as-is — see §18 for the one Docker gotcha that causes.

---

## 20. `nuke` confirms with a typed word and distinguishes "no" from "cannot ask"

The installer needed a teardown counterpart so one server can be used to test
installations repeatedly. Three choices in it are deliberate.

**The confirmation is the typed word `nuke`, not `y/N`.** Everywhere else a
`confirm` prompt is right, because the worst case is a re-run. Here the worst
case is a dropped database, and a y/N prompt sits one stray keystroke away from
that.

**A missing terminal is an error, not a default.** `confirm` deliberately falls
through to its default when there is no TTY, which is what makes the installer
usable from CI. Applying that rule here would mean `sentinel-ops nuke` in a
pipeline either silently destroying a database or silently doing nothing — and
the second is worse, because `nuke && ./install.sh` would then install on top
of a stack that is still running and report success. So `nuke` exits **2** when
it cannot ask, **1** is never returned to the caller, and a genuine typed
cancellation exits 0.

**Docker is torn down before the filesystem.** `docker compose down -v` reads
`supabase/docker-compose.yml` and `supabase/.env` to know what it owns.
Removing the directory first would leave every container and volume orphaned
with nothing left to identify them by — which is precisely the mess this
command exists to prevent. A label-based sweep of the Compose project runs
afterwards anyway, for the case where those files were already gone.

Supabase's images are kept. Re-pulling the stack is several GB and many minutes
per cycle, a cached image cannot make an installation stale (the compose file
pins what it wants), and the point of the command is a fast loop. `tests/test_nuke.sh`
asserts the path guard and the keep-list, since those are what stand between a
mistyped `--dir` and an `rm -rf` somewhere it does not belong.

---

## 21. `FRONTEND_BUILD_MODE=host` removed

§3 originally described a host build path alongside the default in-Docker one,
selected by `FRONTEND_BUILD_MODE=host` and a matching `BUILD_MODE` build
argument in `assets/app/Dockerfile`. It is gone: `frontend_host_build()`, the
`FRONTEND_BUILD_MODE` variable, and the Dockerfile's `builder-host` stage have
all been deleted, and the build is now unconditionally in-Docker.

It never worked against this application's real Dockerfile and lockfile — it
was written against the installer's own fallback template, untested against a
host toolchain, and nothing in the test suite or a real deployment ever
exercised it. Carrying an alternate, unverified build path is worse than not
having one: it looks supported, and the first person to rely on it discovers
otherwise during an incident. The in-Docker path is the only one that matters
and the only one this project has ever actually run.

---

## 22. A default install exposes the LAN, not just the loopback host

**The bug:** `SUPABASE_PUBLIC_URL`/`API_EXTERNAL_URL`/`SITE_URL` defaulted to
`http://localhost:*`. The browser gets these values verbatim through
`/runtime-config.js` (see §8), so from any machine other than the server
itself, `localhost` resolves to *that machine*, not the server, and every
Supabase call fails with `ERR_CONNECTION_REFUSED`. `network_prompt_config`/
`network enable` opened the ports but never touched these URLs, so the bug
survived even after opting into network access — the two problems look like
one but were always two.

**The fix, without reversing §7:** §7's contract (no reverse proxy installed,
loopback-safe by default) is about *who runs TLS*, not about which address the
loopback default should be. A fresh install (interactive or `--yes`) now:

- detects this host's real LAN IPv4 address (`detect_lan_ip()` in
  `lib/common.sh`: the source address of the default route, falling back to
  `hostname -I`), and seeds the three URL prompts with it, not `localhost`;
- defaults the network-exposure prompt to **yes**, so a default run is
  reachable from another device on the LAN with no manual configuration;
- scopes the firewall rule it opens to `FIREWALL_PRIVATE_RANGES`
  (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) instead of the world, so
  "reachable on the LAN" cannot silently become "reachable from the internet"
  on a box that also carries a public IP.

`network enable`/`disable` had a second bug worth its own line: they called
`config_save` (which writes `config/installer.env`, this installer's *own*
bookkeeping) but never `supabase_apply_config` (which writes `supabase/.env`,
what Kong and GoTrue actually read), and restarted only the frontend. Auth
kept validating redirects against whatever `SITE_URL` it booted with,
indefinitely. Both commands now call `supabase_apply_config` and recreate
Kong and Auth (`supabase_gateway_service()` resolves the compose service name,
since it has changed across releases — see §12) alongside the frontend.

**The domain path stays a restart, not a reinstall.** `sentinel-ops domain set
<hostname>` is the first-class way to move off LAN URLs entirely: it sets all
three URLs to `https://<hostname>`, updates `ADDITIONAL_REDIRECT_URLS` (the
same logic §8's `supabase_apply_config` already runs at install time), and
flips `APP_BIND` back to `127.0.0.1` — a domain implies a proxy in front, and
direct exposure is no longer wanted once one exists. Its config transform
(`_domain_apply_settings`) is kept separate from the Docker restart
(`_domain_set`) specifically so it can be unit-tested without a live stack,
the same split `_nuke_filesystem`/`cmd_nuke` already use.

---

## 23. Backup scope widened to the full stack, not just Postgres

**The gap:** `create_database_backup()` only ran `pg_dumpall`. Supabase
Storage's actual uploaded objects and the deployed edge functions had no
backup path at all — a "successful" backup could not reconstitute a working
install, only its database.

**The fix:** `backup_create_full()` (`lib/backup.sh`, replacing
`create_database_backup()`) archives `supabase/volumes/storage` and
`supabase/volumes/functions` alongside the SQL dump, plus a `config.tar.gz`
holding `supabase/.env`, `installer.env` and the deploy key — everything a
fresh box needs besides the backup directory itself. Each backup is still one
directory per cycle, now with a `checksums.txt` recording a sha256 of every
file in it, checked before any restore trusts the directory.

**Why one directory shape, not separate mechanisms for local vs. remote:**
restic (§24) backs up that exact directory. A restic-sourced restore
therefore reproduces the identical shape a local restore already reads, so
`_restore_apply()` is the *only* restore implementation, used regardless of
whether its input is a local backup directory or a staging directory restic
just restored a snapshot into. Two restore code paths for "the same data,
different source" would have been two places to keep in sync and two places
for a subtle divergence to hide.

---

## 24. restic drives the 3-2-1 copies; both roles are opt-in, off by default

**The gap:** `BACKUP_DIR` is always `${INSTALL_DIR}/backups`, on the same
disk as the data it protects against. There was no second copy anywhere, no
offsite copy, and nothing encrypts a backup at rest.

**The fix:** two independently-configurable restic repository roles —
`secondary` (a different local/attached medium: a second disk, a NAS mount)
and `offsite` (remote/cloud) — added via `sentinel-ops remote secondary
configure` / `remote offsite configure`. Neither is required for a normal
install to work; both are off by default, the same "opt-in, not a default
install-time prompt" convention as Azure AD (`ENABLE_AZURE_AD`) and LAN
network exposure before it was flipped to a default (`network enable`, §22)
— configuring an offsite
backend needs credentials and a target the installer cannot invent on an
operator's behalf.

**Why restic specifically:** it is backend-agnostic via a repository URL
(`s3:`, `b2:`, `sftp:`, a local path, …), so nothing in this installer
special-cases a cloud provider — the operator supplies a URL and whatever
credentials that backend needs. More importantly, restic supplies
repository encryption, deduplication and `forget --keep-daily/weekly/monthly
--prune` retention as a single, already-audited dependency. Writing any of
those three ourselves — especially the encryption — would have been a much
larger and much riskier undertaking than shelling out to a tool that already
does it. `lib/restic.sh` is a thin, role-based wrapper: every function that
actually invokes `restic` is one line calling `_restic_run`, and the only
logic worth unit-testing (path/string mapping, the retention-flag builder)
is separated out as pure functions, mirroring the `_domain_apply_settings`/
`_domain_set` split from §22.

**Credentials never touch `installer.env`.** A repository password
(generated with `random_token 24` unless the operator supplies one) and any
backend credentials live in `config/restic-<role>.pass`/`.env` (chmod 600),
exported as real environment variables only for the duration of a single
`restic` invocation inside `_restic_run`, then unset — the same
export-around-the-call pattern `frontend_run_container()` already uses for
`SUPABASE_SERVICE_ROLE_KEY` (`lib/frontend.sh`), because `run_logged` logs
its argv and nothing sensitive may arrive there as `NAME=value` text.

---

## 25. `BACKUP_DIR` stays derived-only

3-2-1's "different medium" requirement could have been satisfied by letting
`BACKUP_DIR` be relocated independently (adding it to `config_load`'s
allowlist, currently it is written to `installer.env` for readability but
never read back). That was deliberately not done.

The `secondary` restic role (§24) already covers "a copy on different
media" — properly, with encryption and retention, not just a relocated
directory. Decoupling `BACKUP_DIR` from `INSTALL_DIR` would also silently
break `nuke --keep-backups`, which assumes `backups/` lives inside
`INSTALL_DIR` and is therefore covered by `_nuke_filesystem`'s keep-list. A
second, independent path to track would be one more thing nuke has to know
about, for a need the restic role already meets better.

---

## 26. Scheduling tolerates hosts without systemd

`sentinel-ops schedule enable` installs a `sentinel-ops-backup.timer`/
`.service` pair. On a host with no `systemctl` (a container, WSL without
systemd) it warns and returns non-fatal rather than dying — exactly the
contract `service_enable_start()` already has in `lib/os.sh`, which this
installer already relies on to enable Docker itself gracefully in the same
situation. An operator on such a host can still run `sentinel-ops backup
create` or `sentinel-ops schedule run-now` by hand, or wire either into their
own cron — the installer just doesn't assume systemd is there to do it for
them.

---

## 27. Verification is lightweight, not a restore drill

Every backup carries a `checksums.txt`, checked before any restore and by
`sentinel-ops backup verify`; each scheduled cycle also runs a periodic
`restic check` (default weekly, `BACKUP_SCHEDULE_CHECK_DAY`) against every
configured repository.

What this deliberately does **not** do is spin up a scratch Postgres
instance, restore a backup into it and diff the result — a real automated
restore drill. That would need a disposable database instance's worth of
extra lifecycle management (start it, wait for it, tear it down, on every
scheduled cycle) for a guarantee stronger than what checksums plus a
repository-level integrity check already catch: corruption, truncation, a
silently-failed upload. `docs/BACKUPS.md` states this boundary explicitly and
recommends operators test a real restore themselves periodically, so the
gap is a stated scope decision, not something to rediscover mid-incident.

## 28. Auth hardening ships as a generated Compose overlay, not a compose patch

The optional gotrue settings in `lib/hardening.sh` (password policy, breached
passwords, CAPTCHA, rate-limit header) have no wiring at all in upstream's
`docker-compose.yml`, not even commented out. Azure AD
(`azure_patch_compose`, see `docs/AZURE-AD.md`) can be enabled by
uncommenting lines that upstream already ships. These settings have no such anchor, so patching them in would
mean inserting new lines into a vendored file, and `update supabase`
overwrites that file every time.

Instead the installer writes `supabase/docker-compose.sentinel-auth.yml`,
which adds only `services.auth.environment` keys. It is listed in
`COMPOSE_FILE` in `supabase/.env`, the mechanism upstream's own `run.sh config
add` uses for its optional overlays. `COMPOSE_FILE` is edited directly rather
than through `run.sh`, so the step works (and can be unit-tested) when
`run.sh` is absent. The list format is identical, so the two coexist with
`docker-compose.logs.yml`. Upstream never ships a file by this name, so
`_sync_tree` leaves it alone. It is regenerated on every install,
`update supabase`, `repair apply` and `sentinel-ops auth` run anyway.

Values are written into the overlay as literals: YAML single-quoted, with
`$` doubled for Compose. Values are not interpolated from `.env`, because the
password symbol set contains every character `.env` and Compose
interpolation handle badly. The one secret, the Turnstile key, is the
exception: it stays in `supabase/.env` and the overlay references it with
`${TURNSTILE_SECRET_KEY:?...}`. If the secret is missing, Compose then
refuses to start with a clear message, rather than gotrue crash-looping.

Sign-up is the exception in the other direction. Upstream already wires
`GOTRUE_DISABLE_SIGNUP: ${DISABLE_SIGNUP}`, so it is a plain `.env` setting
and needs no overlay.

Every setting defaults to off. An install that declines every prompt gets a
byte-identical `supabase/.env` and no overlay file.

---

## 29. `self-update` replaces the installed copy by rename, and never waits for an update

`install` copies `bin/`, `lib/` and `assets/` into the installation root, so a
`git pull` in the original checkout changes nothing about what `sentinel-ops`
runs. `sentinel-ops self-update` downloads the branch tarball from GitHub
(`INSTALLER_BRANCH`, default `main`; `SENTINEL_OPS_INSTALLER_BRANCH`
overrides it per run) and swaps it in. `self-update from <path>` uses a local
checkout instead, for hosts that can't reach GitHub. Both paths go through the
same steps:

- **Validate before touching anything.** The download must contain all three
  trees and the core libraries, and every script must pass `bash -n` and be
  free of CRLF. A broken installer that replaces a working one leaves nothing
  to run the fix with.
- **Compare by content.** Identical trees mean "already up to date" and no
  changes. `check` prints the added, removed and changed files without
  applying them.
- **Swap by `mv`, never by overwriting in place.** Bash reads a running script
  lazily, so rewriting `bin/sentinel-ops` under a running process would splice
  two versions together. A rename leaves that process holding the old inode.
  The replaced copy is kept in `.installer-prev/` until the next self-update.
  A failed rename part way through puts it back.
- **Regenerate what the code generates.** The new copy re-renders the systemd
  units for the backup schedule and auto-update, so a changed unit definition
  reaches existing installs.

It does **not** take the update lock (see 30). An auto-update can be in the
middle of a 10-minute image build, and that must not block an operator from
shipping a fix to the installer. The two cannot corrupt each other, because the
running update keeps the files it already opened. It reads `assets/` by path,
so a swap during a build can hand it the newer Dockerfile. That's an accepted
trade-off: the assets travel with the installer for exactly this reason.

The application is never touched. Updating the installer and deploying a
release stay separate steps.

---

## 30. Auto-update polls with `ls-remote` and holds back a commit it shouldn't retry

`sentinel-ops auto-update enable` installs a `sentinel-ops-autoupdate`
timer (`AUTO_UPDATE_CALENDAR`, default `hourly`, with up to 5 minutes of
random delay). Each check is one `git ls-remote` against the configured branch,
compared with the deployed commit (`APP_COMMIT` in `.state/`). If they are
equal, the check stops there: no fetch, no Supabase health check, no backup,
no build. Only a moved branch runs `update app`, the same code path an operator
uses.

Two cases would otherwise make it misbehave, so a *held* commit
(`AUTO_UPDATE_SKIP_COMMIT`) is recorded:

- **A failed update.** Retrying the same commit every hour would rebuild a
  broken image and take a pre-update backup every hour. The commit is held
  until the branch moves on.
- **A rollback.** After `rollback`, the branch is "ahead" of the deployed
  commit, so the next check would immediately redeploy the release that was
  just rolled back. `rollback` holds that commit.

A newer commit replaces the hold. A successful manual `update app` clears it.

The check compares against the *deployed* commit, not the checkout's `HEAD`. A
failed update can leave `HEAD` fast-forwarded while the old image still runs,
and comparing `HEAD` would then report "up to date" forever.

Every operation that changes the deployment (`update app|supabase|all`,
`rollback`) takes a non-blocking `flock` on `.state/update.lock`. An operator
who runs into a running auto-update gets a clear refusal rather than a second
interleaved deployment. An auto-update that runs into an operator skips that
cycle. Auto-update never updates the installer itself: that stays an
explicit `self-update` (see 29).

## 31. The image build checks DNS first and retries only network failures

The Dockerfile's `# syntax=` line and its base images are pulled from Docker
Hub on every build, so a host whose resolver is flaky fails the build with a
BuildKit trace about anonymous tokens, which says nothing about DNS. Before
building, `frontend_registry_preflight` resolves Docker Hub's hosts (waiting up
to 30s) and, if that fails, stops with an error that names DNS and the commands
to check it. It is skipped when Docker is configured with a proxy, because the
proxy resolves names and this host does not have to.

A build that still fails is retried twice (15s, then 30s), but only when its
output looks like a DNS or network error (`is_network_error`). A compile error
is not retried. Retrying it would only fail again more slowly. The retry
matters most for auto-update: a failed update holds its commit until the
branch moves on (see 30), so one short DNS blip would otherwise block
deployment until the next push.

---

## 32. Storage's upload limit ships as a generated overlay, and is checked through the proxy

Upstream's `docker-compose.yml` hard-codes `FILE_SIZE_LIMIT: 52428800` (50
MiB) in the storage service's environment; it is not read from `.env`. Storage
enforces the smaller of that and the bucket's own limit, so the application's
4 GiB `app-installers` bucket was capped at 50 MiB and larger App Catalog
installers could not be uploaded.

The override is `supabase/docker-compose.sentinel-storage.yml`, registered in
`COMPOSE_FILE` - the same mechanism, and for the same reason, as the auth
hardening overlay (28): `update supabase` re-syncs `docker-compose.yml` from
upstream, but never ships a file by this name. It sets both `FILE_SIZE_LIMIT`
and `UPLOAD_FILE_SIZE_LIMIT`, because Storage prefers the latter when both
exist. Unlike the hardening overlay it is always on: the limit is
`STORAGE_FILE_SIZE_LIMIT` in `installer.env` (4 GiB by default), and a value
that is not a byte count falls back to the default rather than reaching Compose.
It is written on install, `update supabase` and `repair apply`; `repair apply`
recreates only `storage`, and only when the overlay or its registration changed.

The overlay registers with `present`, not by moving itself to the end of
`COMPOSE_FILE` the way the hardening overlay does. Two overlays that both
insisted on being last would swap places on every run, and `repair` would read
that as drift and restart services every time.

There are two checks, because they answer different questions:

- `status` sends a TUS `OPTIONS` and reads `Tus-Max-Size`: through the gateway
  (is Storage configured?) and through `SUPABASE_PUBLIC_URL` when that is
  elsewhere (does the public route reach Storage?). It warns when the
  advertised limit is below the configured one. An `OPTIONS` has no body, so it
  cannot see a proxy's body limit.
- `domain status` sends one 7 MiB TUS `PATCH` to an upload that does not
  exist. Storage answers that with a 4xx of its own, so a 413 can only come from
  something in front of it. This sends real bytes, so it is not part of the
  routine `status`.

Both send the `apikey` header, which the gateway requires on every route; the
TUS `OPTIONS` route itself needs no JWT.

---

## 33. Image cleanup removes superseded tags, not just dangling images, and keeps the rollback image

Nothing removed images, so every deployment grew the disk, and auto-update did
it unattended. Most of the growth is not "dangling": each build keeps its
`sentinel-ops:<sha>` tag, and each Supabase update leaves the previous version
of every service image tagged. `docker image prune` would have recovered very
little, and `docker image prune -a` or `docker system prune` would remove other
workloads' images on a shared host.

So cleanup works by repository and keep-list (`lib/images.sh`):

- **Application:** every `APP_IMAGE_NAME` tag except `APP_IMAGE`,
  `PREVIOUS_APP_IMAGE` and `:latest`. `rollback` needs the previous image to
  still exist, so it is always kept. Untagged builds are removed by label: every
  build carries `--label org.sentinel-ops.component=frontend`, set on the
  command line rather than in the Dockerfile, because the repository's own
  Dockerfile takes precedence over the installer's (4).
- **Supabase:** `docker compose config --images` lists what the stack uses now.
  For each of those repositories, the other local tags go. Repositories the
  config does not name are left alone, and a digest-pinned reference is skipped
  because it says nothing about which tags are older.
- **Build cache:** `docker builder prune --filter until=168h`. This is the one
  host-wide step, because build cache cannot be told apart by project. It is
  only cache, so the cost to anyone else is a slower build.

Removal is plain `docker rmi`, never `-f`, and skips any image a container,
running or stopped, still uses (a leftover staging container, say). A tag that
points at the same image as a kept one is left alone, since untagging it frees
nothing.

Cleanup runs only after an update has fully succeeded and recorded its new
state, never on a failed or rolled-back one, so the operator still has every
image to investigate with. A cleanup problem is logged as a warning and never
fails the update. `IMAGE_CLEANUP_ENABLED=false` turns the automatic step off,
and `sentinel-ops cleanup [--dry-run]` runs it on demand under the update lock.

## 34. Backups before an app update leave Storage out, retention also caps size, and container logs are capped by an overlay

A host filled its disk. Images were already cleaned up (33), but three other
things grew with no size limit:

- **Backups.** Every `update app`, including every auto-update, took a full
  backup, and a full backup archives all of `supabase/volumes/storage`. That
  holds App Catalog installers of up to 4 GiB each, already compressed, so
  gzip barely shrinks them. With retention counting backups (10) and ignoring
  their size, the disk held ten copies of Storage, refreshed on every deploy.
- **Container logs.** Docker's default `json-file` driver keeps a container's
  output forever, and upstream's compose file sets no limit.
- **Installer logs.** One file per update, cleanup and run, never removed.

**Backups.** An application update changes the database, edge functions and
frontend, never Storage. So `backup_create` takes a scope, and the backup
before `update app` (and before the first migration run) is `db`: everything
but `storage.tar.gz`. A Supabase update, the schedule and `backup create` stay
`full`. A pre-restore safety backup matches the restore's scope. The scope is
recorded in `metadata.txt`. A backup without one predates scopes and was full.

Retention keeps `BACKUP_RETENTION_COUNT` and adds `BACKUP_RETENTION_MAX_GB`
(default `auto`, a fifth of the backup filesystem): the oldest go until the
rest fit. The newest backup and the newest full backup are never removed. The
latter is the only local copy of Storage, and a week of database-only
backups must not push it out. That lets the count or size limit be exceeded,
and the alternative, a set of backups with no Storage in it, is worse.

Before writing anything, a backup estimates its size (`pg_database_size` of
every database, plus `du` of Storage for a full one) and refuses to start
without that, 10% and 1 GiB to spare. A backup that half-fills the last of
the disk takes Postgres down with it. Where a backup failure was already
non-fatal (before `update app`), this is a warning like any other.

A failed `tar` now fails the backup and removes its directory. It used to be
a warning, leaving a truncated archive that `checksums.txt` then vouched for,
so `backup verify` passed a corrupt backup. On a full disk that is the backup
someone reaches for.

**Container logs.** The limit goes in a generated Compose overlay,
`docker-compose.sentinel-logging.yml`, registered in `COMPOSE_FILE` like the
storage and auth overlays (28, 32), and in `--log-opt` arguments for the
frontend and MDM proxy containers. `/etc/docker/daemon.json` would have been
one line, but it changes every container on the host (a Zoraxy container, say)
and needs a Docker restart, which is not this installer's call to make.

Compose has no "every service" key, so the overlay names each one. The list
comes from `docker compose config --services`, read with every overlay but
this one. Otherwise, once upstream drops a service, the stale overlay would
make Compose refuse the very config the overlay is regenerated from. It is
regenerated where the service list can change: install (before and after the
analytics overlay adds `analytics` and `vector`), `update supabase` and
`repair apply`. The driver stays `json-file`, which `vector` still reads
through the Docker API.

**Installer logs** older than `LOG_RETENTION_DAYS` (30) are removed after
updates and by `cleanup`.

**Auto-update** skips a cycle, without holding the commit, while less than
`AUTO_UPDATE_MIN_FREE_GB` (5) is free where it would write. An unattended
update that builds an image and takes a backup on a nearly full disk is how
the disk ends up full.

`sentinel-ops cleanup` covers all of it, since it should be the one command
for an operator who is out of space. Backups and logs are pruned even when
Docker is down, which on a full disk it may well be.

Not done: Logflare's analytics tables live in Postgres and grow with it,
making every `database.sql` bigger too. That needs a retention setting inside
Logflare, which is worth adding only if the dump turns out to be large.
