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
COPY .homebrew .homebrew
RUN .homebrew/install.sh

COPY Brewfile .
RUN /home/linuxbrew/.linuxbrew/bin/brew bundle --file="./Brewfile" && \
    for bin in /home/linuxbrew/.linuxbrew/bin/*; do [ "$(basename "$bin")" = "brew" ] && continue; sudo cp "$(readlink -f "$bin")" /usr/local/bin/"$(basename "$bin")"; done

FROM ${BASE_IMAGE} AS bins

COPY .apt .apt
RUN apt-get update && apt-get install -y curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN .apt/install.sh

FROM ${BASE_IMAGE} AS combined
COPY --from=bins / /
COPY --from=homebrew /usr/local/bin/ /usr/local/bin/

FROM scratch AS smoke-test
# single layer output simulation
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
COPY --from=combined / /
SHELL [ "/bin/zsh", "-c" ]

COPY . .
RUN .apt/smoke.sh
RUN .homebrew/smoke.sh

FROM scratch AS final
# single layer output
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
COPY --from=combined / /
SHELL [ "/bin/zsh", "-c" ]
CMD ["/bin/zsh"]
