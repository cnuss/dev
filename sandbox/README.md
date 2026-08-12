# Network sandbox

Supporting pieces for the root **[docker-compose.yml](../docker-compose.yml)**,
which runs this repo's image under the same network confinement as Claude
Code's hosted environment: no route to the internet of its own, and one exit —
a proxy that intercepts `:80`/`:443`/`:53` transparently, re-terminates TLS
with its own CA, and applies whatever `allowlist.txt` says.

```
   ┌──────────────┐      sandbox (routable, no NAT)        ┌──────────────┐
   │     dev      │ ─── default route, everything ──────►  │    proxy     │
   │ ./Dockerfile │      :80/:443/:53 REDIRECTed           │  mitmproxy   │
   └──────────────┘      the rest dropped                  └──────┬───────┘
      HTTPS_PROXY=http://proxy:8080     :8080 CONNECT             │ egress (bridge)
      default via 172.31.240.10         :8082 transparent         ▼
      nameserver 172.31.240.10          :53   DNS            allowlist.txt
      SSL_CERT_FILE=/certs/ca-bundle.crt                     ( `*` by default )
```

Two things are true at once:

**Everything routes through the proxy.** `dev` has exactly one default route
and it points at the proxy, which forwards nothing: `FORWARD` policy is `DROP`
and no `MASQUERADE` rule is ever added, so a sandbox packet either lands on one
of its listeners or dies there. That is what makes ICMP and uncaptured ports
dead ends. The proxy reaches the internet over `egress`, a separate NAT'd
bridge.

The network is created with `enable_ip_masquerade=false`, which on native Linux
also makes a *deliberate* reroute pointless — no NAT rule for the subnet means
an unroutable private source and no return path. On Docker Desktop it buys
nothing, because the VM masquerades everything leaving it regardless of the
per-bridge setting. `sandbox-verify` reports which case you are in, as a `WARN`
rather than a failure: the hosted environment offers no protection here either.
Its egress is a filter, and raw TCP to arbitrary IPs works.

**Capture is transparent.** `:80`, `:443` and `:53` are `REDIRECT`ed onto
mitmproxy regardless of client configuration, so a client that ignores
`HTTPS_PROXY` — Node's built-in `fetch`, `aiohttp`, a hand-rolled Go dialer —
is intercepted rather than broken. `HTTPS_PROXY` is still set and still works;
it is a convenience for tools that honour it, not the boundary. This is exactly
the hosted environment's arrangement.

### Why not `internal: true`

That was the original design, and it cannot work with transparent capture.
Docker programs this on the host for an internal network
([libnetwork `setupInternalNetworkRules`](https://github.com/moby/moby/blob/master/libnetwork/drivers/bridge/setup_ip_tables_linux.go)):

```
-i br-X ! -d 172.31.240.0/24 -j DROP
```

Every packet with an off-subnet destination is dropped *at the bridge*, before
it can reach the proxy container — which is precisely the traffic a transparent
gateway exists to intercept. Measured directly: with `internal: true` the
`:80`/`:443` REDIRECT rule matched **0 packets** while the `:53` rule (whose
traffic is addressed to the in-subnet proxy) matched fine.

The workarounds that keep the destination in-subnet — spoofing DNS to return
the proxy's address, or DNAT inside `dev` — do not help either, because
mitmproxy's transparent mode hard-requires the real original destination:

```python
class TransparentProxy(DestinationKnown):
    assert self.context.server.address, "No server address set."
```

It reads that from `SO_ORIGINAL_DST`, which is set by the redirect in the
proxy's own netns. Rewrite the destination anywhere upstream and mitmproxy
connects to itself.

So the choice is capture *or* `internal: true`. This stack takes capture,
because it is what the hosted environment does, and recovers the confinement
through the missing NAT rule instead. To go the other way, set
`SANDBOX_TRANSPARENT=0` and restore `internal: true` on the network.

## Quick start

From the repo root:

```bash
docker compose up -d
docker compose exec dev sandbox-verify   # assert the boundary holds
docker compose exec dev zsh              # get to work
```

`dev` builds the repo's `Dockerfile` (`target: final`), so the first `up` runs
the whole multi-stage build — homebrew, apt, claude, SBOM — and takes a while.
`docker compose up -d proxy` brings up just the egress tier if that is all you
need.

`sandbox-verify` is the interesting part — it checks that ICMP and uncaptured
ports go nowhere, that a query aimed at `1.1.1.1` is captured and answered,
that traffic verifies against the sandbox CA alone (proving TLS really is
re-terminated), and — the point of the transparent tier — that a client passing
`--noproxy '*'` is intercepted anyway rather than failing.

## Editing the policy

`allowlist.txt` is the whole policy. It is re-read on mtime change, so an edit
takes effect on the next request — no restart.

```
*               # any host — open egress, the shipped default
example.com     # exact host only
.example.com    # the domain and every subdomain
*.example.com   # same as .example.com
```

Denials are invisible to `curl` (a failed `CONNECT` has no readable body), so
the proxy exposes the reason:

```bash
docker compose exec dev curl -s --noproxy '*' http://proxy:8081/status | jq
```

```json
{
  "allowlist": [".github.com", "pypi.org", "..."],
  "allowedPorts": [443],
  "deniedRequests": 3,
  "dnsAllowedQueries": 41,
  "dnsDeniedQueries": 2,
  "recentDenials": [
    {"time": "...", "host": "example.org", "port": 443, "reason": "not-in-allowlist", "status": 403},
    {"time": "...", "host": "exfil.example.net", "port": 53, "reason": "dns-not-in-allowlist", "status": "NXDOMAIN"}
  ]
}
```

## Behaviours copied from the hosted environment

| Behaviour | Why |
|---|---|
| Only `HTTPS_PROXY` is set, never `HTTP_PROXY` | Matches the hosted variable set; the proxy serves only the `CONNECT` path |
| Explicit plain-HTTP proxy requests get **405** | Same signal the hosted proxy gives. Transparently captured `:80` traffic is exempt — that is ordinary traffic, not a misconfigured client |
| Non-443 ports get **403** on the explicit proxy | Matches "non-443 HTTPS ports are not supported" |
| A pile of per-tool CA variables | `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`, `AWS_CA_BUNDLE`, `GIT_SSL_CAINFO`, `CARGO_HTTP_CAINFO`, … — no single variable covers every runtime |
| `ca-bundle.crt` = public roots **+** the proxy CA | So `no_proxy` destinations, which never see the interception CA, still verify against a real chain |
| CA also installed via `update-ca-certificates` | For tools that read only the system store (`openssl s_client`, some Go/Rust binaries, `apt`) |

The CA is minted once by the `ca` service into a shared volume and reused
across restarts, so a trust store you built by hand does not go stale. The
private key lives in the volume — this is a development sandbox, not a
production egress tier.

## What the hosted environment actually does

Measured, not assumed — the defaults here are set to match:

| Probe | Hosted result | Here |
|---|---|---|
| `CONNECT` to 56 hosts incl. `pastebin.com`, `webhook.site`, `ngrok.com` | all `200` | all `200` (`*` policy) |
| Direct TCP :443 ignoring the proxy | intercepted, cert issued by `O = Anthropic, CN = Egress Gateway SDS Issuing CA` | intercepted, cert issued by the sandbox CA |
| Direct TCP :80 ignoring the proxy | real origin response | intercepted, forwarded |
| UDP :53 to `8.8.8.8`, `1.1.1.1`, `9.9.9.9` | all answered | all answered (`REDIRECT`ed to the local resolver) |
| TCP :53, other ports | timeout | dropped |
| ICMP echo to `8.8.8.8`, `1.1.1.1` | no reply | dropped |
| TLS SNI for a host that does not exist | gateway mints a leaf anyway | mitmproxy mints a leaf anyway |

The one thing the hosted environment does **not** do is filter. Its policy
machinery is real — the proxy documents `403`/`407` for denied hosts and
records them — but nothing was denied in this session. So `allowlist.txt` ships
with `*`.

The differences that remain are structural and unavoidable:

* **Choice of resolver.** There, a query to `1.1.1.1` really reaches Cloudflare.
  Here it is redirected to the proxy's resolver, which answers it. Same
  observable result, different path.
* **Escape hatch.** There, egress is a filter that currently passes everything.
  Here, anything the proxy does not explicitly capture hits `FORWARD DROP` and
  has no NAT to fall back on, so a protocol nobody thought about fails closed
  rather than open.

## Turning the policy on

`allowlist.txt` ships open to match the hosted environment. Delete the `*` and
it becomes deny-by-default, governing both tiers at once — an unlisted host
cannot be connected to *and cannot be resolved*, which is what keeps a lookup
for `<secrets>.attacker.example` from being a way out. The curated list already
in the file (registries, distro archives, source hosting) becomes the policy.

`sandbox-verify` notices which mode is active and asserts accordingly; the
policy checks report `SKIP` while `*` is present rather than failing.

## Configuration

Copy `env.example` (repo root) to `.env`. Everything is optional.

| Variable | Default | Meaning |
|---|---|---|
| `SANDBOX_BASE_IMAGE` | `ubuntu:26.04` | Passed to the root Dockerfile's `BASE_IMAGE` |
| `SANDBOX_ALLOWED_PORTS` | `443` | Ports the explicit proxy will `CONNECT` to |
| `SANDBOX_ALLOW_PLAIN_HTTP` | `0` | `1` permits explicit plain-HTTP proxying instead of 405 |
| `SANDBOX_TRANSPARENT` | `1` | `0` disables the redirect — explicit proxy only |
| `SANDBOX_CA_CN` / `SANDBOX_CA_DAYS` | … / `3650` | CA identity and lifetime |
| `SANDBOX_PROXY_UID` | `1000` | uid the mitmproxy image runs as; owns the CA key |
| `SANDBOX_MITMPROXY_IMAGE` / `SANDBOX_ALPINE_IMAGE` | pinned | Support image versions |

### Confining a different image

The `dev` service builds this repo, but nothing about the sandbox depends on
that. Replace its `build:` block with an `image:` and the rest still applies:

```yaml
dev:
  image: node:22
```

The entrypoint and `sandbox-verify` are bind-mounted, not baked, so they follow
any image with a shell. Debian/Ubuntu bases also get the CA in the system trust
store; elsewhere the `*_CA_BUNDLE` variables still apply and the entrypoint
says so rather than failing.

## How DNS works

The hosted environment answers whichever nameserver you aim at — `8.8.8.8`,
`1.1.1.1` and `9.9.9.9` all responded when probed. That is reproduced here by
capture rather than by routing: a `REDIRECT` on `:53` sends every query to the
proxy's own resolver no matter what destination the client picked, so
`nslookup example.com 1.1.1.1` works exactly as it does upstream.

The entrypoint also writes `nameserver 172.31.240.10` into `/etc/resolv.conf`,
so the ordinary path does not depend on the redirect at all. That takes
Docker's embedded resolver (127.0.0.11) out of the picture — it forwards misses
to the daemon's own nameservers, which keeps working on an `internal` network
and would be a lookup path the proxy never sees. `proxy` itself still resolves
because compose puts it in `/etc/hosts` and nsswitch reads `files` before
`dns`.

With `*` in the allowlist every name is forwarded. Remove it and the resolver
filters too: unlisted names are answered NXDOMAIN locally and no query leaves
the box. NXDOMAIN rather than REFUSED so glibc fails fast and unambiguously
("Name or service not known") instead of reporting a temporary failure.

A missing allowlist entry then shows up as a DNS failure rather than a 403.
`/status` reports both — check `recentDenials` for a `dns-not-in-allowlist`
reason before assuming the network is broken.

## Known gaps

**Not proxyable.** By construction this stack cannot carry gRPC/HTTP-2-only
APIs, WebSocket upgrades, client-mTLS, certificate-pinned clients, or raw TCP
(databases, SSH). Same limitations as the hosted proxy — they need a hole
punched deliberately, not worked around.

**Capabilities.** Transparent capture costs `NET_ADMIN` on both containers —
the proxy programs the redirect, `dev` replaces its own default route. A root
process in `dev` can therefore rewrite its routing and go around the proxy. On
native Linux that is a dead end (no NAT for the subnet); on Docker Desktop it
reaches the internet, and `sandbox-verify` says so. This confines a workload,
not an adversary with root inside it. For that, `SANDBOX_TRANSPARENT=0` plus
`internal: true` is the only airtight configuration here — and it gives up
capture.

**Scope.** This confines the network only. Filesystem and syscalls are stock
Docker defaults — this image deliberately ships `tcpdump`, `nmap`, and
`nsenter`.

## Layout

```
docker-compose.yml       networks, services, the environment contract (repo root)
env.example              knobs (repo root)
sandbox/
├── allowlist.txt        the policy
├── entrypoint.sh        default route + resolver + CA, then the normal command
├── verify.sh            sandbox-verify: asserts the boundary from inside
├── ca/                  one-shot CA mint (openssl)
└── proxy/               mitmproxy + the policy addon
    ├── entrypoint.sh    programs the transparent-capture redirect
    ├── sandbox_proxy.py enforcement + /status endpoint
    └── test_rules.py    python3 sandbox/proxy/test_rules.py
```
