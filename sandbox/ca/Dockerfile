ARG ALPINE_IMAGE=alpine:3.24
FROM ${ALPINE_IMAGE}

RUN apk add --no-cache openssl ca-certificates

COPY mkca.sh /usr/local/bin/mkca.sh
RUN chmod 0755 /usr/local/bin/mkca.sh

ENTRYPOINT ["/usr/local/bin/mkca.sh"]
