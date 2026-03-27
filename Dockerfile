FROM ubuntu:latest AS base

COPY apt.list .
RUN apt-get update && xargs apt-get install -y < apt.list && rm -rf /var/lib/apt/lists/*
RUN usermod -l dev -d /home/dev -m ubuntu && groupmod -n dev ubuntu
RUN echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev

FROM base AS final

USER dev
WORKDIR /home/dev
