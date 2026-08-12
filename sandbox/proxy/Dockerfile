# Pinned rather than :latest — the addon uses the mitmproxy addon API, which
# moves between majors. Bump deliberately.
ARG MITMPROXY_IMAGE=mitmproxy/mitmproxy:12.2.3
FROM ${MITMPROXY_IMAGE}

COPY sandbox_proxy.py /opt/sandbox/sandbox_proxy.py
COPY healthcheck.py /opt/sandbox/healthcheck.py

ENV SANDBOX_LISTEN_PORT=8080 \
    SANDBOX_STATUS_PORT=8081 \
    SANDBOX_ALLOWLIST=/etc/sandbox/allowlist.txt

EXPOSE 8080 8081

# Exec-form HEALTHCHECK bypasses ENTRYPOINT, so this runs as root regardless
# of the gosu drop below.
HEALTHCHECK --interval=5s --timeout=3s --start-period=20s --retries=12 \
    CMD ["python3", "/opt/sandbox/healthcheck.py"]

# The base image's ENTRYPOINT (docker-entrypoint.sh) is kept deliberately: it
# aligns the `mitmproxy` user's uid with the cert directory and gosu-drops
# privileges, but only when argv[0] is one of the mitmproxy tools.
#
# confdir=/certs uses the CA the `ca` service minted instead of generating a
# throwaway one on first run. mitmproxy also writes mitmproxy-dhparam.pem
# there, so /certs is chowned to the same uid.
#
# connection_strategy=lazy keeps mitmproxy from dialling upstream before the
# addon has had its chance to reject the CONNECT.
CMD ["mitmdump", \
     "--mode", "regular", \
     "--listen-host", "0.0.0.0", \
     "--listen-port", "8080", \
     "--set", "confdir=/certs", \
     "--set", "connection_strategy=lazy", \
     "--set", "block_global=false", \
     "--set", "flow_detail=0", \
     "--set", "termlog_verbosity=info", \
     "-s", "/opt/sandbox/sandbox_proxy.py"]
