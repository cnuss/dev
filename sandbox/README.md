# Network sandbox

Supporting pieces for the root **[docker-compose.yml](../docker-compose.yml)**,
which runs this repo's image under the same network confinement as Claude
Code's hosted environment: no route to the internet at all, and one narrow
exception — an HTTP `CONNECT` proxy that terminates TLS with its own CA and
refuses any host that is not on an allowlist.

```
   ┌──────────────┐        sandbox (internal: true)        ┌──────────────┐
   │     dev      │ ─────── no default route, no NAT ────► │    proxy     │
   │ ./Dockerfile │        the only reachable peer         │  mitmproxy   │
   └──────────────┘                                        └──────┬───────┘
      HTTPS_PROXY=http://proxy:8080          :8080 CONNECT        │ egress (bridge)
      nameserver 172.31.240.10               :53    DNS           ▼
      SSL_CERT_FILE=/certs/ca-bundle.crt                     allowlist.txt
                                                       everything else 403 / NXDOMAIN
```

The confinement is structural, not advisory. `sandbox` is an `internal: true`
network, so Docker programs no gateway and no masquerade rule for it — a
process in `dev` cannot send an IP packet off the host even if it ignores every
proxy variable, drops the CA, or runs as root.

One allowlist governs both tiers. A host that is not on it cannot be connected
to *and cannot be resolved*, which is what keeps a lookup for
`<secrets>.attacker.example` from being a way out.

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

`sandbox-verify` is the interesting part — it checks that there is no default
route, that raw HTTPS and ICMP off-network fail, that an allowlisted host
succeeds *and* verifies against the sandbox CA alone (proving TLS really is
re-terminated), and that denied hosts, non-443 ports, and plain-HTTP proxying
are refused.

## Editing the policy

`allowlist.txt` is the whole policy. It is re-read on mtime change, so an edit
takes effect on the next request — no restart.

```
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
| Only `HTTPS_PROXY` is set, never `HTTP_PROXY` | A client that falls back to plain HTTP should fail loudly, not quietly skip the `CONNECT` path |
| Plain-HTTP proxy requests get **405** | Same signal the hosted proxy gives; set `SANDBOX_ALLOW_PLAIN_HTTP=1` to permit them |
| Non-443 ports get **403** | Matches "non-443 HTTPS ports are not supported" |
| A pile of per-tool CA variables | `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`, `AWS_CA_BUNDLE`, `GIT_SSL_CAINFO`, `CARGO_HTTP_CAINFO`, … — no single variable covers every runtime |
| `ca-bundle.crt` = public roots **+** the proxy CA | So `no_proxy` destinations, which never see the interception CA, still verify against a real chain |
| CA also installed via `update-ca-certificates` | For tools that read only the system store (`openssl s_client`, some Go/Rust binaries, `apt`) |

The CA is minted once by the `ca` service into a shared volume and reused
across restarts, so a trust store you built by hand does not go stale. The
private key lives in the volume — this is a development sandbox, not a
production egress tier.

## Where this deliberately differs

The hosted environment enforces policy with a **transparent** egress gateway:
outbound TCP/443 is intercepted regardless of client configuration, and the
gateway mints a leaf for whatever SNI is presented (issuer `O = Anthropic,
CN = Egress Gateway SDS Issuing CA`). `HTTPS_PROXY` there is a convenience for
tools that honour it, not the boundary. Its DNS is unrestricted — UDP/53 to any
resolver works.

This stack inverts both:

| | hosted | here |
|---|---|---|
| Boundary | transparent interception of :443 | `internal: true`, no route at all |
| Proxy-unaware clients | silently intercepted, still work | fail to connect |
| DNS | open to any resolver | one filtered resolver, allowlist-scoped |

The `internal: true` boundary is the stronger of the two — nothing escapes it,
including protocols the gateway never sees. The cost is that a client ignoring
`HTTPS_PROXY` (see below) breaks instead of being caught. Adding transparent
capture on top would need the proxy container to become the sandbox's default
gateway, with `NET_ADMIN`, `ip_forward`, and an iptables `REDIRECT` of :443 to
a second `--mode transparent` listener. Worth doing if proxy-unaware tooling
matters more than the simplicity; it is not wired up here.

## Configuration

Copy `env.example` (repo root) to `.env`. Everything is optional.

| Variable | Default | Meaning |
|---|---|---|
| `SANDBOX_BASE_IMAGE` | `ubuntu:26.04` | Passed to the root Dockerfile's `BASE_IMAGE` |
| `SANDBOX_ALLOWED_PORTS` | `443` | Ports the proxy will `CONNECT` to |
| `SANDBOX_ALLOW_PLAIN_HTTP` | `0` | `1` permits plain-HTTP proxying instead of 405 |
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

## How DNS is confined

Docker's embedded resolver (127.0.0.11) forwards misses to the daemon's own
nameservers, and that keeps working on an `internal` network — so by default a
sandboxed container cannot *reach* the internet but can still *query* it. No
data path for ordinary traffic, but a fine exfiltration channel.

The entrypoint closes it by overwriting `/etc/resolv.conf` with a single
`nameserver 172.31.240.10`, the proxy's own address. From then on:

* The embedded resolver is out of the picture entirely.
* The only reachable DNS server is on the sandbox network, and it filters
  against the same `allowlist.txt` — a name that is not listed is answered
  NXDOMAIN locally and no query ever leaves.
* `proxy` still resolves, because compose puts it in `/etc/hosts` (`extra_hosts`)
  and nsswitch reads `files` before `dns`. Service discovery never has to
  survive the switch.
* Actual resolution happens on the proxy's egress leg — which is what
  `CLAUDE_CODE_PROXY_RESOLVES_HOSTS=true` means in the hosted environment.

NXDOMAIN rather than REFUSED so glibc fails fast and unambiguously ("Name or
service not known") instead of retrying and reporting a temporary failure.
`sandbox-verify` asserts all of it, including that an invented name under an
unlisted domain does not resolve.

One consequence worth knowing: a host is unreachable *and* unresolvable until
it is on the allowlist, so a missing entry now shows up as a DNS failure rather
than a 403. `/status` reports both — check `recentDenials` for a
`dns-not-in-allowlist` reason before assuming the network is broken.

## Known gaps

**Not proxyable.** By construction this stack cannot carry gRPC/HTTP-2-only
APIs, WebSocket upgrades, client-mTLS, certificate-pinned clients, or raw TCP
(databases, SSH). Same limitations as the hosted proxy — they need a hole
punched deliberately, not worked around.

**Clients that ignore `HTTPS_PROXY`.** Node's built-in `fetch` (use
`NODE_USE_ENV_PROXY=1` on Node ≥ 22.21), `aiohttp` (`trust_env=True`), Ruby
bundler (reads only `HTTP_PROXY`), and hand-rolled Go dialers will time out
rather than route. In this sandbox that is a hard failure, not a bypass.

**Scope.** This confines the network only. Capabilities, filesystem, and
syscalls are stock Docker defaults — this image deliberately ships `tcpdump`,
`nmap`, and `nsenter`.

## Layout

```
docker-compose.yml       networks, services, the environment contract (repo root)
env.example              knobs (repo root)
sandbox/
├── allowlist.txt        the policy
├── entrypoint.sh        installs the CA, then runs the normal command
├── verify.sh            sandbox-verify: asserts the boundary from inside
├── ca/                  one-shot CA mint (openssl)
└── proxy/               mitmproxy + the allowlist addon
    ├── sandbox_proxy.py enforcement + /status endpoint
    └── test_rules.py    python3 sandbox/proxy/test_rules.py
```
