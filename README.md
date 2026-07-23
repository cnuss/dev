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

### Node Host Access (`ssh-node`)

On flex nodes the debug container shares the host's **network** namespace but has its own **PID** and **mount** namespaces — `kubelet` and `containerd` run inside a `systemd-nspawn` machine (`kube1`) and pods run under that. So `nsenter --target 1` lands inside `kube1`, not on the EC2 host, and there is no host filesystem to reach.

The shared netns does make the host's sshd reachable at `127.0.0.1:22`. `ssh-node` wraps that path:

```bash
ssh-node                 # interactive shell on the host
ssh-node systemctl status kubelet
```

#### Certificate mode (preferred)

The node trusts a **CA public key** rather than a list of user keys. `ssh-node` generates a keypair inside the pod, has step-ca sign a short-lived certificate for it, and throws both away when the session ends. No key material ships in this image, none is stored, and revocation is a CA concern rather than an `authorized_keys` edit on every node.

The pod authenticates to the CA with its own Kubernetes service account token, so there is no bootstrap secret to distribute.

```bash
export NODE_SSH_CA_URL=https://ca.internal:9000
export NODE_SSH_CA_PROVISIONER=flex-debug
ssh-node
```

| Variable | Default | Purpose |
|---|---|---|
| `NODE_SSH_CA_URL` | — | step-ca URL; setting it enables certificate mode |
| `NODE_SSH_CA_PROVISIONER` | — | Provisioner that issues user certificates |
| `NODE_SSH_CA_ROOT` | `/keys/ca.crt` | CA root certificate |
| `NODE_SSH_CA_TOKEN_FILE` | pod SA token | Token used to authenticate to the CA |
| `NODE_SSH_CERT_VALIDITY` | `10m` | Certificate lifetime |
| `NODE_SSH_PRINCIPAL` | `$NODE_SSH_USER` | Certificate principal |

Node side, via cloud-init:

```
# /etc/ssh/sshd_config
TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub
HostCertificate   /etc/ssh/ssh_host_ed25519_key-cert.pub
```

Set `NODE_SSH_HOST_CA_FILE` (or `NODE_SSH_HOST_CA`) to the **host** CA public key and `ssh-node` verifies the node's identity against it, replacing trust-on-first-use with strict checking — worth doing, since the default target is `127.0.0.1` over a shared netns.

#### Key mode (fallback)

| Variable | Default | Purpose |
|---|---|---|
| `NODE_SSH_KEY_FILE` | `/keys/id_ed25519` | Private key path |
| `NODE_SSH_KEY` | — | Key material inline; takes precedence over the file |
| `NODE_SSH_CERT_FILE` | — | Pre-minted certificate to present with the key |
| `NODE_SSH_USER` | `ubuntu` | Login user |
| `NODE_SSH_HOST` | `127.0.0.1` | Target host |
| `NODE_SSH_PORT` | `22` | Target port |
| `NODE_SSH_DRY_RUN` | — | Print the ssh command instead of running it |

Use a dedicated throwaway keypair, never an operator's real key:

```bash
ssh-keygen -t ed25519 -N '' -f nodekey
kubectl create secret generic node-ssh-key --from-file=id_ed25519=nodekey
```

Mount the Secret at `/keys/`, and add `nodekey.pub` to the node's `~ubuntu/.ssh/authorized_keys` via flex-node cloud-init so it survives rebuilds. Appending it live works for a quick test but is lost on the next rebuild.

Secret volumes mount read-only at mode `0444`, which ssh rejects as an unprotected private key, and `chmod` can't fix a read-only mount. `ssh-node` copies such a key to a `0600` file for the session and removes it on exit.

`ssh-node` also works as a container command, so `command: ["ssh-node"]` plus `kubectl attach` (or `a` in k9s) drops straight onto the host.

> **The image ships no key material and no baked keypair.** Generating one at build time would place a private key in a published layer — this image is public on both registries — and pre-authorizing it on nodes would make that key a fleet-wide credential for anyone who runs `docker pull`. Baking `authorized_keys` into the image would not help either: it grants access *into the container*, while the credential that matters lives in the host's `authorized_keys`, which no image layer can reach.

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

The same workflow runs on a weekly schedule (Mondays 06:00 UTC) to pick up base image and package updates. Scheduled runs execute on the default branch, so they publish exactly like a push, and they build with `no-cache` — a cached rebuild would reinstall the identical packages and defeat the purpose. Expect them to take noticeably longer than a normal push build.

GitHub disables scheduled workflows in repos with no activity for 60 days; re-enable from the Actions tab if that happens.
