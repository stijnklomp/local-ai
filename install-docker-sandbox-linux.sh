#!/bin/bash

mkdir -p ~/sbx-dist && cd ~/sbx-dist

curl -L https://github.com/docker/sbx-releases/releases/download/v0.25.0/DockerSandboxes-linux.tar.gz -o sbx.tar.gz
tar -xzvf sbx.tar.gz

sudo cp ~/sbx-dist/docker-sbx/sbx /usr/local/bin/sbx
sudo chmod +x /usr/local/bin/sbx

sudo mkdir -p /usr/lib/docker/sandboxes
sudo cp ~/sbx-dist/docker-sbx/nerdbox-* /usr/lib/docker/sandboxes/
sudo cp ~/sbx-dist/docker-sbx/libkrun.so /usr/lib/docker/sandboxes/
