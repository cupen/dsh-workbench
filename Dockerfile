# syntax=docker/dockerfile:1

FROM archlinux:latest

ARG GITHUB_PROXY=socks5h://host.docker.internal:1080
ARG INSTALL_CODE_SERVER=true
ARG DSH_COMMIT=47f943859bef60e4160492346772ded9b24f765a
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG NODE_DIST_MIRROR=https://npmmirror.com/mirrors/node

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CI=true \
    PYTHON=/usr/bin/python3 \
    npm_config_registry=${NPM_REGISTRY} \
    NPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    npm_config_disturl=${NODE_DIST_MIRROR} \
    NPM_CONFIG_DISTURL=${NODE_DIST_MIRROR} \
    pnpm_config_registry=${NPM_REGISTRY} \
    PNPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    PATH=/usr/local/bin:/usr/bin:/bin

# 1. Use Chinese mirrors for pacman before any package operation.
RUN printf '%s\n' \
    'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' \
    'Server = https://mirrors.aliyun.com/archlinux/$repo/os/$arch' \
    > /etc/pacman.d/mirrorlist

# 2. Bootstrap pacman's keyring without signature checks: the imported
#    Arch bootstrap rootfs has no populated keyring.
RUN echo 'SigLevel = Never' >> /etc/pacman.conf \
    && pacman-key --init \
    && pacman-key --populate archlinux \
    && pacman -Sy --noconfirm --disable-sandbox gnupg archlinux-keyring \
    && sed -i 's/^SigLevel = Never$/SigLevel = Required DatabaseOptional/' /etc/pacman.conf

# 3. Development toolchain and required packages.
#    gcc/make are the minimal toolchain node-pty's node-gyp build needs.
RUN pacman -Syu --needed --noconfirm --disable-sandbox \
    bash-completion \
    ca-certificates \
    curl \
    gcc \
    git \
    make \
    nodejs \
    npm \
    pkgconf \
    python \
    python-pip \
    python-setuptools \
    shadow \
    socat \
    sudo \
    vim \
    wget \
    && yes | pacman -Scc

# 4. Python package mirror.
RUN printf '%s\n' \
    '[global]' \
    'index-url = https://pypi.tuna.tsinghua.edu.cn/simple' \
    'trusted-host = pypi.tuna.tsinghua.edu.cn' \
    > /etc/pip.conf

# 5. npm/pnpm package mirror and exact pnpm version declared by the repo.
RUN npm config set --location=global registry "${NPM_REGISTRY}" \
    && npm install --global pnpm@11.7.0

# 6. GitHub proxy (git and code-server download). Empty means direct connection.
RUN if [ -n "${GITHUB_PROXY}" ]; then \
        git config --global http.https://github.com.proxy "${GITHUB_PROXY}"; \
    fi

# 7. Create the runtime development user.
RUN groupadd --gid 1000 dsh \
    && useradd --create-home --uid 1000 --gid dsh --shell /bin/bash dsh

# 8. Clone the repository at a fixed commit.
RUN git clone --depth 1 https://github.com/deepseek-ai/deepseek-harness.git /opt/deepseek-harness \
    && cd /opt/deepseek-harness \
    && git fetch --depth 1 origin "${DSH_COMMIT}" \
    && git checkout --detach FETCH_HEAD

# 9. Install the full workspace and build dsh. CI=true skips git-hook setup only.
#    The repo's pnpm-workspace.yaml already allows node-pty/koffi/esbuild/lefthook builds.
RUN cd /opt/deepseek-harness \
    && pnpm install --frozen-lockfile \
    && pnpm run build

# 10. Verify node-pty was actually compiled inside the image and can spawn a PTY.
RUN node_pty_dir="$(find /opt/deepseek-harness/node_modules/.pnpm \
        -type d -path '*/node-pty' -print -quit)" \
    && test -n "${node_pty_dir}" \
    && test -f "${node_pty_dir}/build/Release/pty.node" \
    && node -e "const pty=require(process.argv[1]); const p=pty.spawn('/bin/sh',[],{name:'xterm-color',cols:80,rows:24,cwd:process.cwd(),env:process.env}); let out=''; p.onData(d=>{out+=d; if(out.includes('dsh-pty-ok')){p.kill(); process.exit(0);}}); p.write('echo dsh-pty-ok\\r'); setTimeout(()=>{console.error('node-pty smoke timeout'); process.exit(1);},5000);" "${node_pty_dir}"

# 11. Optional code-server (VSCode in browser), downloaded from GitHub via the configured proxy.
RUN if [ "${INSTALL_CODE_SERVER}" = "true" ]; then \
        proxy_args=""; \
        if [ -n "${GITHUB_PROXY}" ]; then \
            proxy_args="--proxy ${GITHUB_PROXY}"; \
        fi; \
        curl -fL ${proxy_args} -o /tmp/code-server.tar.gz \
            "https://github.com/coder/code-server/releases/download/v4.132.0/code-server-4.132.0-linux-amd64.tar.gz" \
        && tar -xzf /tmp/code-server.tar.gz -C /opt \
        && mv /opt/code-server-4.132.0-linux-amd64 /opt/code-server \
        && ln -sf /opt/code-server/bin/code-server /usr/local/bin/code-server \
        && rm -f /tmp/code-server.tar.gz; \
    fi

# 12. Global dsh wrapper that runs the built repo via pnpm.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'cd /opt/deepseek-harness' \
    'exec pnpm dsh "$@"' \
    > /usr/local/bin/dsh \
    && chmod 755 /usr/local/bin/dsh

COPY scripts/dsh-entrypoint.sh /usr/local/bin/dsh-entrypoint
COPY scripts/dsh-region.sh /usr/local/bin/dsh-region

RUN chmod 755 /usr/local/bin/dsh-entrypoint /usr/local/bin/dsh-region \
    && chown -R dsh:dsh /home/dsh \
    && find /opt/deepseek-harness -mindepth 1 -maxdepth 1 ! -name node_modules -print0 \
        | xargs -0 -r chown -R dsh:dsh

WORKDIR /opt/deepseek-harness
USER dsh

EXPOSE 3080 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=5 \
    CMD curl -fsS http://127.0.0.1:3080/ >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["dsh", "web", "--port", "13080"]
