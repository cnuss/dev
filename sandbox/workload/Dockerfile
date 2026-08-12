# Wraps any image in the sandbox's trust setup. Point SANDBOX_IMAGE at
# whatever you want to confine; the only assumptions are a Debian/Ubuntu-style
# update-ca-certificates (skipped with a warning if absent) and a shell.
ARG SANDBOX_IMAGE=cnuss/dev
FROM ${SANDBOX_IMAGE}

COPY entrypoint.sh /usr/local/bin/sandbox-entrypoint
COPY verify.sh /usr/local/bin/sandbox-verify
RUN chmod 0755 /usr/local/bin/sandbox-entrypoint /usr/local/bin/sandbox-verify

ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
CMD ["sleep", "infinity"]
