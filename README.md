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

## CI/CD

Pushes to the `latest` branch build and publish multi-arch images to both Docker Hub and GHCR, followed by smoke tests against the published image. The workflow also extracts the image SBOMs, submits them to the GitHub dependency graph, and attests the SBOM for the GHCR image.
