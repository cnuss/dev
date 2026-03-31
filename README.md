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
| `docker` (CLI) | Docker client |

### Data Processing

| Tool | Description |
|------|-------------|
| `jq` | JSON processor |
| `yq` | YAML processor |
| `ripgrep` (`rg`) | Fast text search |
| `fzf` | Fuzzy finder |

### Networking

`curl`, `wget`, `dig` / `nslookup`, `ping`, `traceroute`, `netcat`, `telnet`, `tftp`, `ip`, `netstat`

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
2. **bins** - Installs system packages from `.apt/packages`
3. **claude** - Installs the Claude CLI
4. **combined** - Merges all stages
5. **smoke-test** - Validates all tools work
6. **final** - Clean single-layer output image with `/bin/zsh` as the default shell

## CI/CD

Pushes to the `latest` branch build and publish multi-arch images to both Docker Hub and GHCR, followed by smoke tests against the published image.
