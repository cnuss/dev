# Pinned rather than :latest. The weekly no-cache rebuild would otherwise pull
# major Ubuntu releases unreviewed — 24.04 -> 26.04 already swapped GNU
# coreutils for uutils this way. Bump this deliberately.
ARG BASE_IMAGE=ubuntu:26.04
FROM anchore/syft:latest AS syft

FROM ${BASE_IMAGE} AS homebrew
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    git \
    build-essential \
    sudo \
    && rm -rf /var/lib/apt/lists/* && \
    echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER ubuntu
WORKDIR /home/ubuntu
COPY .homebrew .homebrew
RUN .homebrew/install.sh

COPY Brewfile .

RUN /home/linuxbrew/.linuxbrew/bin/brew bundle --file="./Brewfile" && \
    for bin in /home/linuxbrew/.linuxbrew/bin/*; do [ "$(basename "$bin")" = "brew" ] && continue; sudo cp "$(readlink -f "$bin")" /usr/local/bin/"$(basename "$bin")"; done && \
    ldd /usr/local/bin/* 2>/dev/null | grep -o '/home/linuxbrew[^ ]*\.so[^ ]*' | sort -u | while read lib; do sudo cp "$(readlink -f "$lib")" /usr/local/lib/"$(basename "$lib")"; done && \
    sudo ldconfig
RUN sudo mkdir -p /usr/local/share/zsh/site-functions && \
    sudo cp -rL /home/linuxbrew/.linuxbrew/share/zsh/site-functions/* /usr/local/share/zsh/site-functions/ && \
    sudo rm -f /usr/local/share/zsh/site-functions/_brew

COPY --from=syft /syft /tmp/syft
RUN /tmp/syft scan /home/linuxbrew/.linuxbrew --source-name homebrew --source-version latest --override-default-catalogers homebrew-cataloger -o spdx-json=brew.spdx.json && sudo rm /tmp/syft

FROM ${BASE_IMAGE} AS bins
COPY --from=syft /syft /tmp/syft

COPY .apt .apt
RUN apt-get update && apt-get install -y curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN .apt/install.sh
RUN /tmp/syft scan / --source-name apt --source-version latest --override-default-catalogers dpkg-db-cataloger -o spdx-json=apt.spdx.json

FROM ${BASE_IMAGE} AS claude
COPY --from=syft /syft /tmp/syft

RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
COPY .claude .claude
RUN .claude/install.sh
# DEVNOTE TEMP SKIP SBOM

FROM python:3.11-slim AS sbom
ARG SBOM_NAME=dev
ARG SBOM_AUTHOR=local
ARG SBOM_EMAIL=local@localhost
ARG SBOM_NAMESPACE=https://local
COPY --from=bins apt.spdx.json /sboms/
COPY --from=homebrew /home/ubuntu/brew.spdx.json /sboms/
RUN mkdir /out && pip install --no-cache-dir spdxmerge && \
    spdxmerge --docpath /sboms/ --outpath /out/ --mergetype 1 --name "$SBOM_NAME" --filetype J \
      --author "$SBOM_AUTHOR" --email "$SBOM_EMAIL" --docnamespace "$SBOM_NAMESPACE"

FROM ${BASE_IMAGE} AS combined
COPY --from=bins / /
COPY --from=claude /usr/local/bin/claude /usr/local/bin/claude
COPY --from=claude /root/.claude/ /root/.claude/
COPY --from=homebrew /usr/local/bin/ /usr/local/bin/
COPY --from=homebrew /usr/local/lib/ /usr/local/lib/
COPY --from=homebrew /usr/local/share/ /usr/local/share/
COPY --from=homebrew /home/linuxbrew/.linuxbrew/lib/ld.so /home/linuxbrew/.linuxbrew/lib/ld.so
COPY --from=sbom /out/merged-SBoM-deep.json /usr/local/share/sbom/sbom.spdx.json
COPY .bin/noded /usr/local/bin/noded
RUN chmod 0755 /usr/local/bin/noded

RUN rm -rf /tmp/* && ldconfig

FROM scratch AS smoke-test
# single layer output simulation
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    LD_LIBRARY_PATH="/usr/local/lib"
COPY --from=combined / /
SHELL [ "/bin/zsh", "-c" ]

COPY . .
RUN .apt/smoke.sh
RUN .claude/smoke.sh
RUN .homebrew/smoke.sh
RUN .bin/smoke.sh

FROM scratch AS final
# single layer output
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    LD_LIBRARY_PATH="/usr/local/lib"
# noded defaults for the flex-node debug sidecar: self-provision host trust via a
# hostPath /etc/ssh, and keepalive so `command: ["noded"]` as PID1 doesn't
# CrashLoopBackOff before the node is reachable. Explicit NODED_CA_URL/NODED_KEY
# still win (self-provision is the last-resort credential source), and the CMD
# default is `sleep infinity`, so these only take effect when noded is run.
# Set here rather than in the combined/smoke-test stage so the smoke tests, which
# assert the no-keepalive exit path, keep running with a clean environment.
ENV NODED_PROVISION=1 \
    NODED_KEEPALIVE=1
COPY --from=combined / /
SHELL [ "/bin/zsh", "-c" ]
CMD ["sleep", "infinity"]
