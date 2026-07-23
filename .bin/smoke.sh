#!/usr/bin/env bash
set -e

ssh -V
step --version >/dev/null

command -v noded
bash -n "$(command -v noded)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# No credentials at all: fail with guidance rather than hanging on a connection
# or dying on an unbound variable.
if NODE_SSH_KEY_FILE=/nonexistent/key noded true 2>"$work/err"; then
    echo "noded: expected failure with no credentials, got success" >&2
    exit 1
fi
grep -q "no credentials available" "$work/err"

# Certificate mode without a provisioner must say so rather than shelling out.
if NODE_SSH_CA_URL=https://ca.invalid noded true 2>"$work/err"; then
    echo "noded: expected failure with no provisioner, got success" >&2
    exit 1
fi
grep -q "NODE_SSH_CA_PROVISIONER is not" "$work/err"

# A world-readable key, as a Secret volume presents it, gets staged to a 0600
# copy rather than being rejected by ssh.
ssh-keygen -q -t ed25519 -N '' -f "$work/id" -C smoke
chmod 444 "$work/id"
NODE_SSH_KEY_FILE="$work/id" NODE_SSH_DRY_RUN=1 noded > "$work/argv"
grep -q -- "-i /tmp/" "$work/argv"
grep -q "StrictHostKeyChecking=accept-new" "$work/argv"
if grep -q "CertificateFile" "$work/argv"; then
    echo "noded: unexpected CertificateFile in key mode" >&2
    exit 1
fi

# Key material passed inline works too.
NODE_SSH_KEY="$(cat "$work/id")" NODE_SSH_DRY_RUN=1 noded >/dev/null

# A supplied certificate is offered to ssh, and a host CA switches host
# verification from trust-on-first-use to strict checking against the CA.
ssh-keygen -q -t ed25519 -N '' -f "$work/ca" -C smoke-ca
ssh-keygen -q -s "$work/ca" -I smoke -n ubuntu -V +10m "$work/id.pub"
NODE_SSH_KEY_FILE="$work/id" \
NODE_SSH_CERT_FILE="$work/id-cert.pub" \
NODE_SSH_HOST_CA_FILE="$work/ca.pub" \
NODE_SSH_DRY_RUN=1 noded uptime > "$work/argv"
grep -q "CertificateFile=" "$work/argv"
grep -q "StrictHostKeyChecking=yes" "$work/argv"
grep -q "UserKnownHostsFile=" "$work/argv"
grep -q "ubuntu@127.0.0.1 uptime" "$work/argv"

# User, host and port overrides reach the ssh invocation.
NODE_SSH_KEY_FILE="$work/id" NODE_SSH_USER=admin NODE_SSH_HOST=10.0.0.5 \
NODE_SSH_PORT=2222 NODE_SSH_DRY_RUN=1 noded > "$work/argv"
grep -q -- "-p 2222" "$work/argv"
grep -q "admin@10.0.0.5" "$work/argv"

# The workdir holding staged key material must not survive the process.
NODE_SSH_KEY_FILE="$work/id" NODE_SSH_DRY_RUN=1 noded > "$work/argv"
staged=$(sed -E 's/.*-i ([^ ]+).*/\1/' "$work/argv")
if [ -e "$staged" ]; then
    echo "noded: staged key $staged survived exit" >&2
    exit 1
fi

# As PID1 for attach, NODE_SSH_KEEPALIVE must hold the container up rather than
# exit, on both a connection failure and a misconfiguration. timeout kills the
# held process and returns 124; a clean exit before then is a failure here.
set +e
timeout 3 env NODE_SSH_KEEPALIVE=1 NODE_SSH_KEY_FILE="$work/id" NODE_SSH_PORT=1 \
    noded true >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 124 ] || { echo "noded: keepalive did not hold on connect failure (rc=$rc)" >&2; exit 1; }

set +e
timeout 3 env NODE_SSH_KEEPALIVE=1 NODE_SSH_KEY_FILE=/nonexistent/key \
    noded true >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 124 ] || { echo "noded: keepalive did not hold on missing creds (rc=$rc)" >&2; exit 1; }

# Without keepalive the same connection failure exits fast (ssh rc 255), not held.
set +e
timeout 5 env NODE_SSH_KEY_FILE="$work/id" NODE_SSH_PORT=1 noded true >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 255 ] || { echo "noded: expected rc 255 without keepalive, got $rc" >&2; exit 1; }

# Self-provision mode publishes CA trust into a (fake) hostPath /etc/ssh and
# self-signs a client certificate, then removes the trust on exit. Point it at a
# closed port so it fails at connect, after provisioning has run.
etc="$work/etc-ssh"
mkdir -p "$etc/sshd_config.d"
set +e
NODE_SSH_PROVISION=1 NODE_SSH_ETC_SSH="$etc" NODE_SSH_PORT=1 noded true 2>"$work/prov.err"
rc=$?
set -e
[ "$rc" -eq 255 ] || { echo "noded: provision expected rc 255 at connect, got $rc" >&2; cat "$work/prov.err" >&2; exit 1; }
grep -q "published runtime CA trust" "$work/prov.err"
# Trust must have been minted, then revoked on exit.
[ -f "$etc/flex_debug_user_ca.pub" ] && { echo "noded: CA pubkey not revoked on exit" >&2; exit 1; }
[ -f "$etc/sshd_config.d/50-flex-debug.conf" ] && { echo "noded: trust conf not revoked on exit" >&2; exit 1; }

# A mount without sshd_config.d (wrong path, or /etc/ssh not mounted) must fail
# with guidance rather than a confusing ssh error. Root bypasses permission bits
# and a read-only bind mount only refuses at write time, so writability is probed
# with a real write inside the helper rather than asserted here.
set +e
NODE_SSH_PROVISION=1 NODE_SSH_ETC_SSH="$work/no-such-etc" noded true 2>"$work/prov2.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "noded: provision without sshd_config.d should fail" >&2; exit 1; }
grep -q "hostPath-mount" "$work/prov2.err"
