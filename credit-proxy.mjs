#!/usr/bin/env node
/**
 * Clawoop Credit Proxy
 * Sits between OpenClaw and AI provider APIs.
 * Tracks token usage, enforces $15/month credit cap.
 * Supports both streaming (SSE) and non-streaming responses.
 *
 * Usage: node credit-proxy.mjs
 * Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, USER_ID, INSTANCE_ID, AI_PROVIDER, AI_MODEL
 */

import http from 'node:http';
import https from 'node:https';

const PORT = parseInt(process.env.CREDIT_PROXY_PORT || '4100');
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const USER_ID = process.env.USER_ID;
const INSTANCE_ID = process.env.INSTANCE_ID;
const AI_MODEL = process.env.AI_MODEL || 'anthropic/claude-opus-4-6';

// Model pricing in cents per 1M tokens
const MODEL_PRICING = {
    // Anthropic
    'anthropic/claude-opus-4-6': { input: 1500, output: 7500 },
    'anthropic/claude-sonnet-4-5': { input: 300, output: 1500 },
    // OpenAI
    'openai/gpt-5.2': { input: 250, output: 1000 },
    'openai/gpt-4.1': { input: 200, output: 800 },
    // Google
    'google/gemini-2.5-pro': { input: 125, output: 500 },
    // xAI
    'xai/grok-3': { input: 300, output: 1500 },
    // DeepSeek
    'deepseek/deepseek-chat': { input: 27, output: 110 },
};

// Real upstream API endpoints
const UPSTREAM = {
    anthropic: 'https://api.anthropic.com',
    openai: 'https://api.openai.com',
    google: 'https://generativelanguage.googleapis.com',
    xai: 'https://api.x.ai',
    deepseek: 'https://api.deepseek.com',
};

function getUpstreamUrl(provider) {
    return UPSTREAM[provider] || UPSTREAM.anthropic;
}

function calcCostCents(model, tokensIn, tokensOut) {
    const pricing = MODEL_PRICING[model] || MODEL_PRICING['anthropic/claude-opus-4-6'];
    const inCost = (tokensIn / 1_000_000) * pricing.input;
    const outCost = (tokensOut / 1_000_000) * pricing.output;
    return Math.ceil(inCost + outCost);
}

// Supabase REST helper
async function supabaseRest(method, table, params = '', body = null) {
    const url = `${SUPABASE_URL}/rest/v1/${table}${params}`;
    const opts = {
        method,
        headers: {
            'apikey': SUPABASE_KEY,
            'Authorization': `Bearer ${SUPABASE_KEY}`,
            'Content-Type': 'application/json',
            'Prefer': method === 'POST' ? 'return=representation' : (method === 'PATCH' ? 'return=representation' : ''),
        },
    };
    if (body) opts.body = JSON.stringify(body);
    const res = await fetch(url, opts);
    if (!res.ok) {
        const text = await res.text();
        console.error(`[credit-proxy] Supabase ${method} ${table} failed:`, res.status, text);
        return null;
    }
    const text = await res.text();
    return text ? JSON.parse(text) : null;
}

// Check remaining credit
async function checkCredit() {
    const data = await supabaseRest('GET', 'credit_balance', `?user_id=eq.${USER_ID}&select=total_cost_cents,cap_cents`);
    if (!data || data.length === 0) {
        // No record yet — create one
        await supabaseRest('POST', 'credit_balance', '', {
            user_id: USER_ID,
            period_start: new Date().toISOString(),
            total_cost_cents: 0,
            cap_cents: 1500,
        });
        return { remaining: 1500, exceeded: false };
    }
    const balance = data[0];
    const remaining = balance.cap_cents - balance.total_cost_cents;
    return { remaining, exceeded: remaining <= 0 };
}

// Log usage and update balance
async function logUsage(deploymentId, tokensIn, tokensOut, model) {
    const costCents = calcCostCents(model, tokensIn, tokensOut);

    // Insert usage log (non-blocking)
    supabaseRest('POST', 'ai_usage', '', {
        deployment_id: deploymentId,
        user_id: USER_ID,
        tokens_in: tokensIn,
        tokens_out: tokensOut,
        cost_cents: costCents,
        model,
    }).catch(e => console.error('[credit-proxy] Usage log failed:', e));

    // Update balance atomically using simple increment approach
    const data = await supabaseRest('GET', 'credit_balance', `?user_id=eq.${USER_ID}&select=total_cost_cents`);
    if (data && data.length > 0) {
        const newTotal = data[0].total_cost_cents + costCents;
        await supabaseRest('PATCH', 'credit_balance', `?user_id=eq.${USER_ID}`, {
            total_cost_cents: newTotal,
        });
    }

    return costCents;
}

// Extract token usage from AI provider response (non-streaming)
function extractUsage(provider, responseBody) {
    try {
        const data = JSON.parse(responseBody);
        return extractUsageFromParsed(provider, data);
    } catch { }
    return { tokensIn: 0, tokensOut: 0 };
}

// Extract usage from parsed JSON object
function extractUsageFromParsed(provider, data) {
    if (provider === 'anthropic') {
        return {
            tokensIn: data.usage?.input_tokens || 0,
            tokensOut: data.usage?.output_tokens || 0,
        };
    } else if (provider === 'openai' || provider === 'xai' || provider === 'deepseek') {
        return {
            tokensIn: data.usage?.prompt_tokens || 0,
            tokensOut: data.usage?.completion_tokens || 0,
        };
    } else if (provider === 'google') {
        const meta = data.usageMetadata || {};
        return {
            tokensIn: meta.promptTokenCount || 0,
            tokensOut: meta.candidatesTokenCount || 0,
        };
    }
    return { tokensIn: 0, tokensOut: 0 };
}

// Determine provider from request path
function detectProvider(path) {
    if (path.includes('/v1/messages')) return 'anthropic';
    if (path.includes('/v1/chat/completions')) return 'openai';
    if (path.includes('generateContent')) return 'google';
    return process.env.AI_PROVIDER || 'anthropic';
}

// Check if request body indicates streaming
function isStreamingRequest(reqBody) {
    try {
        const data = JSON.parse(reqBody);
        return data.stream === true;
    } catch { }
    return false;
}

// Credit exceeded response mimicking provider error format
function creditExceededResponse(provider) {
    if (provider === 'anthropic') {
        return JSON.stringify({
            type: 'error',
            error: {
                type: 'rate_limit_error',
                message: 'Your monthly AI credits have been used up ($15). They will be renewed in the next billing cycle. Check your account at clawoop.com for details.',
            },
        });
    }
    return JSON.stringify({
        error: {
            message: 'Your monthly AI credits have been used up ($15). They will be renewed in the next billing cycle.',
            type: 'rate_limit_error',
            code: 'credit_exceeded',
        },
    });
}

// Forward request and stream response back in real-time (SSE streaming)
function forwardRequestStreaming(provider, req, reqBody, res, credit) {
    const upstream = new URL(getUpstreamUrl(provider) + req.url);

    const options = {
        hostname: upstream.hostname,
        port: 443,
        path: upstream.pathname + upstream.search,
        method: req.method,
        headers: { ...req.headers, host: upstream.hostname },
    };

    const proxyReq = https.request(options, (proxyRes) => {
        // Forward status and headers immediately so client starts receiving
        const responseHeaders = { ...proxyRes.headers };
        res.writeHead(proxyRes.statusCode, responseHeaders);

        // Collect all chunks for usage extraction at the end
        let fullBody = '';
        let lastUsage = { tokensIn: 0, tokensOut: 0 };

        proxyRes.on('data', (chunk) => {
            // Forward each chunk immediately to OpenClaw (real-time streaming)
            res.write(chunk);

            // Also accumulate for usage extraction
            const chunkStr = chunk.toString();
            fullBody += chunkStr;

            // Try to extract usage from SSE data: lines
            // Anthropic sends usage in message_delta events
            // OpenAI sends usage in the final chunk
            const lines = chunkStr.split('\n');
            for (const line of lines) {
                if (!line.startsWith('data: ')) continue;
                const jsonStr = line.slice(6).trim();
                if (jsonStr === '[DONE]') continue;
                try {
                    const event = JSON.parse(jsonStr);
                    // Anthropic: message_delta has usage
                    if (event.type === 'message_delta' && event.usage) {
                        lastUsage.tokensOut = event.usage.output_tokens || lastUsage.tokensOut;
                    }
                    // Anthropic: message_start has input usage
                    if (event.type === 'message_start' && event.message?.usage) {
                        lastUsage.tokensIn = event.message.usage.input_tokens || 0;
                    }
                    // OpenAI/xAI/DeepSeek: usage in final chunk
                    if (event.usage) {
                        lastUsage.tokensIn = event.usage.prompt_tokens || event.usage.input_tokens || lastUsage.tokensIn;
                        lastUsage.tokensOut = event.usage.completion_tokens || event.usage.output_tokens || lastUsage.tokensOut;
                    }
                } catch { }
            }
        });

        proxyRes.on('end', () => {
            res.end();

            // Log usage if we got any
            if (proxyRes.statusCode >= 200 && proxyRes.statusCode < 300) {
                if (lastUsage.tokensIn > 0 || lastUsage.tokensOut > 0) {
                    logUsage(INSTANCE_ID, lastUsage.tokensIn, lastUsage.tokensOut, AI_MODEL)
                        .then(cost => {
                            console.log(`[credit-proxy] Streamed: ${lastUsage.tokensIn}in/${lastUsage.tokensOut}out = ${cost}¢ | remaining: ~${credit.remaining - cost}¢`);
                        })
                        .catch(e => console.error('[credit-proxy] Usage log failed:', e));
                }
            }
        });

        proxyRes.on('error', (err) => {
            console.error('[credit-proxy] Upstream stream error:', err);
            res.end();
        });
    });

    proxyReq.on('error', (err) => {
        console.error('[credit-proxy] Proxy request error:', err);
        res.writeHead(502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'Credit proxy error', type: 'proxy_error' } }));
    });

    proxyReq.write(reqBody);
    proxyReq.end();
}

// Forward request and buffer response (non-streaming)
function forwardRequest(provider, req, reqBody) {
    return new Promise((resolve, reject) => {
        const upstream = new URL(getUpstreamUrl(provider) + req.url);

        const options = {
            hostname: upstream.hostname,
            port: 443,
            path: upstream.pathname + upstream.search,
            method: req.method,
            headers: { ...req.headers, host: upstream.hostname },
        };

        const proxyReq = https.request(options, (proxyRes) => {
            const chunks = [];
            proxyRes.on('data', c => chunks.push(c));
            proxyRes.on('end', () => {
                resolve({
                    statusCode: proxyRes.statusCode,
                    headers: proxyRes.headers,
                    body: Buffer.concat(chunks).toString(),
                });
            });
        });

        proxyReq.on('error', reject);
        proxyReq.write(reqBody);
        proxyReq.end();
    });
}

// HTTP server
const server = http.createServer(async (req, res) => {
    // Health check
    if (req.url === '/health') {
        res.writeHead(200);
        res.end('ok');
        return;
    }

    const provider = detectProvider(req.url);

    // Collect request body
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const reqBody = Buffer.concat(chunks).toString();

    try {
        // Check credit before forwarding
        const credit = await checkCredit();
        if (credit.exceeded) {
            console.log(`[credit-proxy] Credit exceeded for user ${USER_ID} — blocking request`);
            const body = creditExceededResponse(provider);
            res.writeHead(429, { 'Content-Type': 'application/json' });
            res.end(body);
            return;
        }

        const streaming = isStreamingRequest(reqBody);

        if (streaming) {
            // Streaming: forward chunks in real-time, extract usage at the end
            forwardRequestStreaming(provider, req, reqBody, res, credit);
        } else {
            // Non-streaming: buffer full response, extract usage, then send
            const upstream = await forwardRequest(provider, req, reqBody);

            // Extract and log usage from successful responses
            if (upstream.statusCode >= 200 && upstream.statusCode < 300) {
                const usage = extractUsage(provider, upstream.body);
                if (usage.tokensIn > 0 || usage.tokensOut > 0) {
                    const model = AI_MODEL;
                    const cost = await logUsage(INSTANCE_ID, usage.tokensIn, usage.tokensOut, model);
                    console.log(`[credit-proxy] Logged: ${usage.tokensIn}in/${usage.tokensOut}out = ${cost}¢ | remaining: ${credit.remaining - cost}¢`);
                }
            }

            // Forward response back to OpenClaw
            const responseHeaders = { ...upstream.headers };
            delete responseHeaders['transfer-encoding']; // We send full body
            res.writeHead(upstream.statusCode, responseHeaders);
            res.end(upstream.body);
        }
    } catch (err) {
        console.error('[credit-proxy] Proxy error:', err);
        res.writeHead(502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'Credit proxy error', type: 'proxy_error' } }));
    }
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`[credit-proxy] Running on http://127.0.0.1:${PORT}`);
    console.log(`[credit-proxy] User: ${USER_ID}, Instance: ${INSTANCE_ID}, Model: ${AI_MODEL}`);
    console.log(`[credit-proxy] Streaming support: enabled`);
});
