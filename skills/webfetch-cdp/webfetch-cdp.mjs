#!/usr/bin/env node
/**
 * webfetch-cdp.mjs - Core logic for fetching web page content via Playwright CDP
 *
 * Runs as a persistent background process. Listens on an HTTP port (default 8668),
 * receives JSON POST requests to /fetch, returns YAML snapshots.
 *
 * Request format (JSON POST to /fetch):
 *   {"url": "https://...", "waitSelector": "...", "waitTime": 10000, "viewport": "W,H"}
 *
 * Response format:
 *   YAML snapshot content (200 OK) or JSON error object (400/500)
 *
 * Environment variables:
 *   PW_MODULE    - Path to the playwright Node.js module (required)
 *   HTTP_PORT    - HTTP port to listen on (default: 8668)
 */

import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import net from 'node:net';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';

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

// --- Auto-launch Chrome with CDP enabled ---

async function launchChromeWithCDP() {
  const platform = os.platform();
  let chromePath = null;
  const userDataDir = path.join(os.tmpdir(), 'webfetch-cdp-chrome-profile');

  if (platform === 'darwin') {
    const possiblePaths = [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
    ];
    for (const p of possiblePaths) {
      if (fs.existsSync(p)) {
        chromePath = p;
        break;
      }
    }
  } else if (platform === 'linux') {
    const possiblePaths = [
      '/usr/bin/google-chrome',
      '/usr/bin/google-chrome-stable',
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
    ];
    for (const p of possiblePaths) {
      if (fs.existsSync(p)) {
        chromePath = p;
        break;
      }
    }
  }

  if (!chromePath) {
    console.error('Error: Chrome not found');
    return null;
  }

  console.error(`[chrome] Launching Chrome with CDP on port 9222...`);

  // Ensure user data dir exists
  if (!fs.existsSync(userDataDir)) {
    fs.mkdirSync(userDataDir, { recursive: true });
  }

  const chromeProcess = spawn(chromePath, [
    '--remote-debugging-port=9222',
    `--user-data-dir=${userDataDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-default-apps',
    '--disable-popup-blocking',
    '--disable-extensions',
    '--disable-plugins',
    '--disable-background-networking',
    '--disable-sync',
    '--metrics-recording-only',
    '--no-pings',
    '--mute-audio',
    '--disable-hang-monitor',
    '--disable-prompt-on-repost',
    '--password-store=basic',
    '--use-mock-keychain',
  ], {
    stdio: 'ignore',
    detached: true,
  });

  chromeProcess.unref();

  // Wait for Chrome to start and CDP port to be available
  console.error('[chrome] Waiting for Chrome to be ready...');
  for (let i = 0; i < 30; i++) {
    await new Promise(resolve => setTimeout(resolve, 1000));
    if (await checkPort(9222)) {
      console.error('[chrome] Chrome is ready on port 9222');
      return `ws://127.0.0.1:9222`;
    }
  }

  console.error('Error: Chrome failed to start within 30 seconds');
  return null;
}

// --- Handle a single request ---

async function handleRequest(browser, req, reconnectFn) {
  const { url, waitSelector, waitTime = 10000, viewport } = req;
  if (!url) {
    return { error: 'url is required' };
  }

  // Check if browser is still connected, reconnect if needed
  if (!browser.isConnected()) {
    console.error(`[http] Browser disconnected, reconnecting...`);
    try {
      await reconnectFn();
    } catch (e) {
      return { error: `Failed to reconnect: ${e.message}` };
    }
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

  // --- CDP state: lazy connect, never kill daemon ---
  let browser = null;
  let browserConnected = false;

  async function connectBrowser() {
    const wsUrl = await discoverChromeWsUrl();
    if (!wsUrl) {
      throw new Error('Chrome CDP not found (Chrome not running with --remote-debugging-port?)');
    }
    console.error(`[cdp] Connecting to Chrome CDP at ${wsUrl}`);
    browser = await chromium.connectOverCDP(wsUrl);
    browserConnected = true;
    console.error('[cdp] Connected');

    browser.on('disconnected', () => {
      console.error('[cdp] Browser disconnected — will reconnect on next request');
      browserConnected = false;
      browser = null;
    });
  }

  async function ensureBrowser() {
    if (browser && browserConnected && browser.isConnected()) {
      return browser;
    }
    // Not connected — try (re)connect
    try {
      await connectBrowser();
      return browser;
    } catch (e) {
      console.error(`[cdp] Connect failed: ${e.message}`);
      return null;
    }
  }

  // --- Start HTTP server FIRST — daemon never dies from CDP issues ---
  const server = createServer(async (req, res) => {
    if (req.method === 'POST' && req.url === '/fetch') {
      let body = '';
      req.on('data', chunk => { body += chunk.toString(); });
      req.on('end', async () => {
        try {
          const reqData = JSON.parse(body);
          console.error(`[http] POST /fetch: ${reqData.url}`);

          const b = await ensureBrowser();
          if (!b) {
            res.writeHead(503, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Chrome CDP not available — start Chrome with --remote-debugging-port' }));
            return;
          }

          const result = await handleRequest(b, reqData, ensureBrowser);
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
    fs.writeFileSync('/tmp/webfetch-cdp.pid', String(process.pid));
    console.error(`webfetch-cdp daemon started, pid=${process.pid}`);
  });

  server.on('error', (e) => {
    console.error(`HTTP server error: ${e.message}`);
  });
}

main().catch((e) => {
  console.error(`Fatal: ${e.message}`);
  process.exit(1);
});

process.on('uncaughtException', (e) => {
  console.error(`[uncaughtException] ${e.message}`);
});

process.on('unhandledRejection', (e) => {
  console.error(`[unhandledRejection] ${e?.message || e}`);
});
