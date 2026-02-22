#!/bin/sh
set -e

echo "[clawoop] === Custom OpenClaw Entrypoint ==="
echo "[clawoop] Platform: ${PLATFORM:-telegram}"

# Step 1: Onboard the correct channel
echo "[clawoop] Step 1: Running openclaw onboard..."
if [ "$PLATFORM" = "slack" ]; then
  node openclaw.mjs onboard --channel=slack --token="$SLACK_BOT_TOKEN" 2>&1 || true
elif [ "$PLATFORM" = "discord" ]; then
  node openclaw.mjs onboard --channel=discord --token="$DISCORD_BOT_TOKEN" 2>&1 || true
else
  node openclaw.mjs onboard --channel=telegram --token="$TELEGRAM_BOT_TOKEN" 2>&1 || true
fi

# Step 2: Set channel config with dmPolicy=open via CLI
echo "[clawoop] Step 2: Setting channel config via CLI..."
if [ "$PLATFORM" = "slack" ]; then
  node openclaw.mjs config set --json channels.slack "{\"enabled\":true,\"dmPolicy\":\"open\",\"botToken\":\"$SLACK_BOT_TOKEN\",\"allowFrom\":[\"*\"]}" 2>&1 || true
elif [ "$PLATFORM" = "discord" ]; then
  node openclaw.mjs config set --json channels.discord "{\"enabled\":true,\"dmPolicy\":\"open\",\"botToken\":\"$DISCORD_BOT_TOKEN\",\"allowFrom\":[\"*\"]}" 2>&1 || true
else
  node openclaw.mjs config set --json channels.telegram "{\"enabled\":true,\"dmPolicy\":\"open\",\"botToken\":\"$TELEGRAM_BOT_TOKEN\",\"allowFrom\":[\"*\"]}" 2>&1 || true
fi

# Step 3: Also set the AI provider config
echo "[clawoop] Step 3: Setting AI provider config..."
if [ -n "$ANTHROPIC_API_KEY" ]; then
  node openclaw.mjs config set ai.provider "${AI_PROVIDER:-anthropic}" 2>&1 || true
  node openclaw.mjs config set ai.model "${AI_MODEL:-claude-opus-4-20250514}" 2>&1 || true
  node openclaw.mjs config set --json ai.credentials "{\"anthropicApiKey\":\"$ANTHROPIC_API_KEY\"}" 2>&1 || true
fi

# Step 4: Configure Google OAuth for gog tool (Calendar, Gmail, Drive)
echo "[clawoop] Step 4: Configuring Google services..."
if [ -n "$GOG_REFRESH_TOKEN" ] && [ -n "$GOOGLE_OAUTH_CLIENT_ID" ]; then
  echo "[clawoop]   Google OAuth token found — setting up gog tool..."

  # Create credentials.json for Google OAuth
  cat > /home/node/google-credentials.json <<CRED_EOF
{
  "installed": {
    "client_id": "$GOOGLE_OAUTH_CLIENT_ID",
    "client_secret": "$GOOGLE_OAUTH_CLIENT_SECRET",
    "redirect_uris": ["urn:ietf:wg:oauth:2.0:oob"],
    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
    "token_uri": "https://oauth2.googleapis.com/token"
  }
}
CRED_EOF

  # Configure gogcli to use file-based keyring (works in containers)
  export GOG_KEYRING_BACKEND="${GOG_KEYRING_BACKEND:-file}"
  export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:-clawoop-default}"

  # Load credentials into gogcli
  if command -v gogcli >/dev/null 2>&1; then
    gogcli load-credentials /home/node/google-credentials.json 2>&1 || true
    # Inject the refresh token directly
    gogcli set-token --refresh-token="$GOG_REFRESH_TOKEN" 2>&1 || true
    echo "[clawoop]   gogcli configured with user's Google token"
  else
    echo "[clawoop]   gogcli not found — setting env vars for gog tool"
  fi

  # Enable Google tools in OpenClaw config
  node openclaw.mjs config set --json tools.gog '{"enabled":true}' 2>&1 || true
  
  # Set the Google credentials path
  export GOOGLE_APPLICATION_CREDENTIALS=/home/node/google-credentials.json

  echo "[clawoop]   Google services configured for: ${GOG_CONNECTED_EMAIL:-unknown}"
else
  echo "[clawoop]   No Google OAuth token — skipping gog tool setup"
fi

# Step 4b: Configure Notion
if [ -n "$NOTION_API_KEY" ]; then
  echo "[clawoop]   Notion token found — enabling notion skill..."
  echo "NOTION_API_KEY=$NOTION_API_KEY" >> /home/node/.openclaw/.env
  echo "[clawoop]   Notion configured"
fi

# Step 4c: Configure GitHub
if [ -n "$GITHUB_TOKEN" ]; then
  echo "[clawoop]   GitHub token found — enabling github skill..."
  echo "GITHUB_TOKEN=$GITHUB_TOKEN" >> /home/node/.openclaw/.env
  echo "[clawoop]   GitHub configured"
fi

# Step 4d: Configure Spotify
if [ -n "$SPOTIFY_CLIENT_ID" ] && [ -n "$SPOTIFY_CLIENT_SECRET" ]; then
  echo "[clawoop]   Spotify credentials found — enabling spotify skill..."
  echo "SPOTIFY_CLIENT_ID=$SPOTIFY_CLIENT_ID" >> /home/node/.openclaw/.env
  echo "SPOTIFY_CLIENT_SECRET=$SPOTIFY_CLIENT_SECRET" >> /home/node/.openclaw/.env
  echo "[clawoop]   Spotify configured"
fi

# Step 4e: Configure Trello
if [ -n "$TRELLO_API_KEY" ] && [ -n "$TRELLO_TOKEN" ]; then
  echo "[clawoop]   Trello credentials found — enabling trello skill..."
  echo "TRELLO_API_KEY=$TRELLO_API_KEY" >> /home/node/.openclaw/.env
  echo "TRELLO_TOKEN=$TRELLO_TOKEN" >> /home/node/.openclaw/.env
  echo "[clawoop]   Trello configured"
fi

# Step 4f: Configure Twitter/X
if [ -n "$X_API_KEY" ] && [ -n "$X_ACCESS_TOKEN" ]; then
  echo "[clawoop]   Twitter/X credentials found — enabling x-api skill..."
  mkdir -p /home/node/.openclaw/secrets
  cat > /home/node/.openclaw/secrets/x-api.json <<X_EOF
{
  "api_key": "$X_API_KEY",
  "api_secret": "$X_API_SECRET",
  "access_token": "$X_ACCESS_TOKEN",
  "access_secret": "$X_ACCESS_SECRET"
}
X_EOF
  echo "[clawoop]   Twitter/X configured"
fi

# Step 4g: Configure Home Assistant
if [ -n "$HA_URL" ] && [ -n "$HA_TOKEN" ]; then
  echo "[clawoop]   Home Assistant credentials found — enabling HA skill..."
  echo "HA_URL=$HA_URL" >> /home/node/.openclaw/.env
  echo "HA_TOKEN=$HA_TOKEN" >> /home/node/.openclaw/.env
  echo "[clawoop]   Home Assistant configured"
fi

# Step 5: Enable service-specific tools
echo "[clawoop] Step 5: Enabling service tools..."

if [ -n "$NOTION_API_KEY" ]; then
  echo "[clawoop]   Enabling Notion tool..."
  node openclaw.mjs config set --json tools.notion '{"enabled":true}' 2>&1 || true
fi

if [ -n "$GITHUB_TOKEN" ]; then
  echo "[clawoop]   Enabling GitHub tool..."
  node openclaw.mjs config set --json tools.github '{"enabled":true}' 2>&1 || true
fi

if [ -n "$TRELLO_API_KEY" ]; then
  echo "[clawoop]   Enabling Trello tool..."
  node openclaw.mjs config set --json tools.trello '{"enabled":true}' 2>&1 || true
fi

# Step 5b: Run openclaw doctor --fix BEFORE prompt injection (so it doesn't reset our config)
echo "[clawoop] Step 5b: Running doctor --fix..."
node openclaw.mjs doctor --fix 2>&1 || true

# Step 6: Build and inject JIT system prompt
echo "[clawoop] Step 6: Configuring JIT system prompt..."

# Debug: log which env vars are present
echo "[clawoop]   ENV CHECK: GOG_REFRESH_TOKEN=${GOG_REFRESH_TOKEN:+SET} NOTION_API_KEY=${NOTION_API_KEY:+SET} GITHUB_TOKEN=${GITHUB_TOKEN:+SET}"

# Build list of connected services with capabilities
CONNECTED_BLOCK=""
[ -n "$GOG_REFRESH_TOKEN" ] && CONNECTED_BLOCK="${CONNECTED_BLOCK}
- **Google Workspace**: Calendar (list/create/update events), Gmail (read/send emails), Drive (list/search files). Use the gog tool."
[ -n "$NOTION_API_KEY" ] && CONNECTED_BLOCK="${CONNECTED_BLOCK}
- **Notion**: Create pages, query databases, search workspace. Use the notion tool."
[ -n "$GITHUB_TOKEN" ] && CONNECTED_BLOCK="${CONNECTED_BLOCK}
- **GitHub**: List repos, create/list issues, manage PRs. Use the github tool."
[ -n "$SPOTIFY_CLIENT_ID" ] && CONNECTED_BLOCK="${CONNECTED_BLOCK}
- **Spotify**: Control playback, search music, manage playlists. Use curl/fetch with the Spotify Web API and the stored credentials."
[ -n "$TRELLO_API_KEY" ] && CONNECTED_BLOCK="${CONNECTED_BLOCK}
- **Trello**: List boards, create/move cards, manage lists. Use the trello tool."
[ -n "$X_API_KEY" ] && CONNECTED_BLOCK="${CONNECTED_BLOCK}
- **Twitter/X**: Post tweets, search, manage timeline. Use curl with the X API v2 and the stored credentials."
[ -n "$HA_URL" ] && CONNECTED_BLOCK="${CONNECTED_BLOCK}
- **Home Assistant**: Control lights, switches, climate, and other smart home devices. Use curl with the HA REST API at ${HA_URL}."

# Build list of unconnected services
UNCONNECTED_BLOCK=""
[ -z "$GOG_REFRESH_TOKEN" ] && UNCONNECTED_BLOCK="${UNCONNECTED_BLOCK}
- Google Workspace → https://clawoop.com?connect=google"
[ -z "$NOTION_API_KEY" ] && UNCONNECTED_BLOCK="${UNCONNECTED_BLOCK}
- Notion → https://clawoop.com?connect=notion"
[ -z "$GITHUB_TOKEN" ] && UNCONNECTED_BLOCK="${UNCONNECTED_BLOCK}
- GitHub → https://clawoop.com?connect=github"
[ -z "$SPOTIFY_CLIENT_ID" ] && UNCONNECTED_BLOCK="${UNCONNECTED_BLOCK}
- Spotify → https://clawoop.com?connect=spotify"
[ -z "$TRELLO_API_KEY" ] && UNCONNECTED_BLOCK="${UNCONNECTED_BLOCK}
- Trello → https://clawoop.com?connect=trello"
[ -z "$X_API_KEY" ] && UNCONNECTED_BLOCK="${UNCONNECTED_BLOCK}
- Twitter/X → https://clawoop.com?connect=twitter"
[ -z "$HA_URL" ] && UNCONNECTED_BLOCK="${UNCONNECTED_BLOCK}
- Home Assistant → https://clawoop.com?connect=homeassistant"

# Write system prompt to a temp file to avoid escaping issues
cat > /tmp/clawoop-system-prompt.txt << 'PROMPT_DELIM'
You are a helpful AI assistant managed by Clawoop. You can chat naturally and also perform real actions through connected services.
PROMPT_DELIM

# Append the dynamic parts
cat >> /tmp/clawoop-system-prompt.txt << PROMPT_DYNAMIC

## Connected Services (ready to use)
${CONNECTED_BLOCK:-No services connected yet.}

## Services Not Yet Connected
If the user asks for something that needs one of these, tell them which service is needed and share the connection link:
${UNCONNECTED_BLOCK:-All services are connected!}

## Rules
- For connected services, take action directly when asked. Don't ask for confirmation unless the action is destructive.
- For unconnected services, explain what's needed and share the exact connection link.
- Never fabricate data. If a tool call fails, tell the user honestly.
- Be concise and helpful.
- If an AI request fails with a credit_exceeded or rate_limit error, tell the user: 'Aylık AI krediniz doldu. Bir sonraki faturalama döneminde yenilenecektir.' Do not retry.
PROMPT_DYNAMIC

SYSTEM_PROMPT=$(cat /tmp/clawoop-system-prompt.txt)

# Inject into OpenClaw config
echo "[clawoop]   Injecting system prompt (${#SYSTEM_PROMPT} chars)..."
node openclaw.mjs config set ai.systemPrompt "$SYSTEM_PROMPT" 2>&1
PROMPT_RESULT=$?
echo "[clawoop]   System prompt injection exit code: $PROMPT_RESULT"

# Step 6b: Remove BOOTSTRAP.md so our system prompt takes full control
echo "[clawoop] Step 6b: Removing BOOTSTRAP.md..."
rm -f /home/node/.openclaw/BOOTSTRAP.md 2>/dev/null || true
rm -f /home/node/BOOTSTRAP.md 2>/dev/null || true
find /home/node -name "BOOTSTRAP.md" -delete 2>/dev/null || true
echo "[clawoop]   BOOTSTRAP.md removed ✓"

# Verify: dump what config looks like now
echo "[clawoop]   Verifying config..."
node openclaw.mjs config get ai.systemPrompt 2>&1 | head -5 || true

# Step 8: Start credit proxy (if Supabase creds available)
echo "[clawoop] Step 8: Starting credit proxy..."
if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && [ -n "$USER_ID" ]; then
  node /home/node/credit-proxy.mjs &
  PROXY_PID=$!
  sleep 1
  echo "[clawoop]   Credit proxy started (PID: $PROXY_PID)"

  # Override AI provider base URL to route through proxy
  export ANTHROPIC_BASE_URL="http://127.0.0.1:4100"
  export OPENAI_BASE_URL="http://127.0.0.1:4100"
  echo "[clawoop]   AI requests routed through credit proxy"
else
  echo "[clawoop]   Supabase creds missing — credit proxy skipped (no cap enforced)"
fi

# Step 9: Start credential poller (hot-reload integrations without restart)
echo "[clawoop] Step 9: Starting credential poller..."
if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && [ -n "$USER_ID" ]; then
  node /home/node/credential-poller.mjs &
  POLLER_PID=$!
  echo "[clawoop]   Credential poller started (PID: $POLLER_PID)"
else
  echo "[clawoop]   Missing Supabase creds — credential poller skipped"
fi

# Step 10: Start the gateway
echo "[clawoop] Step 10: Starting gateway..."
node openclaw.mjs gateway --allow-unconfigured &
GATEWAY_PID=$!

# Step 11: Health check — wait for gateway, then mark as running
if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && [ -n "$INSTANCE_ID" ]; then
  (
    echo "[clawoop] Step 11: Waiting for gateway to become healthy..."
    for i in $(seq 1 60); do
      sleep 5
      # Check if gateway process is still alive
      if ! kill -0 $GATEWAY_PID 2>/dev/null; then
        echo "[clawoop]   Gateway process died — skipping health callback"
        break
      fi
      # Try to reach the gateway health endpoint (openclaw listens on 3000 by default)
      if curl -sf http://127.0.0.1:3000/health > /dev/null 2>&1 || curl -sf http://127.0.0.1:3000/ > /dev/null 2>&1; then
        echo "[clawoop]   Gateway is healthy — updating status to running"
        curl -sf -X PATCH "${SUPABASE_URL}/rest/v1/deployments?instance_id=eq.${INSTANCE_ID}" \
          -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
          -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
          -H "Content-Type: application/json" \
          -d '{"status": "running"}' > /dev/null 2>&1
        echo "[clawoop]   Status updated to running ✓"
        break
      fi
      echo "[clawoop]   Attempt $i/60 — gateway not ready yet..."
    done
  ) &
fi

# Wait for gateway to exit
wait $GATEWAY_PID
