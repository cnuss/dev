#!/usr/bin/env bash
set -e

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# `dev` is the image CMD. Headless (no tty on stdin, e.g. a sidecar or
# `kubectl run` without -t) it must idle so the container stays up for exec;
# timeout kills the held process and returns 124.
command -v dev
bash -n "$(command -v dev)"
set +e
timeout 2 dev </dev/null >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 124 ] || { echo "dev: headless did not idle (rc=$rc)" >&2; exit 1; }

# With a tty on stdin (`kubectl debug -it`, `docker run -it`) it must drop into
# zsh instead. `script` allocates a pty; the piped command runs in that shell.
echo 'echo shell=$ZSH_VERSION' | script -qec dev /dev/null > "$work/tty.out"
grep -q 'shell=[0-9]' "$work/tty.out"
