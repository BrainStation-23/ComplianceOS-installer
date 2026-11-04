# Windows MDM: what to set up, and what to ask IT

Sentinel Ops can manage Windows PCs through Windows' own device management
(MDM): enforce settings like BitLocker or the firewall, restart or wipe a PC,
and read its inventory. No Microsoft account or licence is involved; PCs talk
to this server directly.

This page is for whoever runs the Sentinel Ops server. It explains what has to
be reachable, gives you a message to send your network or IT people, and the
commands to run once they are done. The application side (enrolling PCs,
profiles) is in the application's `docs/windows-mdm.md`.

## In one paragraph

An enrolled PC proves who it is at every check-in with a **client
certificate**, so whatever receives check-ins has to ask for that certificate
and pass it on. A PC that isn't enrolled yet has none, and Windows refuses to
enroll wherever it's asked for one; TLS is set up before the request path is
known, so one port can't do both. So: Zoraxy keeps port **443** for everything
it does today, enrollment included, and never asks for certificates; a small
proxy run by this installer listens on a second port, **9443**, for the
check-ins. PCs use the same hostname for both; only the port differs.

```
                      ┌─ port 443  → Zoraxy (unchanged)       → Sentinel Ops
 Windows PC ──────────┤              discovery, sign-in, enrollment,
 mdm.example.com      │              certificate renewal, the console
                      └─ port 9443 → MDM proxy (this installer) → Sentinel Ops
                                     check-ins (asks for the PC's certificate)
```

This holds whatever proxy you run on 443: even nginx or Caddy, which *can*
request client certificates, must not on the MDM hostname, or PCs can't
enroll (sentinel-ops#638). Check-ins always need a port of their own; see
[REVERSE-PROXY.md](REVERSE-PROXY.md#windows-mdm-hostname-client-certificates).

## Quick setup: three steps

For when DNS and the network are already in place (the hostname points at the
server's public address, and the MDM port reaches it). If not, start with the
[message for IT](#message-for-it). Use your own hostname instead of
`mdm.example.com` everywhere below.

**Do all three.** Each one on its own looks finished, and missing any one of
them breaks enrollment or check-ins (see [Common mistakes](#common-mistakes)).

1. **The console: Settings → MDM.** Create the **Windows device CA**, set the
   **MDM hostname** (`mdm.example.com`) and the **MDM port** (`9443`), and
   save. The card shows the two addresses PCs will use: discovery on 443,
   check-ins on the MDM port. If the MDM port field is missing, update the
   application first (`sudo sentinel-ops update app`).
2. **The installer: the MDM proxy and its certificate.** On the Sentinel Ops
   server, with the **same port** as in step 1:

   ```bash
   sudo sentinel-ops mdm-proxy enable --port 9443 --cloudflare --domain mdm.example.com
   sudo sentinel-ops mdm-proxy status    # every line green
   ```

   This gets a Let's Encrypt certificate through Cloudflare DNS (it asks for
   the API token) and serves check-ins on 9443. Not on Cloudflare? Use
   Zoraxy's certificate files instead; see
   [Certificate for port 9443](#certificate-for-port-9443).
3. **Zoraxy: a rule for the MDM hostname on 443.** In Zoraxy, add an **HTTP
   proxy rule** for `mdm.example.com` pointing at the Sentinel Ops frontend
   (`127.0.0.1:41820`, the same target as the app's own rule), and issue a
   certificate for it under **TLS / SSL certificates** (ACME). Discovery,
   the sign-in page and enrollment all arrive here. The certificate from
   step 2 does **not** cover this: it is only used on the MDM port.

Then [check it from outside](#check-it-from-outside) and enroll one test PC
before rolling out.

### Check it from outside

From a machine that is **not** on the server's network (a laptop on a phone
hotspot is fine; Git Bash on Windows has `openssl`):

```bash
H=mdm.example.com
# 443 (Zoraxy, step 3): expect your hostname, issued by Let's Encrypt, "Verify return code: 0 (ok)"
echo | openssl s_client -connect $H:443  -servername $H 2>&1 | grep -E "^ *0 s:|i:|Verify return"
# MDM port (the installer, step 2): the same
echo | openssl s_client -connect $H:9443 -servername $H 2>&1 | grep -E "^ *0 s:|i:|Verify return"
# discovery answers through Zoraxy: expect 200, not a redirect
curl -s -o /dev/null -w "%{http_code}\n" https://$H/EnrollmentServer/Discovery.svc
# check-ins answer through the MDM proxy: expect 401 (a check-in with no certificate)
curl -s -X POST -o /dev/null -w "%{http_code}\n" https://$H:9443/ManagementServer/MDM.svc
```

What a wrong answer means:

| You get | It means |
|---|---|
| `CN=Zoraxy Self-host`, `O=imuslab.com`, "self-signed certificate" on 443 | Zoraxy has no rule or certificate for this hostname (step 3 missing) |
| A 3xx redirect from `Discovery.svc` | Same: Zoraxy is sending the hostname to its default site |
| A certificate for a **different** hostname on either port | That port belongs to another installation (e.g. staging); see [Common mistakes](#common-mistakes) |
| No connection on the MDM port | The proxy isn't running (step 2), or the port isn't forwarded or allowed in a firewall |
| `503` from `MDM.svc` | The application has no proxy secret yet: `sudo sentinel-ops update app` |

## Common mistakes

- **No Zoraxy rule for the MDM hostname.** The easiest one to miss: the app's
  hostname works, the MDM proxy is green, and the console is set up, but
  nothing on 443 knows `mdm.example.com`. Zoraxy then answers with its
  built-in self-signed certificate (`CN=Zoraxy Self-host`) and Windows shows
  **"Website certificate problem: Your organization's website is using an
  untrusted or expired certificate"**. Add the rule and its ACME certificate
  (step 3).
- **Thinking the installer's certificate covers 443.** `mdm-proxy enable
  --cloudflare` gets a certificate for the MDM proxy's port only. Zoraxy needs
  its own for the same hostname on 443. Two certificates for one name is
  normal.
- **Different ports in the console and the installer.** The console's MDM
  port is the address PCs are told to check in on; `--port` is where the
  proxy listens. If they differ (or one has a typo, `9433` against `9443`),
  PCs enroll and then never check in. `mdm-proxy status` prints the port the
  console must show.
- **Two installations behind one public address** (e.g. staging and
  production). Port 443 can be shared: Zoraxy routes by hostname. The MDM port
  **can't**: the MDM proxy ends TLS itself, so each installation needs its own
  port (e.g. staging `9443`, production `9444`), its own port forward to its
  own server, and that port in its own console. If production PCs get
  staging's certificate on the MDM port, the forward points at the wrong
  server.
- **Port open on the server but not on the way in.** The installer opens the
  server's own firewall (ufw/firewalld). The router's port forward, the cloud
  security group, or a Zoraxy Stream Proxy (when Zoraxy holds the public
  address) is still needed for the MDM port.
- **The MDM hostname proxied through Cloudflare** (orange cloud). Cloudflare
  then ends TLS, the PC's certificate never reaches the MDM proxy, and the MDM
  port isn't reachable at all through Cloudflare. Set the record to **DNS
  only** (grey cloud). Only the app's hostname may be proxied.
- **Setting the MDM port after PCs enrolled.** A PC keeps the check-in address
  it enrolled with. PCs enrolled before the port was set (or changed) must
  enroll again.
- **Testing from inside the server's network.** Many routers don't loop
  traffic for their own public address back in (no hairpin NAT), so tests
  from the office can fail or hit a different path than PCs outside. Test
  from a phone hotspot.
- **Reading "We couldn't auto-discover a management endpoint" as the
  error.** Windows shows it whenever the e-mail's domain has no
  `EnterpriseEnrollment` DNS record pointing here, which is normal. Enter the
  discovery address (`https://mdm.example.com/EnrollmentServer/Discovery.svc`)
  in the field it shows; the real error, if any, comes after that.

## What has to be in place

| What | Who | Notes |
|---|---|---|
| A hostname for MDM, e.g. `mdm.example.com` | IT (DNS) | Public, and **permanent**: changing it later means every PC enrolls again. It points at the same public address as your other Sentinel Ops hostnames. |
| A Zoraxy rule for that hostname, with a certificate | IT or you (Zoraxy) | Target: the Sentinel Ops frontend, `127.0.0.1:41820`, like the app's own rule. Issue the certificate under **TLS / SSL certificates** (ACME), as for any hostname. |
| **Port 9443 reaching the Sentinel Ops server** | IT (network) | The one new thing. See below. |
| A certificate for port 9443: a **Cloudflare API token**, or the paths of Zoraxy's certificate files | IT or you | With DNS on Cloudflare, the installer gets and renews its own Let's Encrypt certificate ([below](#certificate-for-port-9443)). Otherwise, Zoraxy keeps its files as `<zoraxy>/conf/certs/mdm.example.com.pem` and `.key`. |
| The MDM proxy, and the port in the console | You | [Below](#once-it-is-done). |

You don't add anything to Zoraxy for port 9443 when Zoraxy and Sentinel Ops
run on the same server: connections to 9443 never go through Zoraxy.

## Message for IT

Copy this, filling in your hostname:

> We're turning on Windows device management in Sentinel Ops. Windows PCs need
> to reach the Sentinel Ops server on a new port, **TCP 9443**, using the same
> hostname as the rest: `mdm.example.com`. Port 443 stays as it is, through
> Zoraxy. Please:
>
> 1. **DNS and Zoraxy**: if `mdm.example.com` doesn't exist yet, point it at
>    our public address, and add a Zoraxy proxy rule for it to the Sentinel Ops
>    frontend (`127.0.0.1:41820`) with an ACME certificate, like the app's rule.
> 2. **Allow inbound TCP 9443 to the Sentinel Ops server** from the internet
>    (wherever company laptops connect from): the cloud security group, or
>    port forwarding on the router or firewall in front of the server, the same
>    way 443 reaches it today. The server's own firewall (ufw/firewalld) is
>    opened by our installer.
> 3. **If Zoraxy and Sentinel Ops are on different machines**, port 9443 must
>    end up at the **Sentinel Ops** machine, not Zoraxy's:
>    - if the public address is on a router or firewall: forward 9443 to the
>      Sentinel Ops server;
>    - if the public address is on the Zoraxy machine itself: in Zoraxy, add a
>      **Stream Proxy** rule (TCP, listening on 9443, to the Sentinel Ops
>      server's 9443). It only passes the connection through; Zoraxy doesn't
>      decrypt it.
> 4. **A certificate for port 9443**, one of:
>    - if our DNS is on Cloudflare: a Cloudflare **API token** with
>      *Zone → DNS → Edit* on the zone of `mdm.example.com` (the "Edit zone
>      DNS" template), and the `mdm.example.com` record set to **DNS only**
>      (grey cloud), not proxied;
>    - otherwise, **where Zoraxy keeps the certificate files** for
>      `mdm.example.com` (`conf/certs/mdm.example.com.pem` and `.key`). If
>      Zoraxy runs in Docker, the path on the host. If Zoraxy is on another
>      machine, those two files need copying to the Sentinel Ops server
>      whenever Zoraxy renews them (every couple of months); a scheduled copy
>      is fine.
> 5. **If our office network restricts outgoing ports**, allow outbound TCP 9443
>    to `mdm.example.com`.

## Which setup do you have?

**Zoraxy and Sentinel Ops on the same server** (the usual case): only items 1,
2 and 4 above. The certificate paths are local, and the installer refreshes
its copy itself.

**Zoraxy on another machine, public address on a router or firewall**: the
router sends 443 to Zoraxy (as today) and 9443 to the Sentinel Ops server.
Use the Cloudflare certificate if you can; otherwise Zoraxy's certificate
files have to be copied to the Sentinel Ops server when Zoraxy renews them,
and `--cert`/`--key` point at the copies.

**Zoraxy on another machine that holds the public address itself**: a Zoraxy
Stream Proxy on 9443 forwards to the Sentinel Ops server's 9443. The
certificate as above.

## Certificate for port 9443

PCs check the MDM proxy's certificate like any HTTPS site, so it has to be a
public one for the MDM hostname. There are two ways to give it one.

**Let's Encrypt through Cloudflare DNS** (`--cloudflare`). The installer runs
certbot in a container (`certbot/dns-cloudflare`, pinned; nothing is installed
on the server), proves it controls the hostname by creating a temporary TXT
record through the Cloudflare API, and gets the certificate. No port has to
reach this server for that, so it works wherever Zoraxy runs, and nothing is
copied between machines. The daily timer renews it 30 days before it expires.

- The API token: Cloudflare, **My Profile → API Tokens → Create Token → Edit
  zone DNS**, limited to the one zone. It can change any record in that
  zone, so you can also limit it to the server's outgoing IP address (**Client
  IP Address Filtering**). The installer keeps it in
  `config/mdm-proxy/cloudflare.ini`, readable by root only, and removes it on
  `mdm-proxy disable`.
- The MDM hostname's record must be **DNS only** (grey cloud). Proxied through
  Cloudflare, Cloudflare ends the TLS connection, the PC's certificate never
  reaches the MDM proxy, and check-ins fail.
- Zoraxy still issues its own certificate for the hostname on 443 (discovery
  and the sign-in page). Two certificates for one name, from two machines, is
  fine.

**Zoraxy's certificate files** (`--cert`/`--key`): the installer copies them
and the daily timer copies them again after Zoraxy renews. Simple when Zoraxy
is on the same server; from another machine, something has to copy the files
over first.

**Cloud server (AWS, Azure, ...)**: allow inbound TCP 9443 in the server's
security group / network security group, as 443 is.

## Once it is done

1. **Update** the installer, then the application (which needs the MDM port
   setting, sentinel-ops#611):

   ```bash
   sudo sentinel-ops self-update
   sudo sentinel-ops update app
   ```
2. **Start the MDM proxy** with a [certificate](#certificate-for-port-9443).
   From Let's Encrypt through Cloudflare (it asks for the token):

   ```bash
   sudo sentinel-ops mdm-proxy enable --port 9443 --cloudflare --domain mdm.example.com
   ```

   Or with Zoraxy's files:

   ```bash
   sudo sentinel-ops mdm-proxy enable --port 9443 \
     --cert /path/to/zoraxy/conf/certs/mdm.example.com.pem \
     --key  /path/to/zoraxy/conf/certs/mdm.example.com.key
   ```

   Without these options it asks. `--email` gives Let's Encrypt an address
   for account notices; unattended, pass the token as `CLOUDFLARE_API_TOKEN`
   (`sudo CLOUDFLARE_API_TOKEN=... sentinel-ops -y mdm-proxy enable --cloudflare
   --domain ...`), never as an option. It checks that the certificate and key
   belong together and haven't expired, opens 9443 in the server's firewall,
   and starts the proxy. A daily timer renews the Let's Encrypt certificate, or
   picks up Zoraxy's renewed one.
3. **Check it**:

   ```bash
   sudo sentinel-ops mdm-proxy status
   ```

   Every line should be green: the proxy is running, the certificate is valid,
   it requests client certificates, and the app answers through it.
4. **In the console**: **Settings → MDM**, set the **MDM hostname** (if it
   isn't set) and the **MDM port** to `9443`, and save. The card shows the two
   addresses PCs will use.
5. **Test from outside**: from a laptop that is *not* on the server's network
   (a phone hotspot is fine), open `https://mdm.example.com:9443/` in a
   browser. The browser may offer to send a certificate; cancel. A blank
   "404" page means the port is reachable; a timeout means item 2 of the IT
   message isn't done yet.
6. **Enroll one test PC** (Pro, Enterprise or Education; Home can't enroll),
   from its device page: **Windows MDM → Enroll in MDM**. Within a few minutes
   its card should show a **last check-in**. Only then roll out further.

Set the port **before** PCs enroll: a PC remembers the address it enrolled
with, so PCs enrolled earlier keep trying 443 until they enroll again.

## When something is wrong

| What you see | Likely cause | What to do |
|---|---|---|
| Windows: "We couldn't auto-discover a management endpoint" | The e-mail domain has no `EnterpriseEnrollment` record pointing here; normal | Enter `https://mdm.example.com/EnrollmentServer/Discovery.svc` as the server |
| Windows: "Website certificate problem" while enrolling | Port 443 serves an untrusted certificate for the MDM hostname, usually Zoraxy's self-signed default because it has no rule for the hostname | [Quick setup](#quick-setup-three-steps), step 3; then [check it from outside](#check-it-from-outside) |
| Windows: `0x80192F0C` while enrolling | Something on 443 asks for a client certificate on the MDM hostname | Turn that off on 443; client certificates belong on the MDM port only |
| The MDM port serves another installation's certificate | Two installations share a public address and the forward points at the other one | Give each its own port; see [Common mistakes](#common-mistakes) |
| PCs enroll, but the console says none has checked in | The MDM port isn't set in the console, or 9443 doesn't reach the server | Check **Settings → MDM** shows the check-in address with `:9443`; do step 5 above |
| `mdm-proxy status`: "Reaches the app: 503" | The application has no proxy secret yet | `sudo sentinel-ops update app` |
| `mdm-proxy status`: the certificate expires soon | Zoraxy's files aren't being renewed, or the copy from another machine stopped; with Cloudflare, renewal is failing | Renew in Zoraxy (or fix the copy), then `sudo sentinel-ops mdm-proxy sync-cert`. With Cloudflare, run `sync-cert` and read `sentinel-ops logs installer` |
| `mdm-proxy enable --cloudflare`: "Let's Encrypt did not issue the certificate" | The token can't edit DNS in the hostname's zone, or has expired | Check the token's zone and permission (*Zone → DNS → Edit*) and its IP filter, then enable again |
| `mdm-proxy enable`: "the key does not belong to the certificate" | The `.pem` and `.key` are from different hostnames or renewals | Use the pair from the same Zoraxy certificate |
| Step 5 times out | A firewall, security group or router doesn't pass 9443 | Back to IT, item 2 (or 3) |
| Laptops at a hotel or on guest Wi-Fi stop checking in | That network only allows ports 80 and 443 out | Nothing to fix: they catch up on a normal network. The agent keeps working. |
| You moved the port | PCs enrolled before keep the old address | Enroll them again |

To turn it off: `sudo sentinel-ops mdm-proxy disable`, then clear the MDM port
in the console.

## Questions IT may ask

- **Why not use port 443 for everything?** Check-ins need the server to ask
  for the PC's certificate, and enrolling needs it not to. TLS is set up before
  the server knows which of the two a connection is for, so they need
  different ports. A second port changes nothing about the existing setup.
- **Is 9443 exposed to everything?** Only the check-in path answers on it;
  every other request gets a 404, and every check-in needs a certificate this
  server issued to that PC, which the application checks.
- **Does anything decrypt traffic in between?** No. The MDM proxy is where TLS
  ends for port 9443, as Zoraxy is for 443.
- **Can it be another port?** Yes: pass `--port`, and set the same port in the
  console. Ports 443, 8000 and the application's own port can't be used.
  9443 is also Portainer's default HTTPS port; if that server runs Portainer,
  pick another. An installation that already runs the MDM proxy keeps its
  port: moving it is `mdm-proxy enable --port <new>`, the console's MDM port,
  and the network rules, and PCs enrolled on the old port must enroll again.
- **Does the Sentinel Ops agent need 9443?** No. The agent uses the normal
  application address; only Windows' own MDM client uses 9443.
