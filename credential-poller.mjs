#!/usr/bin/env node
// credential-poller.mjs
// Runs as a sidecar alongside the OpenClaw gateway.
// Polls Supabase every 60s for credential/integration changes,
// then hot-reloads the OpenClaw config (system prompt + tool env)
// WITHOUT restarting the gateway process.

import { execSync } from 'child_process';
import { writeFileSync, readFileSync, existsSync } from 'fs';
import { createHash } from 'crypto';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const USER_ID = process.env.USER_ID;
const POLL_INTERVAL = parseInt(process.env.CREDENTIAL_POLL_INTERVAL || '60', 10) * 1000;

const OPENCLAW_ENV_PATH = '/home/node/.openclaw/.env';
const STATE_FILE = '/tmp/.credential-poller-hash';

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !USER_ID) {
    console.log('[credential-poller] Missing SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, or USER_ID — exiting');
    process.exit(0);
}

console.log(`[credential-poller] Started — polling every ${POLL_INTERVAL / 1000}s for user ${USER_ID}`);

// Store last known hash to detect changes
let lastHash = '';
if (existsSync(STATE_FILE)) {
    lastHash = readFileSync(STATE_FILE, 'utf-8').trim();
}

async function fetchCredentials() {
    const res = await fetch(
        `${SUPABASE_URL}/rest/v1/user_oauth_tokens?user_id=eq.${USER_ID}&select=provider,refresh_token_encrypted,access_token_encrypted,connected_email,credentials_json`,
        {
            headers: {
                'apikey': SUPABASE_SERVICE_ROLE_KEY,
                'Authorization': `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
            },
        }
    );
    if (!res.ok) {
        console.error('[credential-poller] Supabase fetch failed:', res.status, await res.text());
        return null;
    }
    return res.json();
}

function hashCredentials(creds) {
    return createHash('sha256').update(JSON.stringify(creds)).digest('hex');
}

function buildEnvBlock(serviceTokens) {
    const lines = [];
    const envVars = {};

    for (const svc of serviceTokens) {
        switch (svc.provider) {
            case 'google':
                if (svc.refresh_token_encrypted) {
                    envVars.GOG_REFRESH_TOKEN = svc.refresh_token_encrypted;
                    envVars.GOG_ACCESS_TOKEN = svc.access_token_encrypted || '';
                    envVars.GOOGLE_OAUTH_CLIENT_ID = process.env.GOOGLE_OAUTH_CLIENT_ID || '';
                    envVars.GOOGLE_OAUTH_CLIENT_SECRET = process.env.GOOGLE_OAUTH_CLIENT_SECRET || '';
                    envVars.GOG_KEYRING_BACKEND = process.env.GOG_KEYRING_BACKEND || 'file';
                    envVars.GOG_KEYRING_PASSWORD = process.env.GOG_KEYRING_PASSWORD || 'clawoop-default';
                    envVars.GOG_CONNECTED_EMAIL = svc.connected_email || '';
                }
                break;
            case 'notion':
                if (svc.access_token_encrypted) envVars.NOTION_API_KEY = svc.access_token_encrypted;
                break;
            case 'github':
                if (svc.access_token_encrypted) envVars.GITHUB_TOKEN = svc.access_token_encrypted;
                break;
            case 'spotify':
                if (svc.credentials_json) {
                    envVars.SPOTIFY_CLIENT_ID = svc.credentials_json.SPOTIFY_CLIENT_ID || '';
                    envVars.SPOTIFY_CLIENT_SECRET = svc.credentials_json.SPOTIFY_CLIENT_SECRET || '';
                }
                break;
            case 'trello':
                if (svc.credentials_json) {
                    envVars.TRELLO_API_KEY = svc.credentials_json.TRELLO_API_KEY || '';
                    envVars.TRELLO_TOKEN = svc.credentials_json.TRELLO_TOKEN || '';
                }
                break;
            case 'twitter':
                if (svc.credentials_json) {
                    envVars.X_API_KEY = svc.credentials_json.X_API_KEY || '';
                    envVars.X_API_SECRET = svc.credentials_json.X_API_SECRET || '';
                    envVars.X_ACCESS_TOKEN = svc.credentials_json.X_ACCESS_TOKEN || '';
                    envVars.X_ACCESS_SECRET = svc.credentials_json.X_ACCESS_SECRET || '';
                }
                break;
            case 'homeassistant':
                if (svc.credentials_json) {
                    envVars.HA_URL = svc.credentials_json.HA_URL || '';
                    envVars.HA_TOKEN = svc.credentials_json.HA_TOKEN || '';
                }
                break;
        }
    }

    for (const [k, v] of Object.entries(envVars)) {
        lines.push(`${k}=${v}`);
        // Also set in current process so tools can use them
        process.env[k] = v;
    }

    return { lines, envVars };
}

function buildSystemPrompt(serviceTokens) {
    let connectedBlock = '';
    let unconnectedBlock = '';

    const providers = {
        google: { token: null, label: '**Google Workspace**: Calendar (list/create/update events), Gmail (read/send emails), Drive (list/search files). Use the gog tool.' },
        notion: { token: null, label: '**Notion**: Create pages, query databases, search workspace. Use the notion tool.' },
        github: { token: null, label: '**GitHub**: List repos, create/list issues, manage PRs. Use the github tool.' },
        spotify: { token: null, label: '**Spotify**: Control playback, search music, manage playlists. Use curl/fetch with the Spotify Web API and the stored credentials.' },
        trello: { token: null, label: '**Trello**: List boards, create/move cards, manage lists. Use the trello tool.' },
        twitter: { token: null, label: '**Twitter/X**: Post tweets, search, manage timeline. Use curl with the X API v2 and the stored credentials.' },
        homeassistant: { token: null, label: '**Home Assistant**: Control lights, switches, climate, and other smart home devices. Use curl with the HA REST API.' },
    };

    const connectLinks = {
        google: 'https://clawoop.com?connect=google',
        notion: 'https://clawoop.com?connect=notion',
        github: 'https://clawoop.com?connect=github',
        spotify: 'https://clawoop.com?connect=spotify',
        trello: 'https://clawoop.com?connect=trello',
        twitter: 'https://clawoop.com?connect=twitter',
        homeassistant: 'https://clawoop.com?connect=homeassistant',
    };

    // Mark connected providers
    for (const svc of serviceTokens) {
        if (providers[svc.provider]) {
            providers[svc.provider].token = svc;
        }
    }

    for (const [id, p] of Object.entries(providers)) {
        if (p.token) {
            connectedBlock += `\n- ${p.label}`;
        } else {
            const name = id.charAt(0).toUpperCase() + id.slice(1);
            unconnectedBlock += `\n- ${name} → ${connectLinks[id]}`;
        }
    }

    return `You are a helpful AI assistant managed by Clawoop. You can chat naturally and also perform real actions through connected services.

## Connected Services (ready to use)
${connectedBlock || 'No services connected yet.'}

## Services Not Yet Connected
If the user asks for something that needs one of these, tell them which service is needed and share the connection link:
${unconnectedBlock || 'All services are connected!'}

## Rules
- For connected services, take action directly when asked. Don't ask for confirmation unless the action is destructive.
- For unconnected services, explain what's needed and share the exact connection link.
- Never fabricate data. If a tool call fails, tell the user honestly.
- Be concise and helpful.
- If an AI request fails with a credit_exceeded or rate_limit error, tell the user: 'Aylık AI krediniz doldu. Bir sonraki faturalama döneminde yenilenecektir.' Do not retry.`;
}

function applyConfigUpdate(serviceTokens) {
    // 1. Update .env file
    const { lines, envVars } = buildEnvBlock(serviceTokens);
    try {
        // Read existing env, filter out credential lines, append new ones
        let existing = '';
        if (existsSync(OPENCLAW_ENV_PATH)) {
            existing = readFileSync(OPENCLAW_ENV_PATH, 'utf-8');
        }
        const credentialKeys = new Set(Object.keys(envVars));
        const filteredLines = existing.split('\n').filter(line => {
            const key = line.split('=')[0];
            return !credentialKeys.has(key);
        });
        const newContent = [...filteredLines.filter(l => l.trim()), ...lines].join('\n') + '\n';
        writeFileSync(OPENCLAW_ENV_PATH, newContent);
        console.log('[credential-poller] Updated .env with', lines.length, 'credential vars');
    } catch (e) {
        console.error('[credential-poller] Failed to update .env:', e.message);
    }

    // 2. Enable/disable tools
    const toolUpdates = [
        { key: 'GOG_REFRESH_TOKEN', tool: 'gog' },
        { key: 'NOTION_API_KEY', tool: 'notion' },
        { key: 'GITHUB_TOKEN', tool: 'github' },
        { key: 'TRELLO_API_KEY', tool: 'trello' },
    ];
    for (const { key, tool } of toolUpdates) {
        const enabled = !!envVars[key];
        try {
            execSync(`node openclaw.mjs config set --json tools.${tool} '{"enabled":${enabled}}'`, {
                cwd: '/home/node',
                stdio: 'pipe',
                timeout: 5000,
            });
        } catch (e) {
            // Non-critical
        }
    }

    // 3. Update system prompt
    const prompt = buildSystemPrompt(serviceTokens);
    try {
        execSync(`node openclaw.mjs config set ai.systemPrompt "${prompt.replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`, {
            cwd: '/home/node',
            stdio: 'pipe',
            timeout: 10000,
        });
        console.log('[credential-poller] System prompt updated');
    } catch (e) {
        console.error('[credential-poller] Failed to update system prompt:', e.message);
    }
}

async function poll() {
    try {
        const creds = await fetchCredentials();
        if (creds === null) return; // fetch failed, skip this cycle

        const hash = hashCredentials(creds);

        if (hash !== lastHash) {
            console.log('[credential-poller] Credential change detected! Providers:', creds.map(c => c.provider).join(', ') || 'none');
            applyConfigUpdate(creds);
            lastHash = hash;
            writeFileSync(STATE_FILE, hash);
            console.log('[credential-poller] Config hot-reloaded ✓ (no restart needed)');
        }
    } catch (e) {
        console.error('[credential-poller] Poll error:', e.message);
    }
}

// Initial poll
await poll();

// Schedule recurring polls
setInterval(poll, POLL_INTERVAL);
