#!/bin/bash

mkdir -p ~/sbx-dist && cd ~/sbx-dist

curl -L https://github.com/docker/sbx-releases/releases/download/v0.31.1/DockerSandboxes-linux.tar.gz -o sbx.tar.gz
tar -xzvf sbx.tar.gz

sudo cp ~/sbx-dist/docker-sbx/sbx /usr/local/bin/sbx
sudo chmod +x /usr/local/bin/sbx

sudo mkdir -p /usr/lib/docker/sandboxes
sudo cp ~/sbx-dist/docker-sbx/nerdbox-* /usr/lib/docker/sandboxes/
sudo cp ~/sbx-dist/docker-sbx/libsailor.so /usr/lib/docker/sandboxes/
sudo cp ~/sbx-dist/docker-sbx/containerd-shim-nerdbox-v1 /usr/lib/docker/sandboxes/
sudo cp ~/sbx-dist/docker-sbx/mkfs.erofs /usr/lib/docker/sandboxes/
