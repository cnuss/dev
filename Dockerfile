FROM ubuntu:latest AS base

COPY apt.list .
RUN apt-get update && xargs apt-get install -y < apt.list && \
    apt-get autoremove -y && apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* && \
    usermod -l dev -d /home/dev -m ubuntu && groupmod -n dev ubuntu && \
    echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev && \
    touch /home/dev/.sudo_as_admin_successful

FROM base AS asdf
RUN apt-get update && apt-get install -y golang make && rm -rf /var/lib/apt/lists/*
USER dev
WORKDIR /home/dev
RUN go install github.com/asdf-vm/asdf/cmd/asdf@v0.18.1
ENV PATH="/home/dev/.asdf/shims:/home/dev/go/bin:${PATH}"
COPY .plugin-versions .tool-versions ./
RUN asdf plugin add asdf-plugin-manager https://github.com/asdf-community/asdf-plugin-manager.git
RUN asdf install asdf-plugin-manager 1.5.0
RUN asdf-plugin-manager add-all && asdf install

FROM base AS combined
COPY --from=asdf --chown=dev:dev /home/dev/.asdf/installs /home/dev/.asdf/installs
COPY --from=asdf --chown=dev:dev /home/dev/.asdf/plugins /home/dev/.asdf/plugins
COPY --from=asdf --chown=dev:dev /home/dev/.asdf/shims /home/dev/.asdf/shims
COPY --from=asdf /home/dev/go/bin/asdf /usr/local/bin/
COPY --from=asdf --chown=dev:dev /home/dev/.tool-versions /home/dev/.tool-versions
COPY --from=registry.k8s.io/kubectl:v1.35.0 /bin/kubectl /usr/local/bin/
COPY --from=registry.k8s.io/etcd:3.6.6-0 /usr/local/bin/etcdctl /usr/local/bin/

FROM ubuntu:latest AS smoke-test
COPY --from=combined / /
USER dev
WORKDIR /home/dev
ENV PATH="/home/dev/.asdf/shims:${PATH}"

RUN k9s --help
RUN kubectl version --client
RUN etcdctl version

FROM ubuntu:latest AS final

# single layer output
COPY --from=combined / /
USER dev
WORKDIR /home/dev
ENV PATH="/home/dev/.asdf/shims:${PATH}"