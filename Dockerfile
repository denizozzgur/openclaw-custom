FROM ghcr.io/openclaw/openclaw:latest

# Install CLI tools: gog (Google Workspace) + gh (GitHub)
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
    # --- gog CLI (Google Workspace: Gmail, Calendar, Drive) ---
    && curl -fsSL -o /tmp/gogcli.tar.gz \
    https://github.com/steipete/gogcli/releases/download/v0.11.0/gogcli_0.11.0_linux_amd64.tar.gz \
    && tar -xzf /tmp/gogcli.tar.gz -C /tmp/ \
    && find /tmp -name 'gog' -type f -exec cp {} /usr/local/bin/gog \; \
    && chmod +x /usr/local/bin/gog \
    && ln -sf /usr/local/bin/gog /usr/local/bin/gogcli \
    && rm -rf /tmp/gogcli* /tmp/gog* \
    # --- gh CLI (GitHub: repos, issues, PRs) ---
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    # --- Cleanup ---
    && apt-get clean && rm -rf /var/lib/apt/lists/*
USER node

# Copy entrypoint (already executable via git)
COPY entrypoint-patch.sh /home/node/entrypoint-patch.sh
COPY credit-proxy.mjs /home/node/credit-proxy.mjs
COPY credential-poller.mjs /home/node/credential-poller.mjs
COPY qr-watcher.mjs /home/node/qr-watcher.mjs

ENTRYPOINT ["/home/node/entrypoint-patch.sh"]
