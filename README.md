# dsh-workbench: DeepSeek Harness on Arch Linux

This repository builds a development container for
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness).
The image uses Arch Linux, installs Node.js, Python, pnpm, and optional
code-server, builds `dsh` from source, and compiles the `node-pty` native module
inside the image using only tools available in the image.

## What is included

- Base image: official Docker `archlinux:latest`
- pacman mirror: Tsinghua TUNA with Aliyun fallback
- npm/pnpm mirror: `https://registry.npmmirror.com`
- node-gyp headers mirror: `https://npmmirror.com/mirrors/node`
- Python package mirror: `https://pypi.tuna.tsinghua.edu.cn/simple`
- Node.js, npm, pnpm 11.7.0, Python, pip
- Minimal C/C++ toolchain (`gcc`, `make`) for `node-pty`
- Rust intentionally not installed: the x86_64 build of `dsh` does not need it,
  and dropping the Rust toolchain keeps the image noticeably smaller
- Full source checkout at `/opt/deepseek-harness`, pinned to commit
  `47f943859bef60e4160492346772ded9b24f765a`
- `node-pty` compiled in-place and verified with a real PTY smoke test
- Optional code-server 4.132.0, served on port `8443`

## Build

> The GitHub download uses `socks5h://host.docker.internal:1080` by default.
> If your local proxy is elsewhere, change `GITHUB_PROXY` in
> `docker-compose.yml` or pass `--build-arg`.

```sh
make build
```

Equivalent plain command:

```sh
docker compose build
```

If Docker Hub is blocked and `archlinux:latest` cannot be pulled, import the
base image from the Tsinghua TUNA mirror first:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/import-archlinux-base.ps1
docker compose build
```

The import script uses Python `zstandard` and WSL to repack the official Arch
bootstrap tarball into a Docker rootfs. Pass `-Force` if you want to replace an
existing local `archlinux:latest`.

To disable code-server:

```sh
docker compose build --build-arg INSTALL_CODE_SERVER=false
```

## Run

```sh
docker compose up -d
```

Then open:

- DeepSeek Harness Web UI: <http://127.0.0.1:3080>
- code-server: <http://127.0.0.1:8443>

The Web UI starts without an API key, but a key is needed when you actually run
an agent against DeepSeek's API.

> First startup can take a few minutes with no obvious log output while `dsh`
> initializes its `web` profile. Wait for `dsh web: http://127.0.0.1:13080`
> in `docker compose logs dsh`, then open port `3080`.

### docker run

Pull the published image and run it directly:

```sh
docker pull ghcr.io/cupen/dsh-workbench:latest
docker run -d --name dsh-workbench --init --restart unless-stopped -p 127.0.0.1:3080:3080 -p 127.0.0.1:8443:8443 -v dsh-workbench-home:/home/dsh -e DEEPSEEK_API_KEY=sk-... ghcr.io/cupen/dsh-workbench:latest
```

The image does not bake in any API key. `DEEPSEEK_API_KEY` is only passed when
you actually run an agent; the Web UI starts without it. If you are not ready
to provide a key yet, just drop the `-e DEEPSEEK_API_KEY=...` line.

On the mainland, pull through the domestic GHCR mirror instead:

```sh
docker pull ghcr.nju.edu.cn/cupen/dsh-workbench:latest
```

Inside a `docker compose` setup, you can set the key the same way at runtime
instead of editing the compose file:

```sh
docker compose run --rm -e DEEPSEEK_API_KEY=sk-... dsh bash
```

### 镜像区域切换（DSH_REGION）

容器启动时会读取 `DSH_REGION` 环境变量，并自动切换 `dsh` 用户的
npm/pnpm/pip/GitHub 代理配置：

- `DSH_REGION=cn`：使用大陆镜像（npmmirror、清华 pip、node-gyp 头文件镜像），
  GitHub 代理默认 `socks5h://host.docker.internal:1080`
- `DSH_REGION=global`（默认）：使用官方 npm/pypi/node 源，不设置 GitHub 代理

```sh
docker run -d --name dsh-workbench --init --restart unless-stopped -p 127.0.0.1:3080:3080 -p 127.0.0.1:8443:8443 -v dsh-workbench-home:/home/dsh -e DSH_REGION=cn -e DEEPSEEK_API_KEY=sk-... ghcr.io/cupen/dsh-workbench:latest
```

如果你的 SOCKS 代理端口不同，额外传 `GITHUB_PROXY` 覆盖：

```sh
-e GITHUB_PROXY=socks5h://host.docker.internal:7890
```

## GitHub Container Registry

Pushes to `main` and `v*` tags trigger
[`.github/workflows/publish-ghcr.yml`](.github/workflows/publish-ghcr.yml),
which publishes the image to:

```sh
ghcr.io/cupen/dsh-workbench:latest
```

The workflow runs without the local SOCKS proxy, so it passes
`GITHUB_PROXY=` explicitly and relies on GitHub runners' direct network access.

## Shell / development

```sh
docker compose exec dsh bash
```

Inside the container:

```sh
node --version
python --version
dsh --help
```

The repository is at `/opt/deepseek-harness`. A host directory `./workspace` is
mounted at `/workspace` for scratch work.

## How node-pty is handled

`node-pty@1.1.0` ships no Linux x64 prebuild. The repository has
`patches/node-pty@1.1.0.patch` and `allowBuilds` entries, so `pnpm install`
runs its source build. The Dockerfile sets the node-gyp header mirror to
npmmirror and installs `gcc`/`make` plus Python, so the native addon is compiled
with the image's own toolchain. The build loads `pty.node` and spawns a
`/bin/sh` PTY to verify it actually works.
