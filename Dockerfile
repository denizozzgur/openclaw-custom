FROM ghcr.io/openclaw/openclaw:latest

# Switch to root to install our custom entrypoint
USER root
COPY entrypoint-patch.sh /usr/local/bin/entrypoint-patch.sh
RUN chmod +x /usr/local/bin/entrypoint-patch.sh

# Switch back to the original non-root user
USER node

# Override the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint-patch.sh"]
