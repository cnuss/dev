# `noded` — node host access from the debug sidecar

`noded` shells from the privileged `debug: true` sidecar onto the underlying flex-node EC2 host.

## Why ssh, and not `nsenter`

On flex nodes the debug container shares the host's **network** namespace but has its own **PID** and **mount** namespaces — `kubelet` and `containerd` run inside a `systemd-nspawn` machine (`kube1`) and pods run under that. So `nsenter --target 1` lands inside `kube1`, not on the EC2 host, and there is no host filesystem to reach. `hostPID: true` gets you kube1's PID namespace for the same reason — the kubelet creating the pod is itself inside kube1.

The shared netns does make the host's sshd reachable at `127.0.0.1:22`, so ssh over the shared netns is the only container → host path. `noded` wraps it:

```bash
noded                 # interactive shell on the host
noded systemctl status kubelet
```

## Sidecar deployment

The image bakes `NODED_PROVISION=1` and `NODED_KEEPALIVE=1`, so a sidecar needs only `command: ["noded"]` plus a read-write `/etc/ssh` hostPath — no `env:` block — to self-provision and land on the node:

```yaml
- name: debug
  image: cnuss/dev:latest
  imagePullPolicy: Always
  command: ["noded"]             # PID1 is the host ssh session
  stdin: true
  tty: true
  volumeMounts:
    - name: host-etc-ssh
      mountPath: /etc/ssh          # read-write hostPath
  securityContext:
    privileged: true
    allowPrivilegeEscalation: true
    runAsUser: 0
    readOnlyRootFilesystem: false
    capabilities:
      add: ["ALL"]
    seccompProfile:
      type: Unconfined
volumes:
  - name: host-etc-ssh
    hostPath:
      path: /etc/ssh
      type: Directory
```

In k9s: select the pod, press **`a`** → `ubuntu@node`.

There is no ENTRYPOINT to override — `docker inspect` shows `Entrypoint=null`. The `zsh -c` in the Dockerfile is the `SHELL` directive, which only affects `RUN` steps at build time; it never wraps the container process, so `command` replaces PID1 directly.

### `s` vs `a`

With PID1 = `noded`:

- **`a` (attach)** → attaches to PID1 → **on the node** (`ubuntu@node`)
- **`s` (shell)** → `kubectl exec`, a new process → **container toolbox** (`nsenter`, `tcpdump`, …)

This is the opposite of the muscle-memory "`s` = shell into this thing" — worth a note in the runbook. There is no image-side way to make `s` land on the host: k9s picks what `s` execs (`bash`/`sh` by name), and the image can't redirect that. To get `s`-to-node too, use a k9s plugin on the operator side.

## Credential modes

First configured one wins: supplied cert → step-ca → bare key → **self-provision (default)**. Self-provision is last on purpose so the baked default never shadows an explicitly configured CA or key.

### Self-provision — the default (`NODED_PROVISION=1` + hostPath `/etc/ssh`)

`noded` mints a throwaway user CA in the pod, writes the **public** half plus a `TrustedUserCAKeys` drop-in into the node's `/etc/ssh/sshd_config.d/`, then self-signs a short-lived client certificate. No step-ca, no Secret, no cloud-init. This is the deployment shown above.

It activates with **no sshd reload** only because Ubuntu serves ssh through `ssh.socket` — a fresh `sshd` per connection re-reads `sshd_config.d/*`, so the new trust is live on the next connection. The container can't signal the host sshd to reload (it's in the `kube1` PID namespace), so **socket activation is load-bearing** — confirm your flex nodes still use `ssh.socket` (Ubuntu 24.04+ default). A long-running sshd would not pick up the trust without a reload.

Trade-offs:

- The CA **private** key never leaves the pod's tmpfs and dies with the pod; the published public key is revoked on graceful stop, and a stable filename means a restart replaces the trust rather than accumulating it.
- After an ungraceful `SIGKILL` the drop-in can linger. It is inert — it trusts a CA whose private key is gone — and the next pod overwrites it, but it is litter until then.
- A read-write hostPath mount of the node's `/etc/ssh` lets the container rewrite the host's sshd config and host keys. A genuine node-level privilege, acceptable only for the already-`privileged`, `debug: true` sidecar.

### step-ca (`NODED_CA_URL` + `NODED_CA_PROVISIONER`)

The node trusts a **CA public key** rather than a list of user keys. `noded` has step-ca sign a short-lived certificate; the pod authenticates to the CA with its own Kubernetes service account token, so there is no bootstrap secret to distribute. Setting `NODED_CA_URL` overrides the baked self-provision default — use this if you'd rather not grant the `/etc/ssh` hostPath.

```bash
export NODED_CA_URL=https://ca.internal:9000
export NODED_CA_PROVISIONER=flex-debug
noded
```

Node side, via cloud-init:

```
# /etc/ssh/sshd_config
TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub
HostCertificate   /etc/ssh/ssh_host_ed25519_key-cert.pub
```

Needs `automountServiceAccountToken` on (default) and a step-ca `k8ssa` provisioner. Set `NODED_HOST_CA_FILE` (or `NODED_HOST_CA`) to the **host** CA public key and `noded` verifies the node's identity against it, replacing trust-on-first-use with strict checking — worth doing, since the default target is `127.0.0.1` over a shared netns.

### Bare key (`NODED_KEY_FILE` / `NODED_KEY`)

A dedicated throwaway keypair in a Secret. Setting `NODED_KEY_FILE` overrides the baked default. Never an operator's real key:

```bash
ssh-keygen -t ed25519 -N '' -f nodekey
kubectl create secret generic node-ssh-key --from-file=id_ed25519=nodekey
```

Mount the Secret at `/keys/`, and add `nodekey.pub` to the node's `~ubuntu/.ssh/authorized_keys` via flex-node cloud-init so it survives rebuilds. Secret volumes mount read-only at mode `0444`, which ssh rejects as an unprotected private key and `chmod` can't fix; `noded` copies such a key to a `0600` file for the session and removes it on exit.

## Keepalive

Baked `NODED_KEEPALIVE=1`: on an ssh-level failure (rc 255 — connection refused, auth rejected, host key mismatch) `noded` prints why and holds the container `Running` instead of `CrashLoopBackOff`, staying attachable. A real session that ends exits with its rc so `restartPolicy: Always` recycles the sidecar for a fresh session. Set `NODED_KEEPALIVE=` (empty) to make failures exit instead.

## Environment

Prefix `NODED_`. All optional — the image defaults cover the common case. The `CMD` default is `sleep infinity`, so these only take effect when `noded` runs.

| Variable | Default | Purpose |
|---|---|---|
| `NODED_PROVISION` | `1` (baked) | Self-provision CA trust via a read-write hostPath `/etc/ssh` |
| `NODED_KEEPALIVE` | `1` (baked) | Hold the container up on failure instead of exiting (attach-as-PID1) |
| `NODED_ETC_SSH` | `/etc/ssh` | Mount point for the node's `/etc/ssh` |
| `NODED_CA_URL` | — | step-ca URL; enables step-ca certificate mode |
| `NODED_CA_PROVISIONER` | — | Provisioner that issues user certificates |
| `NODED_CA_ROOT` | `/keys/ca.crt` | CA root certificate |
| `NODED_CA_TOKEN_FILE` | pod SA token | Token used to authenticate to the CA |
| `NODED_CERT_VALIDITY` | `10m` | Certificate lifetime |
| `NODED_HOST_CA_FILE` / `NODED_HOST_CA` | — | Host CA pubkey; strict host verification |
| `NODED_CERT_FILE` | — | Pre-minted certificate to present with the key |
| `NODED_KEY_FILE` | `/keys/id_ed25519` | Private key path |
| `NODED_KEY` | — | Key material inline; takes precedence over the file |
| `NODED_USER` | `ubuntu` | Login user |
| `NODED_HOST` | `127.0.0.1` | Target host |
| `NODED_PORT` | `22` | Target port |
| `NODED_PRINCIPAL` | `$NODED_USER` | Certificate principal |
| `NODED_DRY_RUN` | — | Print the ssh command instead of running it |

## No baked keypair

The image ships no key material and no baked keypair. `cnuss/dev` is public on both registries, so a build-time key would place a private key in a published layer — a fleet-wide credential for anyone who runs `docker pull`. Baking `authorized_keys` into the image would not help either: it grants access *into the container* (which ships no sshd), while the credential that matters lives in the **host's** `authorized_keys`, which no image layer can reach. Self-provision and step-ca sidestep both — the key is minted at runtime and never persisted.
