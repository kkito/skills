#!/usr/bin/env node
/**
 * webfetch-cdp.mjs - Core logic for fetching web page content via Playwright CDP
 *
 * Environment variables (set by webfetch-cdp.sh):
 *   PW_MODULE      - Path to playwright module
 *   URL            - Target URL
 *   WAIT_SELECTOR  - CSS selector to wait for (optional)
 *   WAIT_TIME      - Max wait time in ms (default: 10000)
 *   VIEWPORT       - Viewport size as "W,H" (optional)
 */

import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import net from 'node:net';

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
  // 1. Try DevToolsActivePort file
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

  // 2. Scan common ports
  const commonPorts = [9222, 9229, 9333];
  for (const port of commonPorts) {
    if (await checkPort(port)) {
      // Try to get WebSocket URL via HTTP
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

// --- Main ---

async function main() {
  const { URL, WAIT_SELECTOR, WAIT_TIME, VIEWPORT, PW_MODULE } = process.env;

  if (!URL) {
    console.error('Error: URL is required');
    process.exit(1);
  }

  if (!PW_MODULE) {
    console.error('Error: PW_MODULE environment variable not set');
    process.exit(1);
  }

  // Load playwright dynamically
  let chromium;
  try {
    const pwPath = path.join(PW_MODULE, 'index.js');
    const pw = await import(pwPath);
    // ESM import returns namespace; playwright uses default export
    chromium = pw.default?.chromium || pw.chromium;
    if (!chromium) {
      console.error('Error: chromium not found in playwright module');
      console.error('Available exports:', Object.keys(pw).join(', '));
      process.exit(1);
    }
  } catch (e) {
    console.error(`Error: Failed to load playwright from ${PW_MODULE}`);
    console.error(e.message);
    process.exit(1);
  }

  // Discover Chrome CDP endpoint
  const wsUrl = await discoverChromeWsUrl();
  let browser;
  let createdPage = false;

  if (wsUrl) {
    try {
      browser = await chromium.connectOverCDP(wsUrl);
    } catch (e) {
      console.error(`Error: Failed to connect to Chrome via CDP (${wsUrl})`);
      console.error(e.message);
      process.exit(1);
    }
  } else {
    console.error(
      'Error: Chrome remote debugging port not found.\n' +
      '  Please enable it in Chrome:\n' +
      '  1. Open chrome://inspect/#remote-debugging\n' +
      '  2. Check "Allow remote debugging for this browser instance"\n' +
      '  (You may need to restart Chrome after enabling)'
    );
    process.exit(1);
  }

  let page = null;

  try {
    // Find or create a browser context
    const contexts = browser.contexts();
    let context;
    if (contexts.length > 0) {
      context = contexts[0];
    } else {
      context = await browser.newContext();
    }

    // Record existing page count so we only close what we created
    const existingPageCount = context.pages().length;

    // Create a new page for this fetch
    page = await context.newPage();
    createdPage = true;

    // Set viewport if specified
    if (VIEWPORT) {
      const [width, height] = VIEWPORT.split(',').map(Number);
      if (width && height) {
        await page.setViewportSize({ width, height });
      }
    }

    // Navigate to URL
    await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 30000 });

    // Wait for network to be idle (SPA apps often need time for API calls after initial HTML load)
    try {
      await page.waitForLoadState('networkidle', { timeout: parseInt(WAIT_TIME || '10000') });
    } catch {
      // Non-fatal: network may never be idle on pages with polling
    }

    // Wait for selector if specified
    if (WAIT_SELECTOR) {
      try {
        await page.waitForSelector(WAIT_SELECTOR, { timeout: parseInt(WAIT_TIME || '10000') });
      } catch {
        // Non-fatal: continue with snapshot even if selector not found
      }
    }

    // Take aria snapshot using _snapshotForAI (has built-in content polling with increasing delays)
    // This is the same path playwright-cli snapshot uses
    const snapshotResult = await page._snapshotForAI({ timeout: parseInt(WAIT_TIME || '10000') });
    console.log(snapshotResult.full);

  } finally {
    // Close only the page we created, never touch user's pages
    if (page) {
      await page.close().catch(() => {});
    }
    // CDP-connected browser doesn't support disconnect(); just let process exit.
    // The WebSocket connection will be dropped when the Node process terminates.
    // browser.close() would kill the user's Chrome, so we never call it.
  }
}

main().then(() => {
  process.exit(0);
}).catch((e) => {
  console.error(`Error: ${e.message}`);
  process.exit(1);
});
