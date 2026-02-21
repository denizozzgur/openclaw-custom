FROM ghcr.io/openclaw/openclaw:latest

# Copy entrypoint (already executable via git)
COPY entrypoint-patch.sh /home/node/entrypoint-patch.sh

ENTRYPOINT ["/home/node/entrypoint-patch.sh"]
