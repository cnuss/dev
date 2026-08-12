# Pinned rather than :latest — the addon uses the mitmproxy addon API, which
# moves between majors. Bump deliberately.
ARG MITMPROXY_IMAGE=mitmproxy/mitmproxy:12.2.3
FROM ${MITMPROXY_IMAGE}

# The base is python:slim, which ships no iptables. Needed to program the
# transparent-capture redirect at startup.
RUN apt-get update \
    && apt-get install -y --no-install-recommends iptables \
    && rm -rf /var/lib/apt/lists/*

COPY sandbox_proxy.py /opt/sandbox/sandbox_proxy.py
COPY healthcheck.py /opt/sandbox/healthcheck.py
COPY entrypoint.sh /opt/sandbox/entrypoint.sh
RUN chmod 0755 /opt/sandbox/entrypoint.sh

ENV SANDBOX_LISTEN_PORT=8080 \
    SANDBOX_STATUS_PORT=8081 \
    SANDBOX_TRANSPARENT_PORT=8082 \
    SANDBOX_DNS_PORT=53 \
    SANDBOX_ALLOWLIST=/etc/sandbox/allowlist.txt

EXPOSE 8080 8081 8082 53/udp

# Exec-form HEALTHCHECK bypasses ENTRYPOINT, so this runs as root regardless
# of the gosu drop below.
HEALTHCHECK --interval=5s --timeout=3s --start-period=20s --retries=12 \
    CMD ["python3", "/opt/sandbox/healthcheck.py"]

# Our entrypoint programs iptables as root, then chains to the base image's
# docker-entrypoint.sh, which aligns the `mitmproxy` user's uid with the cert
# directory and gosu-drops privileges.
ENTRYPOINT ["/opt/sandbox/entrypoint.sh"]

# Three listeners, one policy:
#   regular@8080      the explicit HTTPS_PROXY endpoint
#   transparent@8082  where the :80/:443 redirect lands — catches clients that
#                     ignore HTTPS_PROXY entirely
#   dns@53            the resolver every lookup is redirected to
# Binding 53 as the non-root mitmproxy user needs
# net.ipv4.ip_unprivileged_port_start=0, set on the service in compose.
#
# confdir=/certs uses the CA the `ca` service minted instead of generating a
# throwaway one on first run. mitmproxy also writes mitmproxy-dhparam.pem
# there, so /certs is chowned to the same uid.
#
# connection_strategy=lazy keeps mitmproxy from dialling upstream before the
# addon has had its chance to reject the request.
#
# dns_name_servers is deliberately unset: mitmproxy then uses the proxy
# container's own resolver, which sits on the egress network and works.
CMD ["mitmdump", \
     "--mode", "regular@8080", \
     "--mode", "transparent@8082", \
     "--mode", "dns@53", \
     "--listen-host", "0.0.0.0", \
     "--set", "confdir=/certs", \
     "--set", "connection_strategy=lazy", \
     "--set", "block_global=false", \
     "--set", "flow_detail=0", \
     "--set", "termlog_verbosity=info", \
     "-s", "/opt/sandbox/sandbox_proxy.py"]
