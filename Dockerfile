# Pinned rather than :latest. The weekly no-cache rebuild would otherwise pull
# major Ubuntu releases unreviewed — 24.04 -> 26.04 already swapped GNU
# coreutils for uutils this way. Bump this deliberately. Held at 24.04 because
# xpra.org only ships complete amd64+arm64 xpra packages for noble.
ARG BASE_IMAGE=ubuntu:24.04
FROM anchore/syft:latest AS syft

FROM ${BASE_IMAGE} AS bins
COPY --from=syft /syft /tmp/syft

COPY .apt .apt
RUN apt-get update && apt-get install -y curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN .apt/install.sh
COPY .bin/dev /usr/local/bin/dev
RUN /tmp/syft scan / --source-name apt --source-version latest --override-default-catalogers dpkg-db-cataloger -o spdx-json=apt.spdx.json

FROM ${BASE_IMAGE} AS claude
RUN apt-get update && apt-get install -y curl ca-certificates jq && rm -rf /var/lib/apt/lists/*
COPY .claude .claude
RUN .claude/install.sh
RUN .claude/sbom.sh > claude.spdx.json

# On-demand tools: resolve versions and hash the artifacts now, ship only the
# stubs + locks (see .ondemand/). /out/cache feeds the smoke test and :full.
FROM ${BASE_IMAGE} AS ondemand
RUN apt-get update && apt-get install -y curl ca-certificates jq && rm -rf /var/lib/apt/lists/*
COPY .ondemand .ondemand
RUN .ondemand/lock.sh /out

# Apt-kind on-demand packages: resolved FROM bins, so each package's .deb
# closure is exactly what it would add to the shipped image. The release
# locks are merged in here so one SBOM covers both kinds.
FROM bins AS ondemand-apt
COPY .ondemand .ondemand
COPY --from=ondemand /out/share/ /out/share/
RUN .ondemand/lock-apt.sh /out
RUN .ondemand/sbom.sh /out/share > ondemand.spdx.json

FROM python:3.11-slim AS sbom
ARG SBOM_NAME=dev
ARG SBOM_AUTHOR=local
ARG SBOM_EMAIL=local@localhost
ARG SBOM_NAMESPACE=https://local
COPY --from=bins apt.spdx.json /sboms/
COPY --from=claude claude.spdx.json /sboms/
COPY --from=ondemand-apt ondemand.spdx.json /sboms/
RUN mkdir /out && pip install --no-cache-dir spdxmerge && \
    spdxmerge --docpath /sboms/ --outpath /out/ --mergetype 1 --name "$SBOM_NAME" --filetype J \
      --author "$SBOM_AUTHOR" --email "$SBOM_EMAIL" --docnamespace "$SBOM_NAMESPACE"

FROM ${BASE_IMAGE} AS combined
COPY --from=bins / /
COPY --from=claude /usr/local/bin/claude /usr/local/bin/claude
COPY --from=ondemand-apt /out/share/ /usr/local/share/ondemand/
COPY --from=ondemand /out/bin/ /usr/local/bin/
COPY .ondemand/ondemand /usr/local/bin/ondemand
RUN mkdir -p /usr/local/share/zsh/site-functions
RUN --mount=type=bind,source=.ondemand/stubs.sh,target=/tmp/stubs.sh /tmp/stubs.sh
COPY --from=sbom /out/merged-SBoM-deep.json /usr/local/share/sbom/sbom.spdx.json

RUN rm -rf /tmp/* && ldconfig

FROM scratch AS smoke-test
# single layer output simulation
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    LD_LIBRARY_PATH="/usr/local/lib" \
    PIPX_DEFAULT_PYTHON=/usr/bin/python3
COPY --from=combined / /

COPY . .
RUN .apt/smoke.sh
RUN .claude/smoke.sh
RUN .ondemand/smoke.sh
# First run of each tool goes through its stub, installing from the build
# caches — the whole download/verify/install/exec path, no second download.
RUN --mount=type=bind,from=ondemand,source=/out/cache,target=/var/cache/ondemand/release \
    --mount=type=bind,from=ondemand-apt,source=/out/cache,target=/var/cache/ondemand/apt \
    .ondemand/smoke-tools.sh
RUN .bin/smoke.sh

# `:full` — every on-demand tool installed, for clusters without egress.
# Kept before `final` so a plain `docker build .` still produces the slim
# image. Keep ENV/CMD in step with `final`.
FROM scratch AS full
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    LD_LIBRARY_PATH="/usr/local/lib" \
    PIPX_DEFAULT_PYTHON=/usr/bin/python3
COPY --from=combined / /
RUN --mount=type=bind,from=ondemand,source=/out/cache,target=/var/cache/ondemand/release \
    --mount=type=bind,from=ondemand-apt,source=/out/cache,target=/var/cache/ondemand/apt \
    ondemand install --all
CMD ["dev"]

FROM scratch AS final
# single layer output
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    LD_LIBRARY_PATH="/usr/local/lib" \
    PIPX_DEFAULT_PYTHON=/usr/bin/python3
COPY --from=combined / /
# `dev` opens zsh when stdin is a tty (kubectl debug -it, docker run -it) and
# idles otherwise, so a headless pod stays up for exec.
CMD ["dev"]
