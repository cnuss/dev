# cnuss/dev

A containerized development environment with Kubernetes tools, networking utilities, and the Claude CLI. Multi-arch (`amd64`/`arm64`), built on Ubuntu.

## Quick Start

```bash
# Docker
docker run -it cnuss/dev

# Kubernetes
kubectl run dev --rm -it --image=cnuss/dev -- zsh
```

Also available from GitHub Container Registry:

```bash
docker run -it ghcr.io/cnuss/dev
kubectl run dev --rm -it --image=ghcr.io/cnuss/dev -- zsh
```

## What's Included

### Kubernetes & DevOps

| Tool | Description |
|------|-------------|
| `kubectl` | Kubernetes CLI |
| `k9s` | Terminal UI for Kubernetes |
| `kubectx` / `kubens` | Fast context and namespace switching |
| `etcd` / `etcdctl` | Distributed key-value store |
| `prometheus` / `promtool` | Metrics & monitoring toolkit |
| `docker` (CLI) | Docker client |

### Data Processing

| Tool | Description |
|------|-------------|
| `jq` | JSON processor |
| `yq` | YAML processor |
| `ripgrep` (`rg`) | Fast text search |
| `fzf` | Fuzzy finder |

### Crypto / Tokens

| Tool | Description |
|------|-------------|
| `jwt` (jwt-cli) | Encode / decode / inspect JWTs |
| `step` | JWT sign/verify (incl. JWKS), JWK generation, keypairs, x509 / PKI |
| `jose` | JWS / **JWE** / JWK — encrypted tokens, which `jwt` and `step` don't cover |
| `openssl` | Key and certificate primitives |

Verify a Kubernetes service account token against the cluster's JWKS:

```bash
kubectl create token default \
  | step crypto jwt verify --jwks <(kubectl get --raw /openid/v1/jwks) --iss https://kubernetes.default.svc
```

### Networking

`curl`, `wget`, `dig` / `nslookup`, `ping`, `traceroute`, `netcat`, `telnet`, `tftp`, `ip`, `netstat`, `tcpdump`, `mtr`, `nmap`, `ncat`, `socat`

### Connectivity / Overlay

| Tool | Description |
|------|-------------|
| `cloudflared` | Cloudflare Tunnel client — reach a cluster-internal service from outside, or reach out through egress-restricted networks |
| `tailscale` / `tailscaled` | Tailscale CLI and daemon — join the pod to a tailnet, or use it as a subnet router / exit node |

As with FRR, these ship as binaries only — no baked credentials, no daemon started. Both are runtime concerns:

- `tailscaled` needs `/dev/net/tun` plus `NET_ADMIN`, or `--tun=userspace-networking` to run without them. Auth via `TS_AUTHKEY` / `tailscale up --authkey`.
- `cloudflared` needs no special capabilities; supply the tunnel token or credentials file at pod start.

### BGP / Routing

| Tool | Description |
|------|-------------|
| FRR (`vtysh`, `bgpd`, `zebra`) | BGP speaker / routing suite (binaries only — no baked config, no running daemon; render `frr.conf` at pod start) |
| `bgpq4` | Generate prefix-lists from IRR data, diff against reality |

BGP speaking and route programming require `NET_ADMIN` + `NET_RAW` capabilities in the pod `securityContext` — a runtime concern, not baked into the image.

### Namespaces / Process Debugging

`nsenter`, `unshare`, `lsns`, `mount`, `findmnt` (from `util-linux`)

Entering another container's namespaces needs `hostPID: true` plus `privileged: true` in the pod spec — or at minimum `CAP_SYS_ADMIN` and `CAP_SYS_PTRACE`:

```bash
nsenter --target 1 --mount --uts --ipc --net --pid -- ip addr
```

`util-linux` is `Essential` in the Ubuntu base, but it's pinned in `.apt/packages` and smoke-tested so a slimmer `BASE_IMAGE` can't silently drop it.

### Node Host Access (`noded`)

`noded` shells from the privileged `debug: true` sidecar onto the underlying flex-node EC2 host — the container shares the host's network namespace, so the host sshd is reachable at `127.0.0.1:22` even though `nsenter` can't reach the host (its PID/mount namespaces belong to the `kube1` nspawn machine). The image bakes `NODED_PROVISION=1` and `NODED_KEEPALIVE=1`, so a sidecar needs only `command: ["noded"]` plus a read-write `/etc/ssh` hostPath to self-provision host trust and land on the node.

See **[.bin/noded.md](.bin/noded.md)** for the deployment manifest, credential modes (self-provision / step-ca / key), the `s` vs `a` distinction, and the full environment reference.

### General

`git`, `zsh`, `vim`, `less`, `busybox`, `tar`, `gzip`, `bzip2`, `xz`, `unzip`, `sudo`

### AI

`claude` - Anthropic's Claude CLI

## Build

```bash
docker build -t cnuss/dev .
```

The Dockerfile uses a multi-stage build:

1. **homebrew** - Installs tools from `Brewfile` via Homebrew, copies binaries and shared libs
2. **bins** - Installs system packages from `.apt/packages` (with extra apt repos from `.apt/sources/`)
3. **claude** - Installs the Claude CLI
4. **sbom** - Merges the per-stage Syft SPDX scans into a single SBOM
5. **combined** - Merges all stages; ships the SBOM at `/usr/local/share/sbom/sbom.spdx.json`
6. **smoke-test** - Validates all tools work
7. **final** - Clean single-layer output image; `/bin/zsh` is the build `SHELL`, and the default `CMD` is `sleep infinity` so the container idles for `kubectl exec` / `docker exec` instead of exiting

## Network Sandbox

`docker-compose.yml` runs this image with the same network confinement as
Claude Code's hosted environment: the container sits on an `internal: true`
network with no route off the host, and its only peer is an allowlisting
`CONNECT` proxy that re-terminates TLS with its own CA.

```bash
docker compose up -d                     # builds ./Dockerfile — not quick
docker compose exec dev sandbox-verify   # assert the boundary holds
docker compose exec dev zsh
```

`:80`, `:443` and `:53` are redirected onto the proxy regardless of client
configuration, so tools that ignore `HTTPS_PROXY` are intercepted rather than
broken — the hosted environment's arrangement, and the reason the network is
`internal: true` with the proxy as its only route.

Egress policy is `sandbox/allowlist.txt`, re-read live, governing connections
and name resolution alike. It ships as `*` (open) because that is what the
hosted environment measurably does; delete the `*` for deny-by-default. See
**[sandbox/README.md](sandbox/README.md)** for the measurements, the knobs, and
the protocols a proxy of this shape cannot carry.

## CI/CD

Pushes to the `latest` branch build and publish multi-arch images to both Docker Hub and GHCR, followed by smoke tests against the published image. The workflow also extracts the image SBOMs, submits them to the GitHub dependency graph, and attests the SBOM for the GHCR image.

The same workflow runs on a weekly schedule (Mondays 06:00 UTC) to pick up base image and package updates. Scheduled runs execute on the default branch, so they publish exactly like a push, and they build with `no-cache` — a cached rebuild would reinstall the identical packages and defeat the purpose. Expect them to take noticeably longer than a normal push build.

GitHub disables scheduled workflows in repos with no activity for 60 days; re-enable from the Actions tab if that happens.
