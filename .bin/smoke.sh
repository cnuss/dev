#!/usr/bin/env bash
set -e

ssh -V
step --version >/dev/null

command -v ssh-node
bash -n "$(command -v ssh-node)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# No credentials at all: fail with guidance rather than hanging on a connection
# or dying on an unbound variable.
if NODE_SSH_KEY_FILE=/nonexistent/key ssh-node true 2>"$work/err"; then
    echo "ssh-node: expected failure with no credentials, got success" >&2
    exit 1
fi
grep -q "no credentials available" "$work/err"

# Certificate mode without a provisioner must say so rather than shelling out.
if NODE_SSH_CA_URL=https://ca.invalid ssh-node true 2>"$work/err"; then
    echo "ssh-node: expected failure with no provisioner, got success" >&2
    exit 1
fi
grep -q "NODE_SSH_CA_PROVISIONER is not" "$work/err"

# A world-readable key, as a Secret volume presents it, gets staged to a 0600
# copy rather than being rejected by ssh.
ssh-keygen -q -t ed25519 -N '' -f "$work/id" -C smoke
chmod 444 "$work/id"
NODE_SSH_KEY_FILE="$work/id" NODE_SSH_DRY_RUN=1 ssh-node > "$work/argv"
grep -q -- "-i /tmp/" "$work/argv"
grep -q "StrictHostKeyChecking=accept-new" "$work/argv"
if grep -q "CertificateFile" "$work/argv"; then
    echo "ssh-node: unexpected CertificateFile in key mode" >&2
    exit 1
fi

# Key material passed inline works too.
NODE_SSH_KEY="$(cat "$work/id")" NODE_SSH_DRY_RUN=1 ssh-node >/dev/null

# A supplied certificate is offered to ssh, and a host CA switches host
# verification from trust-on-first-use to strict checking against the CA.
ssh-keygen -q -t ed25519 -N '' -f "$work/ca" -C smoke-ca
ssh-keygen -q -s "$work/ca" -I smoke -n ubuntu -V +10m "$work/id.pub"
NODE_SSH_KEY_FILE="$work/id" \
NODE_SSH_CERT_FILE="$work/id-cert.pub" \
NODE_SSH_HOST_CA_FILE="$work/ca.pub" \
NODE_SSH_DRY_RUN=1 ssh-node uptime > "$work/argv"
grep -q "CertificateFile=" "$work/argv"
grep -q "StrictHostKeyChecking=yes" "$work/argv"
grep -q "UserKnownHostsFile=" "$work/argv"
grep -q "ubuntu@127.0.0.1 uptime" "$work/argv"

# User, host and port overrides reach the ssh invocation.
NODE_SSH_KEY_FILE="$work/id" NODE_SSH_USER=admin NODE_SSH_HOST=10.0.0.5 \
NODE_SSH_PORT=2222 NODE_SSH_DRY_RUN=1 ssh-node > "$work/argv"
grep -q -- "-p 2222" "$work/argv"
grep -q "admin@10.0.0.5" "$work/argv"

# The workdir holding staged key material must not survive the process.
NODE_SSH_KEY_FILE="$work/id" NODE_SSH_DRY_RUN=1 ssh-node > "$work/argv"
staged=$(sed -E 's/.*-i ([^ ]+).*/\1/' "$work/argv")
if [ -e "$staged" ]; then
    echo "ssh-node: staged key $staged survived exit" >&2
    exit 1
fi
