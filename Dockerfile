FROM ghcr.io/openclaw/openclaw:latest

# Install gogcli for Google Workspace (Gmail, Calendar, Drive)
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL https://github.com/steipete/gogcli/releases/download/v0.11.0/gogcli_0.11.0_linux_amd64.tar.gz \
    | tar -xz -C /usr/local/bin/ \
    && ln -sf /usr/local/bin/gog /usr/local/bin/gogcli \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
USER node

# Copy entrypoint (already executable via git)
COPY entrypoint-patch.sh /home/node/entrypoint-patch.sh
COPY credit-proxy.mjs /home/node/credit-proxy.mjs
COPY credential-poller.mjs /home/node/credential-poller.mjs

ENTRYPOINT ["/home/node/entrypoint-patch.sh"]
