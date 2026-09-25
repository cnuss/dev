# cnuss/dev

A containerized development environment with Kubernetes tools, networking utilities, and the Claude CLI. Multi-arch (`amd64`/`arm64`), built on Ubuntu.

## Quick Start

```bash
# Docker
docker run -it cnuss/dev

# Kubernetes
kubectl run dev --rm -it --image=cnuss/dev

# Ephemeral debug container in an existing pod
kubectl debug -it some-pod --image=cnuss/dev
```

Tools marked † below are [installed on first use](#on-demand-tools). For clusters without outbound access, use `cnuss/dev:full`, which has all of them preinstalled:

```bash
kubectl debug -it some-pod --image=cnuss/dev:full
```

Also available from GitHub Container Registry:

```bash
docker run -it ghcr.io/cnuss/dev
kubectl run dev --rm -it --image=ghcr.io/cnuss/dev
```

## What's Included

### Kubernetes & DevOps

| Tool | Description |
|------|-------------|
| `kubectl` † | Kubernetes CLI |
| `k9s` † | Terminal UI for Kubernetes |
| `kubectx` / `kubens` † | Fast context and namespace switching |
| `etcd` / `etcdctl` / `etcdutl` † | Distributed key-value store |
| `prometheus` / `promtool` † | Metrics & monitoring toolkit |
| `docker` (CLI) † | Docker client (no buildx/compose plugins) |

### Data Processing

| Tool | Description |
|------|-------------|
| `jq` | JSON processor |
| `yq` † | YAML processor |
| `ripgrep` (`rg`) † | Fast text search |
| `fzf` † | Fuzzy finder |

### Crypto / Tokens

| Tool | Description |
|------|-------------|
| `jwt` (jwt-cli) † | Encode / decode / inspect JWTs — amd64 only (no arm64 release upstream; use `step crypto jwt`) |
| `step` † | JWT sign/verify (incl. JWKS), JWK generation, keypairs, x509 / PKI |
| `jose` | JWS / **JWE** / JWK — encrypted tokens, which `jwt` and `step` don't cover |
| `openssl` | Key and certificate primitives |

Verify a Kubernetes service account token against the cluster's JWKS:

```bash
kubectl create token default \
  | step crypto jwt verify --jwks <(kubectl get --raw /openid/v1/jwks) --iss https://kubernetes.default.svc
```

### Networking

`curl`, `wget`, `dig` / `nslookup`, `ping`, `traceroute`, `netcat`, `telnet`, `tftp`, `ip`, `netstat`, `tcpdump`, `mtr`, `ncat`, `socat`, `nmap` †

### Connectivity / Overlay

| Tool | Description |
|------|-------------|
| `cloudflared` † | Cloudflare Tunnel client — reach a cluster-internal service from outside, or reach out through egress-restricted networks |
| `tailscale` / `tailscaled` † | Tailscale CLI and daemon — join the pod to a tailnet, or use it as a subnet router / exit node |

These ship as binaries only — no baked credentials, no daemon started. Both are runtime concerns:

- `tailscaled` needs `/dev/net/tun` plus `NET_ADMIN`, or `--tun=userspace-networking` to run without them. Auth via `TS_AUTHKEY` / `tailscale up --authkey`.
- `cloudflared` needs no special capabilities; supply the tunnel token or credentials file at pod start.

### BGP / Routing

| Tool | Description |
|------|-------------|
| `bgpq4` † | Generate prefix-lists from IRR data, diff against reality |

### Namespaces / Process Debugging

`nsenter`, `unshare`, `lsns`, `mount`, `findmnt` (from `util-linux`)

Entering another container's namespaces needs `hostPID: true` plus `privileged: true` in the pod spec — or at minimum `CAP_SYS_ADMIN` and `CAP_SYS_PTRACE`:

```bash
nsenter --target 1 --mount --uts --ipc --net --pid -- ip addr
```

`util-linux` is `Essential` in the Ubuntu base, but it's pinned in `.apt/packages` and smoke-tested so a slimmer `BASE_IMAGE` can't silently drop it.

### Languages / Runners

| Tool | Description |
|------|-------------|
| `node` / `npm` / `npx` † | Node.js 24 LTS (NodeSource) — `npx` runs packages without installing them |
| `uv` / `uvx` † | Fast Python package manager — `uvx` runs Python tools in throwaway envs |
| `pipx` † | Install / run Python CLI apps in isolated venvs |

### General

`git`, `zsh`, `vim`, `less`, `busybox`, `tar`, `gzip`, `bzip2`, `xz`, `unzip`, `sudo`

### AI

`claude` - Anthropic's Claude CLI

## On-demand tools

Tools marked † aren't in the image. Each of their commands is a small stub instead. The first time you run one, the stub installs the version pinned when the image was built, checks every sha256, and runs the real tool with your arguments. Every later call goes straight to the real tool. There are two kinds:

- **Release**: a single upstream binary or tarball (k9s, kubectl, rg, uv…). The stub is `/usr/local/bin/<tool>`, and the real binary replaces it, plus its zsh completion.
- **Apt**: Ubuntu or third-party `.deb`s (xpra + Xvfb, node, docker CLI, pipx, nmap, bgpq4). The stub sits at the real path, e.g. `/usr/bin/xpra`. At build time the exact set of `.deb`s the package needs beyond what's baked is recorded, each with its URL and sha256. The stub downloads that set, verifies it, and hands it to apt as local files. Packages already installed at the same or a newer version are skipped. Ubuntu `.deb`s fall back to Launchpad's permanent URL once the mirror drops a superseded version. Apt packages need root or passwordless sudo.

```bash
ondemand list                 # what's available, versions, installed or not
ondemand install k9s step     # install ahead of time (by package or binary name)
ondemand install --all        # everything, e.g. in a Dockerfile FROM cnuss/dev
```

Versions are resolved at build time: `latest` from each upstream, or a `tag=` pin in `.ondemand/tools/<pkg>`. The SHA-256 of the artifact is recorded in the image, and the weekly rebuild moves versions forward. The image's SBOM lists every on-demand package with its version and checksum.

- **No outbound network?** Use `:full`, or run `ondemand install --all` in an image of your own.
- **Read-only root filesystem, or no sudo?** A release tool's binary goes to `~/.cache/ondemand/bin` (or `/tmp/ondemand-<uid>/bin` if that isn't writable), and the stub keeps running it from there.

To add a tool, create `.ondemand/tools/<pkg>`. The existing files are the reference.

- **Release**: needs `bins`, a `url()` function, and a `repo=` (GitHub releases) or a `latest()` function to find the version. An optional `checksums()` URL is cross-checked against the hash at build time. `complete_<bin>=` or `complete_url_<bin>()` adds a zsh completion, and `arches="amd64"` limits which arches get it.
- **Apt**: `kind=apt` and `packages="…"`, with the repo in `.apt/sources/` if it isn't Ubuntu's. Stubs are derived from the packages' own `bin`/`sbin` entries, and `stubs=` adds any others.

## Build

```bash
docker build -t cnuss/dev .                    # slim (on-demand stubs)
docker build --target full -t cnuss/dev:full .  # everything preinstalled
```

The Dockerfile uses a multi-stage build:

1. **bins** - Installs system packages from `.apt/packages` (with extra apt repos from `.apt/sources/`), without Recommends
2. **claude** - Downloads the Claude CLI release binary (version from `.claude/version`, sha256-verified against the release manifest) and writes its own SPDX entry
3. **ondemand** - Resolves each release-kind `.ondemand/tools/*` version, downloads and hashes the artifact, writes the stubs and locks
4. **ondemand-apt** - `FROM bins`: records each apt-kind package's `.deb` closure against the baked image, and writes the SPDX document for all on-demand packages
5. **sbom** - Merges the per-stage SPDX documents into a single SBOM
6. **combined** - Merges all stages; ships the SBOM at `/usr/local/share/sbom/sbom.spdx.json`
7. **smoke-test** - Validates all tools work, installing each on-demand tool through its stub from the build cache
8. **full** - `final` with every on-demand tool preinstalled (published as `:full`)
9. **final** - Clean single-layer output image; the default `CMD` is `dev`, which opens zsh when stdin is a tty (`kubectl debug -it`, `docker run -it`) and otherwise idles so the container stays up for `kubectl exec` / `docker exec` instead of exiting

## CI/CD

Pushes to the `latest` branch build and publish multi-arch images to both Docker Hub and GHCR, as `:latest` and `:full`, followed by smoke tests against the published images. The workflow also extracts the image SBOMs, submits them to the GitHub dependency graph, and attests the SBOM and build provenance for both tags on both registries.

The same workflow runs on a weekly schedule (Mondays 06:00 UTC) to pick up base image and package updates. Scheduled runs execute on the default branch, so they publish exactly like a push, and they build with `no-cache` — a cached rebuild would reinstall the identical packages and defeat the purpose. Expect them to take noticeably longer than a normal push build.

GitHub disables scheduled workflows in repos with no activity for 60 days; re-enable from the Actions tab if that happens.
