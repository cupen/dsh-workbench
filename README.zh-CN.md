# dsh-workbench

基于 Arch Linux 的 DeepSeek Harness 开发容器。

[English](README.md) | [中文](README.zh-CN.md)

本仓库构建 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
的开发容器。镜像使用 Arch Linux，安装 Node.js、Python、pnpm 与可选的
code-server，从源码构建 `dsh`，并在镜像内编译 `node-pty` 原生模块。

## 包含内容

- 基础镜像：Docker 官方 `archlinux:latest`
- pacman 镜像：清华 TUNA，阿里云兜底
- npm/pnpm 镜像：`https://registry.npmmirror.com`
- node-gyp 头文件镜像：`https://npmmirror.com/mirrors/node`
- Python 包镜像：`https://pypi.tuna.tsinghua.edu.cn/simple`
- Node.js、npm、pnpm 11.7.0、Python、pip
- 默认用户 `deepseek`（uid/gid 1000，家目录 `/home/deepseek`），
  已配置免密 `sudo`
- 默认只安装 production 依赖；`DSH_DEV_MODE=true` 时保留 devDependencies，
  供 deepseek-harness 插件开发使用
- 多阶段构建：`node-pty` 在专门的 builder 阶段编译；最终镜像不保留
  C/C++ 编译链与任何包缓存
- 刻意不安装 Rust：`dsh` 的 x86_64 构建不需要它，去掉可显著减小镜像体积
- 源码位于 `/opt/deepseek-harness`，锁定到提交
  `47f943859bef60e4160492346772ded9b24f765a`
- `node-pty` 已在镜像内编译，并通过真实 PTY smoke test
- 可选 code-server 4.132.0，端口 `8443`

## 构建

> GitHub 下载默认使用 `socks5h://host.docker.internal:1080`。
> 如果本地代理不同，请修改 `docker-compose.yml` 中的 `GITHUB_PROXY`，
> 或通过 `--build-arg` 传入。

```sh
make build
```

等价命令：

```sh
docker compose build
```

默认镜像只安装 production 依赖，`dsh` 直接运行预构建的 CLI
（`apps/cli/lib/bin.js`）。如果要在容器内开发 deepseek-harness 插件
（需要保留 TypeScript、tsx 等 devDependencies 以便就地构建和 lint）：

```sh
make build-dev
# 或
docker compose build --build-arg DSH_DEV_MODE=true
```

如果 Docker Hub 被墙、拉不到 `archlinux:latest`，可先从清华 TUNA 导入官方
Arch bootstrap：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/import-archlinux-base.ps1
docker compose build
```

导入脚本使用 Python `zstandard` 和 WSL 把官方 Arch bootstrap 重新打包成
Docker rootfs。要替换已有的本地 `archlinux:latest` 时加 `-Force`。

关闭 code-server：

```sh
docker compose build --build-arg INSTALL_CODE_SERVER=false
```

## 运行

```sh
docker compose up -d
```

然后打开：

- DeepSeek Harness Web UI：<http://127.0.0.1:3080>
- code-server：<http://127.0.0.1:8443>

Web UI 不需要 API key 也能启动；真正跑 agent 时才需要传入 key。

> 首次启动可能需要几分钟且没有明显日志输出，`dsh` 在初始化 `web` profile。
> 等 `docker compose logs dsh` 中出现
> `dsh web: http://127.0.0.1:13080` 后，再访问 `3080` 端口。

### docker run

直接拉取并运行发布镜像：

```sh
docker pull ghcr.io/cupen/dsh-workbench:latest
docker run -d --name dsh-workbench --init --restart unless-stopped -p 127.0.0.1:3080:3080 -p 127.0.0.1:8443:8443 -v dsh-workbench-home:/home/deepseek -e DEEPSEEK_API_KEY=sk-... ghcr.io/cupen/dsh-workbench:latest
```

镜像不内置 API key。`DEEPSEEK_API_KEY` 只在真正跑 agent 时传入；
暂时没有 key 就去掉 `-e DEEPSEEK_API_KEY=...`。

国内网络可改用 GHCR 镜像站拉取：

```sh
docker pull ghcr.nju.edu.cn/cupen/dsh-workbench:latest
```

### DSH_REGION

容器启动时会读取 `DSH_REGION` 环境变量，自动切换 `deepseek` 用户的镜像配置：

- `DSH_REGION=cn`：使用大陆镜像（npmmirror、清华 pip、node-gyp 头文件），
  GitHub 代理默认 `socks5h://host.docker.internal:1080`
- `DSH_REGION=global`（默认）：使用官方 npm/pypi/node 源，不设置 GitHub 代理

```sh
docker run -d --name dsh-workbench --init --restart unless-stopped -p 127.0.0.1:3080:3080 -p 127.0.0.1:8443:8443 -v dsh-workbench-home:/home/deepseek -e DSH_REGION=cn -e DEEPSEEK_API_KEY=sk-... ghcr.io/cupen/dsh-workbench:latest
```

如果 SOCKS 代理端口不同，可以覆盖：

```sh
-e GITHUB_PROXY=socks5h://host.docker.internal:7890
```

## GitHub Container Registry

推送 `main` 或 `v*` tag 会触发
[`.github/workflows/publish-ghcr.yml`](.github/workflows/publish-ghcr.yml)，
发布到：

```sh
ghcr.io/cupen/dsh-workbench:latest
```

工作流不依赖本地 SOCKS 代理，因此显式传入 `GITHUB_PROXY=`，使用 GitHub
Runner 的直接网络访问。

## Shell / 开发

```sh
docker compose exec dsh bash
```

容器内：

```sh
node --version
python --version
dsh --help
```

仓库位于 `/opt/deepseek-harness`。宿主机的 `./workspace` 目录会挂载到容器的
`/workspace`，方便放临时文件。

## node-pty 的处理方式

`node-pty@1.1.0` 没有 Linux x64 prebuild。仓库自带
`patches/node-pty@1.1.0.patch` 和 `allowBuilds` 配置，`pnpm install`
会执行源码编译。Dockerfile 在专门的 builder 阶段编译（node-gyp 头文件镜像
指向 npmmirror，并在该阶段安装 `gcc`/`make`/`pkgconf` 和 Python），随后把
构建好的整个工作区复制进最终镜像。

最终镜像刻意不保留 C/C++ 编译链，以减小体积。如果需要在容器内重新编译
原生模块，先安装工具链：

```sh
sudo pacman -S gcc make pkgconf python
```

构建过程会加载 `pty.node` 并实际 spawn 一个 `/bin/sh` PTY，验证复制后的
插件可用。
