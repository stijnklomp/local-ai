FROM debian:13-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      libgomp1 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
