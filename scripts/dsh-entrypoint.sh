#!/bin/sh
set -eu

if [ -x /usr/local/bin/dsh-region ]; then
    . /usr/local/bin/dsh-region
fi

if [ -x /usr/local/bin/code-server ]; then
    mkdir -p /home/deepseek/.local/share/code-server /home/deepseek/.config/code-server
    code-server \
        --auth none \
        --bind-addr 0.0.0.0:8443 \
        --user-data-dir /home/deepseek/.local/share/code-server \
        /opt/deepseek-harness &
fi

# dsh web intentionally binds to 127.0.0.1. Socat exposes the published
# 0.0.0.0:3080 endpoint and forwards it to dsh's private 13080 listener.
socat TCP-LISTEN:3080,bind=0.0.0.0,fork,reuseaddr TCP:127.0.0.1:13080 \
    >/tmp/dsh-socat.log 2>&1 &
socat_pid=$!
trap 'kill "${socat_pid}" 2>/dev/null || true' TERM INT EXIT

exec "$@"
