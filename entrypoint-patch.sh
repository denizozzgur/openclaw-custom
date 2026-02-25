#!/bin/sh
set -e

# Helper: update deploy_stage in Supabase (non-blocking, fail-silent)
update_stage() {
  if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && [ -n "$INSTANCE_ID" ]; then
    curl -sf -X PATCH "${SUPABASE_URL}/rest/v1/deployments?id=eq.${INSTANCE_ID}" \
      -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"deploy_stage\": \"$1\"}" > /dev/null 2>&1 || true
  fi
}

echo "[clawoop] === Custom OpenClaw Entrypoint ==="
echo "[clawoop] Platform: ${PLATFORM:-telegram}"

# Step 1: Onboard the correct channel
update_stage "configuring"
echo "[clawoop] Step 1: Running openclaw onboard..."
if [ "$PLATFORM" = "slack" ]; then
  node openclaw.mjs onboard --channel=slack --token="$SLACK_BOT_TOKEN" 2>&1 || true
elif [ "$PLATFORM" = "discord" ]; then
  node openclaw.mjs onboard --channel=discord --token="$DISCORD_BOT_TOKEN" 2>&1 || true
elif [ "$PLATFORM" = "whatsapp" ]; then
  echo "[clawoop]   WhatsApp uses QR pairing — skipping onboard, will login during gateway start"
else
  node openclaw.mjs onboard --channel=telegram --token="$TELEGRAM_BOT_TOKEN" 2>&1 || true
fi

# Step 2: Set channel config with dmPolicy=open via CLI
echo "[clawoop] Step 2: Setting channel config via CLI..."
if [ "$PLATFORM" = "slack" ]; then
  node openclaw.mjs config set --json channels.slack "{\"enabled\":true,\"dmPolicy\":\"open\",\"botToken\":\"$SLACK_BOT_TOKEN\",\"allowFrom\":[\"*\"]}" 2>&1 || true
elif [ "$PLATFORM" = "discord" ]; then
  node openclaw.mjs config set --json channels.discord "{\"enabled\":true,\"dmPolicy\":\"open\",\"botToken\":\"$DISCORD_BOT_TOKEN\",\"allowFrom\":[\"*\"]}" 2>&1 || true
elif [ "$PLATFORM" = "whatsapp" ]; then
  echo "[clawoop]   WhatsApp uses Business API — enabling HTTP chat API for webhook bridge..."
  CONFIG_FILE="/home/node/.openclaw/openclaw.json"
  mkdir -p /home/node/.openclaw
  mkdir -p /home/node/.openclaw/sessions
  mkdir -p /home/node/.openclaw/credentials
  # Generate a gateway token for secure HTTP access (if not already set)
  GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 32)}"
  export OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN"
  # WhatsApp containers don't use a native channel — our webhook bridges messages
  # Enable the HTTP chat completions endpoint so the webhook can forward messages here
  node -e "
    const fs = require('fs');
    const cfgPath = '$CONFIG_FILE';
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch(e) {}
    cfg.gateway = cfg.gateway || {};
    cfg.gateway.http = cfg.gateway.http || {};
    cfg.gateway.http.endpoints = cfg.gateway.http.endpoints || {};
    cfg.gateway.http.endpoints.chatCompletions = { enabled: true };
    cfg.gateway.auth = cfg.gateway.auth || {};
    cfg.gateway.auth.mode = 'token';
    cfg.gateway.auth.token = '$GATEWAY_TOKEN';
    fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
    console.log('[clawoop]   HTTP chat completions API enabled with token auth for WhatsApp bridge');
  " 2>&1 || true
else
  node openclaw.mjs config set --json channels.telegram "{\"enabled\":true,\"dmPolicy\":\"open\",\"botToken\":\"$TELEGRAM_BOT_TOKEN\",\"allowFrom\":[\"*\"]}" 2>&1 || true
fi

# Step 3: Set the AI model via valid OpenClaw config path
echo "[clawoop] Step 3: Setting AI model config..."
echo "[clawoop]   Model: ${AI_MODEL:-anthropic/claude-opus-4-6}"
# Use the correct OpenClaw config key: agents.defaults.model (provider/model format)
node openclaw.mjs config set agents.defaults.model "${AI_MODEL:-anthropic/claude-opus-4-6}" 2>&1 || true
echo "[clawoop]   Model set via agents.defaults.model ✓"
# API keys are read directly from env vars (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)
# No need for ai.credentials — OpenClaw detects keys from environment automatically.

# Step 3b: Ensure agent directory exists (auth handled via env vars)
echo "[clawoop] Step 3b: Ensuring agent directory exists..."
mkdir -p "/home/node/.openclaw/agents/main/agent"
echo "[clawoop]   Agent dir ready ✓ (API keys read from env vars: ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)"

# Step 4: Configure Google OAuth for gog tool (Calendar, Gmail, Drive)
update_stage "connecting"
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

  # Configure gog CLI to use file-based keyring (works in containers)
  export GOG_KEYRING_BACKEND="${GOG_KEYRING_BACKEND:-file}"
  export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:-clawoop-default}"
  export GOG_ACCOUNT="${GOG_CONNECTED_EMAIL}"

  # Load credentials into gog CLI
  if command -v gog >/dev/null 2>&1; then
    # Set keyring backend to file (no system keychain in containers)
    gog auth keyring file 2>&1 || true
    # Store OAuth client credentials
    gog auth credentials /home/node/google-credentials.json 2>&1 || true
    # Import the refresh token directly (no browser needed)
    if [ -n "$GOG_CONNECTED_EMAIL" ]; then
      echo "$GOG_REFRESH_TOKEN" | gog auth tokens import "$GOG_CONNECTED_EMAIL" 2>&1 || true
    fi
    echo "[clawoop]   gog CLI configured with user's Google token"
  else
    echo "[clawoop]   gog not found — setting env vars for gog tool"
  fi

  # Enable Google tools in OpenClaw config
  # gog tool is auto-detected via GOG_REFRESH_TOKEN env var
  
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

# Step 5: Service tools are auto-detected via env vars
echo "[clawoop] Step 5: Service tools configured via env vars..."
# Tools (gog, notion, github, trello) are activated via their env vars,
# not via tools.* config keys. OpenClaw detects them automatically.
echo "[clawoop]   NOTION_API_KEY=${NOTION_API_KEY:+SET} GITHUB_TOKEN=${GITHUB_TOKEN:+SET} TRELLO_API_KEY=${TRELLO_API_KEY:+SET}"
echo "[clawoop]   Tools ready ✓"

# Step 5b: Run openclaw doctor --fix
echo "[clawoop] Step 5b: Running doctor --fix..."
node openclaw.mjs doctor --fix 2>&1 || true

# Step 6: Write OpenClaw workspace files (IDENTITY.md, SOUL.md, TOOLS.md)
# OpenClaw builds its system prompt from these files — NOT from ai.systemPrompt
echo "[clawoop] Step 6: Writing workspace files..."

WORKSPACE="/home/node/.openclaw/workspace"
mkdir -p "$WORKSPACE"

# Debug: log which env vars are present
echo "[clawoop]   ENV CHECK: GOG_REFRESH_TOKEN=${GOG_REFRESH_TOKEN:+SET} NOTION_API_KEY=${NOTION_API_KEY:+SET} GITHUB_TOKEN=${GITHUB_TOKEN:+SET}"

# 6a: IDENTITY.md — defines who the bot is
cat > "$WORKSPACE/IDENTITY.md" << 'EOF'
name: Clawoop Assistant
type: AI assistant
vibe: helpful, practical, proactive
emoji: 🤖
EOF
echo "[clawoop]   IDENTITY.md written ✓"

# 6b: Build connected/unconnected service lists for SOUL.md
CONNECTED_SERVICES=""
UNCONNECTED_SERVICES=""

if [ -n "$GOG_REFRESH_TOKEN" ]; then
  CONNECTED_SERVICES="${CONNECTED_SERVICES}
- **Google Workspace**: Calendar (list/create/update events), Gmail (read/send emails), Drive (list/search files). Use the gog tool."
else
  UNCONNECTED_SERVICES="${UNCONNECTED_SERVICES}
- Google Workspace → https://clawoop.com?connect=google"
fi

if [ -n "$NOTION_API_KEY" ]; then
  CONNECTED_SERVICES="${CONNECTED_SERVICES}
- **Notion**: Create pages, query databases, search workspace. Use the notion tool."
else
  UNCONNECTED_SERVICES="${UNCONNECTED_SERVICES}
- Notion → https://clawoop.com?connect=notion"
fi

if [ -n "$GITHUB_TOKEN" ]; then
  CONNECTED_SERVICES="${CONNECTED_SERVICES}
- **GitHub**: List repos, create/list issues, manage PRs. Use the github tool."
else
  UNCONNECTED_SERVICES="${UNCONNECTED_SERVICES}
- GitHub → https://clawoop.com?connect=github"
fi

if [ -n "$SPOTIFY_CLIENT_ID" ]; then
  CONNECTED_SERVICES="${CONNECTED_SERVICES}
- **Spotify**: Control playback, search music, manage playlists. Use curl with Spotify Web API."
else
  UNCONNECTED_SERVICES="${UNCONNECTED_SERVICES}
- Spotify → https://clawoop.com?connect=spotify"
fi

if [ -n "$TRELLO_API_KEY" ]; then
  CONNECTED_SERVICES="${CONNECTED_SERVICES}
- **Trello**: List boards, create/move cards, manage lists. Use the trello tool."
else
  UNCONNECTED_SERVICES="${UNCONNECTED_SERVICES}
- Trello → https://clawoop.com?connect=trello"
fi

if [ -n "$X_API_KEY" ]; then
  CONNECTED_SERVICES="${CONNECTED_SERVICES}
- **Twitter/X**: Post tweets, search, manage timeline. Use curl with X API v2."
else
  UNCONNECTED_SERVICES="${UNCONNECTED_SERVICES}
- Twitter/X → https://clawoop.com?connect=twitter"
fi

if [ -n "$HA_URL" ]; then
  CONNECTED_SERVICES="${CONNECTED_SERVICES}
- **Home Assistant**: Control smart home devices. Use curl with HA REST API at ${HA_URL}."
else
  UNCONNECTED_SERVICES="${UNCONNECTED_SERVICES}
- Home Assistant → https://clawoop.com?connect=homeassistant"
fi

# 6c: SOUL.md — core personality, rules, and integration awareness
cat > "$WORKSPACE/SOUL.md" << SOUL_EOF
# Soul

You are a helpful AI assistant managed by Clawoop. You can chat naturally and also perform real actions through connected services.

## Connected Services (ready to use)
${CONNECTED_SERVICES:-No services connected yet.}

## Services Not Yet Connected
If the user asks for something that needs one of these, tell them which service is needed and share the connection link:
${UNCONNECTED_SERVICES:-All services are connected!}

## Core Rules
- For connected services, take action directly when asked. Don't ask for confirmation unless the action is destructive.
- For unconnected services, explain what's needed and share the exact connection link.
- Never fabricate data. If a tool call fails, tell the user honestly.
- Be concise and helpful.
- Always respond in English by default. If the user writes in another language, match their language.
- Skip onboarding questions — you are already fully configured and ready to help.
- If an AI request fails with a credit_exceeded or rate_limit error, tell the user: "Your monthly AI credits have been used up. They will be renewed in the next billing cycle." Do not retry.
SOUL_EOF
echo "[clawoop]   SOUL.md written ✓"

# 6d: USER.md — basic user context
cat > "$WORKSPACE/USER.md" << 'EOF'
# User

The user is a Clawoop subscriber who has deployed this AI assistant. Help them with any task — from scheduling meetings to managing files. Be proactive and practical. Always default to English. If the user writes in another language, respond in that language instead.
EOF
echo "[clawoop]   USER.md written ✓"

# 6e: Remove BOOTSTRAP.md — prevents onboarding questions
echo "[clawoop] Step 6e: Removing BOOTSTRAP.md..."
rm -f "$WORKSPACE/BOOTSTRAP.md" 2>/dev/null || true
rm -f /home/node/.openclaw/BOOTSTRAP.md 2>/dev/null || true
rm -f /home/node/BOOTSTRAP.md 2>/dev/null || true
find /home/node -name "BOOTSTRAP.md" -delete 2>/dev/null || true
echo "[clawoop]   BOOTSTRAP.md removed ✓"

# 6f: Verify workspace files
echo "[clawoop]   Workspace files:"
ls -la "$WORKSPACE/" 2>/dev/null || echo "   (workspace dir not found)"
echo "[clawoop]   SOUL.md preview:"
cat "$WORKSPACE/SOUL.md" 2>/dev/null | head -5 || echo "   (SOUL.md not found)"

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
  export XAI_BASE_URL="http://127.0.0.1:4100"
  export DEEPSEEK_BASE_URL="http://127.0.0.1:4100"
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

# Step 10: Start the gateway (with auto-restart on crash)
update_stage "starting"
echo "[clawoop] Step 10: Starting gateway..."

MAX_RETRIES=5
RETRY=0
while [ $RETRY -lt $MAX_RETRIES ]; do
  RETRY=$((RETRY + 1))
  echo "[clawoop]   Gateway start attempt $RETRY/$MAX_RETRIES"

  if [ "$PLATFORM" = "whatsapp" ]; then
    node openclaw.mjs gateway --allow-unconfigured 2>&1 | node /home/node/qr-watcher.mjs &
  else
    node openclaw.mjs gateway --allow-unconfigured 2>&1 &
  fi
  GATEWAY_PID=$!

  # Health check — wait for gateway process to stabilize, then mark as running
  if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && [ -n "$INSTANCE_ID" ]; then
    (
      # Give gateway 20s to start and stabilize
      sleep 20
      if kill -0 $GATEWAY_PID 2>/dev/null; then
        echo "[clawoop]   Gateway process alive after 20s — marking as running"
        curl -sf -X PATCH "${SUPABASE_URL}/rest/v1/deployments?id=eq.${INSTANCE_ID}" \
          -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
          -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
          -H "Content-Type: application/json" \
          -d '{"status": "running", "deploy_stage": "ready"}' > /dev/null 2>&1
        echo "[clawoop]   Status updated to running ✓"
      else
        echo "[clawoop]   Gateway process died within 20s"
      fi
    ) &
  fi

  # Wait for gateway to exit (|| true prevents set -e from killing the script)
  wait $GATEWAY_PID || true
  EXIT_CODE=$?
  echo "[clawoop]   Gateway exited with code $EXIT_CODE"

  if [ $RETRY -lt $MAX_RETRIES ]; then
    DELAY=$((RETRY * 5))
    echo "[clawoop]   Restarting in ${DELAY}s..."
    sleep $DELAY
  fi
done

echo "[clawoop]   Gateway failed after $MAX_RETRIES attempts"
# Update status to error
if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && [ -n "$INSTANCE_ID" ]; then
  curl -sf -X PATCH "${SUPABASE_URL}/rest/v1/deployments?id=eq.${INSTANCE_ID}" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"status": "error", "deploy_stage": "building"}' > /dev/null 2>&1
fi

