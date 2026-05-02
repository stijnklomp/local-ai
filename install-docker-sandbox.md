# Install Docker Sandbox on Debian (02-05-2026)

1. Create a dedicated folder and move into it

```sh
mkdir -p ~/sbx-dist && cd ~/sbx-dist
```

2. Download the clean Linux archive again

```sh
curl -L https://github.com/docker/sbx-releases/releases/download/v0.25.0/DockerSandboxes-linux.tar.gz -o sbx.tar.gz
```

3. Extract it carefully

```sh
tar -xzvf sbx.tar.gz
```

4. Check the directory name (it likely created 'docker-sbx' or just files)

```sh
ls -F
```

5. Move the main binary to your path

```sh
sudo cp ~/sbx-dist/docker-sbx/sbx /usr/local/bin/sbx
sudo chmod +x /usr/local/bin/sbx
```

6. Move the micro-VM helper files to where sbx expects them

```sh
sudo mkdir -p /usr/lib/docker/sandboxes
sudo cp ~/sbx-dist/docker-sbx/nerdbox-* /usr/lib/docker/sandboxes/
sudo cp ~/sbx-dist/docker-sbx/libkrun.so /usr/lib/docker/sandboxes/
```
