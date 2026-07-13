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

### Networking

`curl`, `wget`, `dig` / `nslookup`, `ping`, `traceroute`, `netcat`, `telnet`, `tftp`, `ip`, `netstat`, `tcpdump`, `mtr`, `nmap`, `ncat`, `socat`

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
7. **final** - Clean single-layer output image with `/bin/zsh` as the default shell

## CI/CD

Pushes to the `latest` branch build and publish multi-arch images to both Docker Hub and GHCR, followed by smoke tests against the published image. The workflow also extracts the image SBOMs, submits them to the GitHub dependency graph, and attests the SBOM for the GHCR image.
