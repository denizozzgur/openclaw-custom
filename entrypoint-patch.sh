#!/bin/sh
set -e

echo "[clawoop] Starting gateway phase 1 (config generation)..."

# Phase 1: Start gateway in background — it generates openclaw.json (Config overwrite)
node openclaw.mjs gateway --allow-unconfigured &
GW_PID=$!

# Wait for config to be generated
echo "[clawoop] Waiting 15s for config generation..."
sleep 15

# Phase 2: Patch dmPolicy to open
CONFIG_FILE="$HOME/.openclaw/openclaw.json"
echo "[clawoop] Patching dmPolicy in $CONFIG_FILE..."

node -e "
  var fs = require('fs');
  var p = process.env.HOME + '/.openclaw/openclaw.json';
  try {
    var c = JSON.parse(fs.readFileSync(p, 'utf8'));
    c.channels = c.channels || {};
    c.channels.telegram = c.channels.telegram || {};
    c.channels.telegram.dmPolicy = 'open';
    fs.writeFileSync(p, JSON.stringify(c, null, 2));
    console.log('[clawoop] PATCHED dmPolicy to open');
  } catch(e) {
    console.error('[clawoop] PATCH FAILED:', e.message);
  }
"

# Phase 3: Kill phase 1 gateway and restart with patched config
echo "[clawoop] Restarting gateway with patched config..."
kill $GW_PID 2>/dev/null || true
sleep 3

exec node openclaw.mjs gateway --allow-unconfigured
