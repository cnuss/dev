FROM ubuntu:latest AS base

COPY .apt .apt
RUN .apt/install.sh

FROM base AS asdf
RUN apt-get update && apt-get install -y golang make && rm -rf /var/lib/apt/lists/*
USER dev
WORKDIR /home/dev
COPY --chown=dev:dev .asdf .asdf
RUN .asdf/install.sh

FROM base AS combined
COPY --from=asdf --chown=dev:dev /home/dev/.asdf/installs /home/dev/.asdf/installs
COPY --from=asdf --chown=dev:dev /home/dev/.asdf/plugins /home/dev/.asdf/plugins
COPY --from=asdf --chown=dev:dev /home/dev/.asdf/shims /home/dev/.asdf/shims
COPY --from=asdf /home/dev/go/bin/asdf /usr/local/bin/
COPY --from=asdf --chown=dev:dev /home/dev/.asdf/.tool-versions /home/dev/.tool-versions
COPY --from=registry.k8s.io/kubectl:v1.35.0 /bin/kubectl /usr/local/bin/
COPY --from=registry.k8s.io/etcd:3.6.6-0 /usr/local/bin/etcdctl /usr/local/bin/

FROM scratch AS smoke-test
COPY --from=combined / /
USER dev
WORKDIR /home/dev
ENV PATH="/home/dev/.asdf/shims:${PATH}"

RUN k9s --help
RUN kubectl version --client
RUN etcdctl version
RUN fzf --version
RUN kubectx --help

FROM scratch AS final
# single layer output
COPY --from=combined / /
USER dev
WORKDIR /home/dev
ENV PATH="/home/dev/.asdf/shims:${PATH}"