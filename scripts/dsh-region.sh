#!/bin/sh
# Switch user-level mirror configuration between mainland China and global.
# Source this script from the entrypoint; set DSH_REGION=cn|global at runtime.
set -eu

DSH_REGION="${DSH_REGION:-global}"

case "$DSH_REGION" in
  cn|china|CN|CHINA)
    DSH_REGION=cn
    NPM_REGISTRY="https://registry.npmmirror.com"
    NODE_DIST_URL="https://npmmirror.com/mirrors/node"
    PYPI_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
    GITHUB_PROXY="${GITHUB_PROXY:-socks5h://host.docker.internal:1080}"
    ;;
  *)
    DSH_REGION=global
    NPM_REGISTRY="https://registry.npmjs.org"
    NODE_DIST_URL="https://nodejs.org/download/release"
    PYPI_INDEX="https://pypi.org/simple"
    GITHUB_PROXY="${GITHUB_PROXY:-}"
    ;;
esac

mkdir -p "$HOME/.config/pnpm" "$HOME/.config/pip"

printf 'registry=%s\ndisturl=%s\n' "$NPM_REGISTRY" "$NODE_DIST_URL" > "$HOME/.npmrc"
printf 'registry: %s\n' "$NPM_REGISTRY" > "$HOME/.config/pnpm/config.yaml"
printf '[global]\nindex-url = %s\n' "$PYPI_INDEX" > "$HOME/.config/pip/pip.conf"

git config --global --unset-all http.https://github.com.proxy >/dev/null 2>&1 || true
if [ -n "$GITHUB_PROXY" ]; then
  git config --global http.https://github.com.proxy "$GITHUB_PROXY"
fi

export DSH_REGION
export NPM_CONFIG_REGISTRY="$NPM_REGISTRY"
export NPM_CONFIG_DISTURL="$NODE_DIST_URL"
export PNPM_CONFIG_REGISTRY="$NPM_REGISTRY"
export PIP_INDEX_URL="$PYPI_INDEX"
export GITHUB_PROXY

echo "[dsh-region] mirror mode: ${DSH_REGION}" >&2
