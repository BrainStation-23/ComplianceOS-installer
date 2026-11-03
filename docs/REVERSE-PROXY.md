# Reverse proxy

The installer does **not** install or manage a reverse proxy. TLS termination,
certificates and routing are the host's responsibility, to be handled however
that host already does it.

## Moving to a real domain

The recommended first step, once you have a hostname and a proxy in mind, is:

```bash
sudo sentinel-ops domain set app.example.com
```

This does everything a domain move needs in one config change plus a
restart - **no reinstall, no rebuild, no data loss**:

- sets `SUPABASE_PUBLIC_URL`, `API_EXTERNAL_URL` and `SITE_URL` to
  `https://app.example.com`
- adds it to `ADDITIONAL_REDIRECT_URLS` so auth redirects keep working
- flips `APP_BIND` back to `127.0.0.1` (a domain implies a proxy in front, so
  direct exposure is no longer wanted - see
  [DECISIONS.md #7](DECISIONS.md#7-no-reverse-proxy-is-installed))
- persists both to `config/installer.env` and `supabase/.env`, then restarts
  Kong, Auth and the frontend so they pick up the new URLs

Run `sentinel-ops domain status` at any time to see which mode (loopback, LAN
or domain) is currently active. This replaces hand-editing
`config/installer.env` - do that only for settings `domain set` does not
cover.

What it does **not** do is register DNS or run a proxy: point `app.example.com`
at this server yourself, and see the worked configurations below (Zoraxy,
nginx, Caddy, Traefik) for the proxy
that terminates TLS and forwards to the two upstreams `domain set` just
printed.

What the installer guarantees regardless of mode is a stable pair of
upstreams to point at.

## The two upstreams

```bash
sentinel-ops status     # prints both under "URLs"
```

| Upstream | Default | What it serves |
|---|---|---|
| Frontend | `127.0.0.1:41820` | The React application (Node running the Nitro SSR server) |
| Supabase API | `127.0.0.1:8000` | Kong — REST, Auth, Storage, Realtime, Edge Functions, Studio |

A fresh install binds both to every interface (`APP_BIND=0.0.0.0`) so the LAN
can reach them with zero manual config - see [DECISIONS.md
#7](DECISIONS.md#7-no-reverse-proxy-is-installed) and `sentinel-ops network
status`. Once you put a proxy in front with `sentinel-ops domain set`,
`APP_BIND` goes back to **loopback only**: the proxy on this host reaches
them, the public internet does not.

```
        Internet
           │
           ▼
   your reverse proxy          ← you manage this
      ┌────┴─────┐
      ▼          ▼
 127.0.0.1:41820  127.0.0.1:8000
   frontend        Supabase Kong
```

### If the proxy runs elsewhere

Set `APP_BIND=0.0.0.0` in `config/installer.env` and re-run
`sentinel-ops update app`, or use `sentinel-ops network enable`, which does
the same bind change and also opens the frontend port in `ufw`/`firewalld` if
one is active. If no firewall is enforcing anything on this host, **firewall
the port yourself** — nothing else will.

### If the proxy runs in Docker

The frontend container joins the Supabase Docker network, so a proxy container
on that same network can route to it by name instead of through the host:

```bash
docker network connect "$(docker inspect -f \
  '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' supabase-db)" my-proxy
```

Then use `sentinel-ops-frontend:41820` and `kong:8000` as the upstreams.

---

## Example configurations

These are references, not managed files. Adapt them to your setup.

Whichever proxy you use, check it once it is up:

```bash
sudo sentinel-ops domain status
```

Under **Uploads** it reports the upload limit Storage advertises, both directly
and through your proxy, and pushes one 6 MiB upload chunk through the proxy to
confirm it is not refused. A `413` there means the proxy caps request bodies
below what the App Catalog sends - see [Upload size](#things-that-will-bite-you).

### Zoraxy

Zoraxy is what we usually run in front of Sentinel Ops, and it needs the least
configuration: it streams request bodies to the upstream with **no size limit**,
upgrades WebSockets (Realtime) on its own, and sets `X-Forwarded-Proto`, which
Storage uses to build the upload URLs it hands back to the browser.

Create two rules with **Create Proxy Rule**:

| Matching Keyword / Domain | Target | Remote Target Require TLS |
|---|---|---|
| `app.sentinelops.com` | `127.0.0.1:41820` | off |
| `supabase.sentinelops.com` | `127.0.0.1:8000` | off |

Issue the certificates under **TLS / SSL certificates** (ACME), and turn on
**Force redirect HTTP request to HTTPS** on the listener.

Things to leave alone:

- **Don't start Zoraxy with a non-zero `-writetimeout`.** The default, `0`, is
  what lets a long upload or a Realtime connection run as long as it needs to.
- **Per-rule rate limiting** on the Supabase rule, if you turn it on, must stay
  well above the upload rate: TUS sends one request per 6 MiB, and the
  application itself makes many small requests per page. 100 req/s is a
  reasonable floor.

For `sentinel-ops auth enable rate-limit` (see
[AUTH-HARDENING.md](AUTH-HARDENING.md)), add a custom header to the Supabase
rule (**Edit Custom Header**): direction *to upstream*, name
`X-Sentinel-Client-IP`, value `$remote_ip`. If Zoraxy itself sits behind
another proxy or a CDN, `$remote_ip` is that hop's address, not the user's -
set the header at the outermost proxy instead.

For **Windows MDM**, Zoraxy can't request a PC's client certificate: keep it
as it is and run `sentinel-ops mdm-proxy enable`, which serves MDM on a port of
its own. See [Zoraxy can't serve the MDM hostname](#zoraxy-cant-serve-the-mdm-hostname).

### nginx

```nginx
server {
    listen 443 ssl http2;
    server_name app.sentinelops.com;

    ssl_certificate     /etc/letsencrypt/live/app.sentinelops.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.sentinelops.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:41820;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 443 ssl http2;
    server_name supabase.sentinelops.com;

    ssl_certificate     /etc/letsencrypt/live/supabase.sentinelops.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/supabase.sentinelops.com/privkey.pem;

    # Storage enforces its own upload limit (4 GiB by default); nginx's 1 MB
    # default would refuse the very first 6 MiB upload chunk with a 413.
    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Realtime uses WebSockets.
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }

    # Resumable (TUS) uploads: stream each chunk to Storage as it arrives
    # instead of spooling it to disk first.
    location /storage/v1/upload/resumable {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
}
```

#### Sign-in rate limiting (optional)

Pairs with `sentinel-ops auth enable rate-limit` (see
[AUTH-HARDENING.md](AUTH-HARDENING.md)). Add the client-IP header to the
Supabase server block above. It must be `proxy_set_header`, which
**overwrites** whatever the client sent; an appended header can be spoofed.
A second, coarser per-IP limit on the password-grant endpoint at the edge
costs nothing:

```nginx
# http {} context
limit_req_zone $binary_remote_addr zone=auth_token:10m rate=10r/m;

# inside the supabase.sentinelops.com server {} block
    proxy_set_header X-Sentinel-Client-IP $remote_addr;   # in location / too

    location = /auth/v1/token {
        limit_req zone=auth_token burst=5 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host                 $host;
        proxy_set_header X-Real-IP            $remote_addr;
        proxy_set_header X-Forwarded-For      $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto    $scheme;
        proxy_set_header X-Sentinel-Client-IP $remote_addr;
    }
```

`/auth/v1/token` also serves session refreshes, so leave enough headroom for
several users behind one NAT. This adds a limit at the proxy. It does not
replace gotrue's own limit, which keys on the header.

### Caddy

```caddyfile
app.sentinelops.com {
    reverse_proxy 127.0.0.1:41820
    encode gzip zstd
}

supabase.sentinelops.com {
    reverse_proxy 127.0.0.1:8000
    encode gzip zstd
}
```

Caddy has no request body limit by default, and Storage enforces its own. If you
add a `request_body { max_size … }` block, keep it at or above the Storage
limit (`4GB`).

### Traefik (dynamic file provider)

```yaml
http:
  routers:
    sentinel-app:
      rule: "Host(`app.sentinelops.com`)"
      service: sentinel-app
      tls:
        certResolver: letsencrypt
    sentinel-supabase:
      rule: "Host(`supabase.sentinelops.com`)"
      service: sentinel-supabase
      tls:
        certResolver: letsencrypt
  services:
    sentinel-app:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:41820"
    sentinel-supabase:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8000"
```

Traefik has no request body limit by default. If you attach a `buffering`
middleware to the Supabase router, its `maxRequestBodyBytes` must allow at
least one 6 MiB upload chunk - or leave buffering off that router entirely.

---

## Windows MDM hostname (client certificates)

Only needed if you enroll Windows PCs in the console's MDM (**Settings → MDM**;
the application's `docs/windows-mdm.md` covers the rest). After enrollment, a
PC authenticates every check-in to `/ManagementServer/MDM.svc` with its device
certificate **at the TLS layer**. TLS ends at your proxy, so on the MDM
hostname the proxy must:

1. **Request** a client certificate, but neither require nor verify one:
   enrollment requests have none, and the application checks the certificate
   against its own Windows device CA.
2. **Forward** it in `X-Client-Cert`, together with the **proxy secret** in
   `X-MDM-Proxy-Secret`. The application trusts the certificate header only
   when the secret comes with it.
3. **Set** both headers itself, never pass through what a client sent.

The installer generates the secret on the first install or update that starts
the frontend, keeps it in `supabase/.env`, and passes it to the container.
Read it with:

```bash
sudo sentinel-ops credentials --show     # "Windows MDM (reverse proxy)"
```

If your proxy has to use other header names, set `MDM_CLIENT_CERT_HEADER` and
`MDM_PROXY_SECRET_HEADER` in `config/installer.env` and run
`sentinel-ops update app`.

The MDM hostname goes to the **frontend** upstream (`127.0.0.1:41820`). Until
the proxy forwards the certificate, enrolled PCs can't check in: the console's
**Settings → MDM** says so when PCs are enrolled but none has checked in.

### nginx

```nginx
server {
    listen 443 ssl;
    server_name mdm.example.com;
    ssl_certificate     /etc/letsencrypt/live/mdm.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mdm.example.com/privkey.pem;

    # ask for the PC's certificate, but don't verify it here
    ssl_verify_client optional_no_ca;

    location / {
        proxy_pass http://127.0.0.1:41820;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        # proxy_set_header replaces whatever the client sent
        proxy_set_header X-Client-Cert $ssl_client_escaped_cert;
        proxy_set_header X-MDM-Proxy-Secret "<proxy secret>";
    }
}
```

### Caddy

```caddy
mdm.example.com {
    tls {
        client_auth {
            mode request
        }
    }
    reverse_proxy 127.0.0.1:41820 {
        header_up X-Client-Cert {http.request.tls.client.certificate_der_base64}
        header_up X-MDM-Proxy-Secret "<proxy secret>"
    }
}
```

The application accepts the certificate as a URL-encoded PEM (nginx), a PEM on
one line, or base64 DER (Caddy). Another proxy works if it can **request** (not
require) a client certificate on the MDM hostname and forward it in a header;
none besides nginx and Caddy has been tried.

### Zoraxy can't serve the MDM hostname

Zoraxy (checked against v3.3.5) never asks a client for a certificate: its TLS
listener has no client-certificate setting, and no rule or header can forward
one. Its stream proxy forwards by port, not by hostname, so it can't pass the
MDM hostname's TLS through to something that can either. With Zoraxy on port
443 for every hostname:

- enrollment works (discovery, the certificate policy and enrollment don't need
  a client certificate);
- **check-ins don't**: `/ManagementServer/MDM.svc` answers 401 to every PC,
  and the console's **Settings → MDM** says that PCs are enrolled but none has
  checked in;
- certificate renewal fails too, since it also authenticates with the PC's
  certificate.

**The supported setup: an MDM port.** Keep Zoraxy exactly as it is and give
MDM a port of its own, served by the installer's MDM proxy: a Caddy container
that requests the PC's certificate and forwards it, with the proxy secret, to
the frontend. Windows always looks for discovery on 443, and discovery and the
sign-in page need no certificate, so only what needs one moves.

1. Keep Zoraxy's rule for the MDM hostname, pointing at the frontend
   (`127.0.0.1:41820`), with its ACME certificate.
2. Start the proxy with that certificate:

   ```bash
   sudo sentinel-ops mdm-proxy enable --port 8443      --cert <zoraxy>/conf/certs/mdm.example.com.pem      --key  <zoraxy>/conf/certs/mdm.example.com.key
   ```

   It checks the certificate and key, copies them, opens the port in
   ufw/firewalld, and installs a daily timer that copies them again when
   Zoraxy renews (`sentinel-ops mdm-proxy sync-cert`).
3. In the console, **Settings → MDM → MDM port**: the same port, **before PCs
   enroll** (a PC keeps the address it enrolled with).
4. Open the port wherever else traffic is filtered (a cloud security group).
5. Check it:

   ```bash
   sudo sentinel-ops mdm-proxy status
   ```

   It should show that the proxy requests client certificates, and that
   `/ManagementServer/MDM.svc` answers 401 without one: the request reached the
   app with the secret. A 503 means the app has no secret yet
   (`sentinel-ops update app`).

| Traffic | Port | Served by |
|---|---|---|
| Discovery, the sign-in page, the console, the API | 443 | Zoraxy |
| Certificate policy, enrollment, renewal, check-ins | the MDM port | the MDM proxy |

The proxy answers only those MDM paths; everything else on its port is a 404.
A network that only lets 80 and 443 out (some guest or hotel Wi-Fi) blocks
check-ins until the PC is back on a normal network. `sentinel-ops mdm-proxy
disable` removes it; clear the console's MDM port too.

If you'd rather keep all MDM traffic on 443, these also work:

**An SNI router in front of Zoraxy.** nginx's `stream` module reads the
hostname a connection asks for without decrypting it, passes the MDM
hostname's connections to an nginx server that requests the client certificate
(the [nginx](#nginx-1) configuration above, listening on `127.0.0.1:8443`),
and everything else to Zoraxy unchanged. Zoraxy moves off 443: set its
**Incoming Port** (Global Settings) to e.g. `4443`. Turn on its **PROXY
Protocol** setting (*Accept PROXY protocol v1/v2 headers on the TLS
listener*) so it still sees users' addresses; that turns off HTTP/3, which
can't pass through a TCP router anyway.

```nginx
# nginx.conf, top level (not inside http {})
stream {
    map $ssl_preread_server_name $sentinel_upstream {
        mdm.example.com  127.0.0.1:8443;   # requests the PC's certificate
        default          127.0.0.1:4443;   # Zoraxy, as before
    }
    server {
        listen 443;
        ssl_preread on;
        proxy_pass $sentinel_upstream;
        proxy_protocol on;   # both upstreams learn the user's address
    }
}
```

The MDM server block then accepts the PROXY protocol too: make its first line
`listen 127.0.0.1:8443 ssl proxy_protocol;` instead of `listen 443 ssl;`.

Port 80 stays with Zoraxy, so its ACME HTTP-01 renewals keep working. The MDM
server block needs its own certificate for the MDM hostname; reuse the one
Zoraxy issued (it keeps them under its `conf/certs` directory) or issue one
with certbot's DNS challenge.

**A second public IP.** Point the MDM hostname at its own address and run
nginx or Caddy (above) on that address's port 443. Zoraxy keeps the other
address and nothing about it changes.

Either way, check it from a PC: **Settings → MDM** shows the last check-in
once one gets through.

## Things that will bite you

**WebSockets.** Supabase Realtime needs `Upgrade`/`Connection` headers and a
long read timeout. Without them Realtime silently fails to connect while
everything else looks fine.

**Upload size.** App Catalog installers (a Homebrew `.pkg` is ~120 MB) are
uploaded with TUS in 6 MiB chunks, so the proxy has to accept at least one
~7 MiB request body. nginx defaults to 1 MB and answers with a confusing HTML
413; Zoraxy, Caddy and Traefik have no limit unless you add one. Separately,
Storage has its own limit: upstream Supabase ships 50 MiB, and the installer
raises it to 4 GiB with a generated overlay,
`supabase/docker-compose.sentinel-storage.yml` (change it with
`STORAGE_FILE_SIZE_LIMIT` in `config/installer.env`, then
`sentinel-ops repair apply`). `sentinel-ops status` shows the limit Storage
actually advertises; `sentinel-ops domain status` also tests the proxy.

**nginx must speak HTTP/1.1 to Supabase.** nginx proxies with HTTP/1.0 unless
told otherwise, and current Supabase releases put Envoy in front of the stack,
which answers HTTP/1.0 with `426 Upgrade Required` - on every route, not just
Realtime. Keep `proxy_http_version 1.1;` in every `location` that points at
`127.0.0.1:8000`.

**Slow uplinks.** Supabase's gateway gives each request to Storage 30 seconds.
A 6 MiB chunk therefore needs roughly 2 Mbit/s of upload bandwidth; slower
links fail mid-upload whatever the proxy allows.

**The URLs come from runtime env vars, not the bundle.** The app reads
`SUPABASE_URL`/`SUPABASE_PUBLIC_URL` from `process.env` at runtime via
`/runtime-config.js`, so the domains must match `SUPABASE_PUBLIC_URL` in
`config/installer.env`. Changing a domain only needs the container restarted
with the new value (`sentinel-ops update app` does this), not a rebuild — but
it still needs the container, not just the proxy, reloaded.

**TLS offloading in front of the proxy.** A load balancer or appliance that
terminates TLS before your proxy hides the PC's client certificate, and Windows
MDM check-ins fail. The MDM hostname needs TLS to end at the proxy that
forwards the certificate.

**Do not expose Logflare.** Its `/dashboard` has no authentication of its own.
Port 4000 is not published by default — keep it that way.

**Studio.** Reached through the Supabase hostname and protected by
`DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` (see `sentinel-ops credentials`).
That is HTTP basic auth, so consider restricting it by IP at the proxy too.
