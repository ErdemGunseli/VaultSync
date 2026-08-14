# =============================================================================
# vault-bridge - standalone Obsidian Sync <-> git bridge.
# =============================================================================
# Outbound-only worker: no ports, no inbound HTTP. Runs anywhere with a
# persistent volume mounted at /data.
# =============================================================================
FROM node:22-slim

# git + git-lfs (vault media), ca-certificates (HTTPS to GitHub + Obsidian),
# bash (the scripts are bash, not POSIX sh), tini (PID 1 signal handling so
# SIGTERM actually reaches the bridges on redeploy), inotify-tools (fast local-
# edit detection - the bridge falls back to interval-only polling, with a
# WARNING, if this is ever missing at runtime).
RUN apt-get update \
    && apt-get install -y --no-install-recommends git git-lfs bash ca-certificates tini inotify-tools \
    && git lfs install --skip-repo \
    && rm -rf /var/lib/apt/lists/*

# obsidian-headless is an open beta (0.0.x) whose CLI surface has changed across
# releases; pin it and bump deliberately after re-checking `ob --help`.
ARG OBSIDIAN_HEADLESS_VERSION=0.0.14
RUN npm install -g "obsidian-headless@${OBSIDIAN_HEADLESS_VERSION}" \
    && npm cache clean --force

WORKDIR /app
COPY bridge.sh entrypoint.sh /app/
RUN chmod +x /app/bridge.sh /app/entrypoint.sh

# Sync state and vault clones both live on the mounted disk.
ENV DATA_DIR=/data \
    SECRETS_DIR=/etc/secrets \
    XDG_CONFIG_HOME=/data/ob-state

# -g signals the ENTIRE process group on shutdown, not just entrypoint.sh -
# belt to entrypoint.sh's own trap-forwarding braces: even if a refactor breaks
# that chain, a Render/docker SIGTERM still reaches every bridge, ob and
# inotifywait descendant rather than orphaning them as live second writers.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/entrypoint.sh"]
