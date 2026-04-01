ARG BASE_IMAGE=ubuntu:latest
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

RUN /usr/local/bin/syft scan /home/linuxbrew/.linuxbrew --source-name homebrew --source-version latest --select-catalogers homebrew -o spdx-json=brew.spdx.json

FROM anchore/syft:latest AS syft

FROM ${BASE_IMAGE} AS bins
COPY --from=syft /syft /usr/local/bin/syft

COPY .apt .apt
RUN apt-get update && apt-get install -y curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN .apt/install.sh
RUN syft scan / --source-name apt --source-version latest --exclude **/syft -o spdx-json=apt.spdx.json

FROM ${BASE_IMAGE} AS claude
COPY --from=syft /syft /usr/local/bin/syft

RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
COPY .claude .claude
RUN .claude/install.sh
# DEVNOTE TEMP SKIP SBOM

FROM python:3.11-slim AS sbom
COPY --from=bins apt.spdx.json /sboms/
COPY --from=homebrew /home/ubuntu/brew.spdx.json /sboms/
RUN mkdir /out && pip install --no-cache-dir spdxmerge && \
    spdxmerge --docpath /sboms/ --outpath /out/ --mergetype 1 --name dev --filetype J \
      --author cnuss --email noreply@github.com --docnamespace https://github.com/cnuss/dev

FROM ${BASE_IMAGE} AS combined
COPY --from=bins / /
COPY --from=claude /usr/local/bin/claude /usr/local/bin/claude
COPY --from=claude /root/.claude/ /root/.claude/
COPY --from=homebrew /usr/local/bin/ /usr/local/bin/
COPY --from=homebrew /usr/local/lib/ /usr/local/lib/
COPY --from=homebrew /usr/local/share/ /usr/local/share/
COPY --from=homebrew /home/linuxbrew/.linuxbrew/lib/ld.so /home/linuxbrew/.linuxbrew/lib/ld.so
COPY --from=sbom /out/merged-SBoM-deep.json /usr/local/share/sbom/sbom.spdx.json

RUN ldconfig

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

FROM scratch AS final
# single layer output
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    LD_LIBRARY_PATH="/usr/local/lib"
COPY --from=combined / /
SHELL [ "/bin/zsh", "-c" ]
CMD ["/bin/zsh"]
