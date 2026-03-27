FROM ubuntu:latest AS base

COPY apt.list .
RUN apt-get update && xargs apt-get install -y < apt.list && rm -rf /var/lib/apt/lists/*

FROM base AS final
