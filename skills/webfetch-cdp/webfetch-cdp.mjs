#!/usr/bin/env node
/**
 * webfetch-cdp.mjs - Core logic for fetching web page content via Playwright CDP
 *
 * Runs as a persistent background process. Listens on a Unix domain socket,
 * receives JSON requests, returns YAML snapshots.
 *
 * Request format (JSON, one per connection):
 *   {"url": "https://...", "waitSelector": "...", "waitTime": 10000, "viewport": "W,H"}
 *
 * Response format:
 *   YAML snapshot content followed by "---END---" on its own line
 *
 * Environment variables:
 *   SOCKET_FILE    - Unix socket path to listen on
 */

import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import net from 'node:net';
import { createServer } from 'node:http';

// --- Discover Chrome CDP WebSocket URL ---

function checkPort(port) {
  return new Promise((resolve) => {
    const socket = net.createConnection(port, '127.0.0.1');
    const timer = setTimeout(() => { socket.destroy(); resolve(false); }, 1500);
    socket.once('connect', () => { clearTimeout(timer); socket.destroy(); resolve(true); });
    socket.once('error', () => { clearTimeout(timer); resolve(false); });
  });
}

async function discoverChromeWsUrl() {
  const possiblePaths = [];
  const platform = os.platform();
  const home = os.homedir();

  if (platform === 'darwin') {
    possiblePaths.push(
      path.join(home, 'Library/Application Support/Google/Chrome/DevToolsActivePort'),
      path.join(home, 'Library/Application Support/Google/Chrome Canary/DevToolsActivePort'),
      path.join(home, 'Library/Application Support/Chromium/DevToolsActivePort'),
    );
  } else if (platform === 'linux') {
    possiblePaths.push(
      path.join(home, '.config/google-chrome/DevToolsActivePort'),
      path.join(home, '.config/chromium/DevToolsActivePort'),
    );
  } else if (platform === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || '';
    possiblePaths.push(
      path.join(localAppData, 'Google/Chrome/User Data/DevToolsActivePort'),
      path.join(localAppData, 'Chromium/User Data/DevToolsActivePort'),
    );
  }

  for (const p of possiblePaths) {
    try {
      const content = fs.readFileSync(p, 'utf-8').trim();
      const lines = content.split('\n');
      const port = parseInt(lines[0]);
      if (port > 0 && port < 65536) {
        if (await checkPort(port)) {
          const wsPath = lines[1] || null;
          if (wsPath && wsPath.startsWith('/devtools/browser/')) {
            return `ws://127.0.0.1:${port}${wsPath}`;
          }
          return { port, hasWsPath: !!wsPath };
        }
      }
    } catch { /* file not found, continue */ }
  }

  const commonPorts = [9222, 9229, 9333];
  for (const port of commonPorts) {
    if (await checkPort(port)) {
      try {
        const http = await import('node:http');
        const body = await new Promise((resolve, reject) => {
          http.default.get(`http://127.0.0.1:${port}/json/version`, { timeout: 2000 }, (res) => {
            let data = '';
            res.on('data', c => data += c);
            res.on('end', () => resolve(data));
          }).on('error', reject);
        });
        const json = JSON.parse(body);
        if (json.webSocketDebuggerUrl) {
          return json.webSocketDebuggerUrl;
        }
      } catch { /* HTTP endpoint not available, use ws:// fallback */ }
      return `ws://127.0.0.1:${port}`;
    }
  }

  return null;
}

// --- Handle a single request ---

async function handleRequest(browser, req) {
  const { url, waitSelector, waitTime = 10000, viewport } = req;
  if (!url) {
    return { error: 'url is required' };
  }

  let page = null;
  try {
    // Reuse existing context (newContext may not work with CDP-connected browser)
    const contexts = browser.contexts();
    let context;
    if (contexts.length > 0) {
      context = contexts[0];
    } else {
      try {
        context = await browser.newContext();
      } catch (e) {
        console.error(`[http] newContext failed: ${e.message}`);
        throw e;
      }
    }

    // Create a new page for this fetch
    try {
      const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error('newPage timeout')), 15000));
      page = await Promise.race([context.newPage(), timeout]);
    } catch (e) {
      console.error(`[http] newPage failed:`, e.message);
      throw e;
    }

    // Set viewport if specified
    if (viewport) {
      const [width, height] = viewport.split(',').map(Number);
      if (width && height) {
        await page.setViewportSize({ width, height });
      }
    }

    // Navigate to URL
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });

    // Wait for network to be idle
    try {
      await page.waitForLoadState('networkidle', { timeout: waitTime });
    } catch {
      // Timeout is non-fatal
    }

    // Wait for selector if specified
    if (waitSelector) {
      try {
        await page.waitForSelector(waitSelector, { timeout: waitTime });
      } catch {
        // Non-fatal: continue with snapshot
      }
    }

    // Take aria snapshot
    const snapshotResult = await page._snapshotForAI({ timeout: waitTime });
    return { snapshot: snapshotResult.full };
  } finally {
    if (page) {
      await page.close().catch(() => {});
    }
  }
}

// --- Persistent daemon mode ---

async function main() {
  const { PW_MODULE, HTTP_PORT } = process.env;

  if (!PW_MODULE) {
    console.error('Error: PW_MODULE environment variable not set');
    process.exit(1);
  }

  const port = HTTP_PORT ? parseInt(HTTP_PORT, 10) : 8668;

  // Load playwright
  const pw = await import(`file://${PW_MODULE}/index.js`);
  const chromium = pw.default?.chromium || pw.chromium;
  if (!chromium) {
    console.error('Error: chromium not found in playwright module');
    process.exit(1);
  }

  // Discover and connect to Chrome CDP
  const wsUrl = await discoverChromeWsUrl();
  let browser;

  if (wsUrl) {
    try {
      browser = await chromium.connectOverCDP(wsUrl);
    } catch (e) {
      console.error(`Error: Failed to connect to Chrome via CDP (${wsUrl})`);
      process.exit(1);
    }
  } else {
    console.error('Error: Chrome remote debugging port not found.');
    process.exit(1);
  }

  // Write PID so the shell wrapper can find us
  fs.writeFileSync('/tmp/webfetch-cdp.pid', String(process.pid));
  console.error(`webfetch-cdp daemon started, pid=${process.pid}`);

  // Monitor browser disconnection
  browser.on('disconnected', () => {
    console.error('[FATAL] Browser disconnected! Process will exit.');
    process.exit(1);
  });

  // Create HTTP server
  const server = createServer(async (req, res) => {
    if (req.method === 'POST' && req.url === '/fetch') {
      let body = '';
      req.on('data', chunk => { body += chunk.toString(); });
      req.on('end', async () => {
        try {
          const reqData = JSON.parse(body);
          console.error(`[http] POST /fetch: ${reqData.url}`);

          const result = await handleRequest(browser, reqData);
          if (result.error) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: result.error }));
          } else {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end(result.snapshot);
          }
        } catch (e) {
          console.error(`[http] error:`, e.message);
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: e.message }));
        }
      });
    } else if (req.method === 'POST' && req.url === '/exit') {
      res.writeHead(200);
      res.end('ok');
      process.exit(0);
    } else {
      res.writeHead(404);
      res.end('Not found');
    }
  });

  server.listen(port, '127.0.0.1', () => {
    console.error(`webfetch-cdp daemon listening on http://127.0.0.1:${port}`);
  });

  server.on('error', (e) => {
    console.error(`HTTP server error: ${e.message}`);
  });

  // Keep process alive
  const keepAlive = setInterval(() => {}, 60000);
  keepAlive.ref();

  // Monitor browser connection
  browser.on('disconnected', () => {
    console.error('[http] Browser disconnected, exiting...');
    process.exit(1);
  });
}

main().catch((e) => {
  console.error(`Error: ${e.message}`);
  process.exit(1);
});

process.on('uncaughtException', (e) => {
  console.error(`[uncaughtException] ${e.message}`);
  console.error(e.stack);
});

process.on('unhandledRejection', (e) => {
  console.error(`[unhandledRejection] ${e?.message || e}`);
});

process.on('exit', (code) => {
  console.error(`[exit] process exiting with code: ${code}`);
});

process.on('beforeExit', (code) => {
  console.error(`[beforeExit] code: ${code}`);
});
