#!/bin/bash

curl -L https://github.com/docker/sbx-releases/releases/download/v0.31.1/DockerSandboxes-linux-amd64-ubuntu2604.deb -o DockerSandboxes-linux-amd64-ubuntu2604.deb
sudo apt install ./DockerSandboxes-linux-amd64-ubuntu2604.deb
