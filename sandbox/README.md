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
      HTTPS_PROXY=http://proxy:8080                                │ egress (bridge)
      SSL_CERT_FILE=/certs/ca-bundle.crt                           ▼
                                                              allowlist.txt
                                                            everything else 403
```

The confinement is structural, not advisory. `sandbox` is an `internal: true`
network, so Docker programs no gateway and no masquerade rule for it — a
process in `dev` cannot send an IP packet off the host even if it ignores every
proxy variable, drops the CA, or runs as root.

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
  "recentDenials": [
    {"time": "...", "host": "example.org", "port": 443, "reason": "not-in-allowlist", "status": 403}
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

## Known gaps

**DNS.** Docker's embedded resolver (127.0.0.11) forwards queries via the
daemon on the host, so a container on an `internal` network can still *resolve*
public names even though it cannot reach them. That is no data path for
ordinary traffic, but it is a DNS-exfiltration channel. To close it, uncomment
the two lines on the `dev` service:

```yaml
dns: ["127.0.0.1"]                    # black-hole the resolver
extra_hosts: ["proxy:172.31.240.10"]  # the one name that still needs to work
```

Names are then resolved only by the proxy, on its own leg — which is exactly
what `CLAUDE_CODE_PROXY_RESOLVES_HOSTS=true` means upstream.

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
