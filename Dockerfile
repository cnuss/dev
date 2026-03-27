FROM ubuntu:latest AS base

COPY .ubuntu .ubuntu
RUN .ubuntu/install.sh

FROM base AS asdf
RUN apt-get update && apt-get install -y golang make && rm -rf /var/lib/apt/lists/*
WORKDIR /root
COPY .asdf .asdf
RUN .asdf/install.sh

FROM base AS claude
WORKDIR /root
COPY .claude .claude
RUN .claude/install.sh

FROM base AS combined
COPY --from=asdf /root/.asdf/installs /root/.asdf/installs
COPY --from=asdf /root/.asdf/plugins /root/.asdf/plugins
COPY --from=asdf /root/.asdf/shims /root/.asdf/shims
COPY --from=asdf /root/go/bin/asdf /usr/local/bin/
COPY --from=asdf /root/.asdf/.tool-versions /.tool-versions
COPY --from=claude /root/.claude /root/.claude
COPY --from=claude /root/.local/bin/claude /usr/local/bin/
COPY --from=registry.k8s.io/kubectl:v1.35.0 /bin/kubectl /usr/local/bin/
COPY --from=registry.k8s.io/etcd:3.6.6-0 /usr/local/bin/etcdctl /usr/local/bin/

FROM scratch AS smoke-test
COPY --from=combined / /
ENV ASDF_DATA_DIR="/root/.asdf"
ENV PATH="/root/.asdf/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SHELL [ "/bin/zsh", "-c" ]

COPY . .
RUN .ubuntu/smoke.sh
RUN .claude/smoke.sh
RUN .asdf/smoke.sh

FROM scratch AS final
# single layer output
COPY --from=combined / /
ENV ASDF_DATA_DIR="/root/.asdf"
ENV PATH="/root/.asdf/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CMD ["/bin/zsh"]
SHELL [ "/bin/zsh", "-c" ]
