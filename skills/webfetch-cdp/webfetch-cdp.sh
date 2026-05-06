#!/usr/bin/env node
'use strict';

/**
 * webfetch-cdp — Node.js CLI launcher
 *
 * Replaces the old bash wrapper. Manages the persistent daemon (webfetch-cdp.mjs)
 * using spawn + detached.
 *
 * Usage:
 *   webfetch-cdp.sh <url> [options]
 *   webfetch-cdp.sh --url <url> [options]
 *   webfetch-cdp.sh --stop
 *   webfetch-cdp.sh --restart
 *
 * Options:
 *   --wait-selector <sel>   CSS selector to wait for
 *   --wait-time <ms>        Max wait time (default: 10000)
 *   --viewport <W,H>        Viewport size, e.g. "1920,1080"
 */

// --- CommonJS (portable — works with any file extension) ---

const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const net = require('net');

const SCRIPT_DIR = path.dirname(fs.realpathSync(__filename));
const HTTP_PORT = parseInt(process.env.WEBFETCH_CDP_PORT || '8668');
const DAEMON_SCRIPT = path.join(SCRIPT_DIR, 'webfetch-cdp.mjs');
const DAEMON_LOG = '/tmp/webfetch-cdp.log';

// ──────────────────────────────────────────────
// Port / connectivity helpers
// ──────────────────────────────────────────────

function checkPort(port, host = '127.0.0.1', timeoutMs = 2000) {
  return new Promise((resolve) => {
    const socket = net.createConnection(port, host);
    const timer = setTimeout(() => { socket.destroy(); resolve(false); }, timeoutMs);
    socket.once('connect', () => { clearTimeout(timer); socket.destroy(); resolve(true); });
    socket.once('error', () => { clearTimeout(timer); resolve(false); });
  });
}

function httpPost(url, jsonBody, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const payload = JSON.stringify(jsonBody);
    const req = http.request({
      hostname: u.hostname, port: u.port, path: u.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      },
      timeout: timeoutMs,
    }, (res) => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

// ──────────────────────────────────────────────
// Find playwright module (same logic as old bash)
// ──────────────────────────────────────────────

function findPlaywrightModule() {
  const { execSync } = require('child_process');

  try {
    const cliPath = execSync('command -v playwright-cli 2>/dev/null', { encoding: 'utf-8' }).trim();
    if (cliPath) {
      const dir = path.dirname(cliPath);
      const nm = path.resolve(dir, '../lib/node_modules/@playwright/cli/node_modules');
      if (fs.existsSync(path.join(nm, 'playwright'))) {
        return path.join(nm, 'playwright');
      }
    }
  } catch { /* not found in PATH, try npm root */ }

  try {
    const npmRoot = execSync('npm root -g 2>/dev/null', { encoding: 'utf-8' }).trim();
    if (npmRoot) {
      const nm = path.join(npmRoot, '@playwright/cli/node_modules');
      if (fs.existsSync(path.join(nm, 'playwright'))) {
        return path.join(nm, 'playwright');
      }
    }
  } catch { /* npm root failed */ }

  console.error('Error: Cannot find playwright module');
  console.error('  playwright-cli must be installed globally.');
  process.exit(1);
}

// ──────────────────────────────────────────────
// Daemon management 
// ──────────────────────────────────────────────

function startDaemonDetached() {
  const logFd = fs.openSync(DAEMON_LOG, 'a');
  const pwModule = findPlaywrightModule();

  const child = spawn(process.execPath, [DAEMON_SCRIPT], {
    detached: true,                               // ← KEY: new process group
    stdio: ['ignore', logFd, logFd],
    env: {
      ...process.env,
      PW_MODULE: pwModule,
      HTTP_PORT: String(HTTP_PORT),
    },
  });

  child.unref();                                   // ← KEY: parent won't wait
  fs.closeSync(logFd);

  console.error(`[debug] Daemon starting (detached, PID ${child.pid})...`);
}

async function ensureDaemon() {
  // Fast path — port already listening
  if (await checkPort(HTTP_PORT)) {
    return;
  }

  console.error('[debug] Daemon not running, starting...');
  startDaemonDetached();

  // Wait up to 10 s for HTTP server
  for (let i = 0; i < 100; i++) {
    await new Promise(r => setTimeout(r, 100));
    if (await checkPort(HTTP_PORT)) {
      console.error('[debug] Daemon is ready');
      return;
    }
  }

  // Timed out — show log tail
  console.error('Error: Failed to start daemon. Log tail:');
  try {
    const log = fs.readFileSync(DAEMON_LOG, 'utf-8');
    const lines = log.trim().split('\n').slice(-10);
    for (const l of lines) console.error('  ' + l);
  } catch { /* no log yet */ }
  process.exit(1);
}

async function stopDaemon() {
  try {
    await httpPost(`http://127.0.0.1:${HTTP_PORT}/exit`, {});
    console.log('Daemon stopped.');
  } catch {
    // Force kill by PID file
    const pidFile = '/tmp/webfetch-cdp.pid';
    try {
      const pid = parseInt(fs.readFileSync(pidFile, 'utf-8').trim(), 10);
      try { process.kill(pid, 'SIGKILL'); } catch { /* already dead */ }
      fs.unlinkSync(pidFile);
      console.log('Daemon killed (PID', pid, ').');
    } catch {
      console.log('Daemon not running.');
    }
  }
}

// ──────────────────────────────────────────────
// Argument parsing
// ──────────────────────────────────────────────

function parseArgs(argv) {
  let url = '';
  let waitSelector = '';
  let waitTime = 10000;
  let viewport = '';
  let action = 'fetch';   // fetch | stop | restart

  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--url':
        url = argv[++i];
        break;
      case '--wait-selector':
        waitSelector = argv[++i];
        break;
      case '--wait-time':
        waitTime = parseInt(argv[++i], 10) || 10000;
        break;
      case '--viewport':
        viewport = argv[++i];
        break;
      case '--stop':
        action = 'stop';
        break;
      case '--restart':
        action = 'restart';
        break;
      case '--help':
      case '-h':
        console.log(`Usage:
  webfetch-cdp.sh <url> [options]
  webfetch-cdp.sh --url <url> [options]
  webfetch-cdp.sh --stop
  webfetch-cdp.sh --restart

Options:
  --wait-selector <sel>  CSS selector to wait for
  --wait-time <ms>        Max wait time (default: 10000)
  --viewport <W,H>        Viewport size, e.g. "1920,1080"
`);
        process.exit(0);
      default:
        if (argv[i].startsWith('http://') || argv[i].startsWith('https://')) {
          url = argv[i];
        } else if (argv[i].startsWith('-')) {
          console.error('Error: Unknown option:', argv[i]);
          process.exit(1);
        } else {
          console.error('Error: Invalid argument:', argv[i]);
          process.exit(1);
        }
    }
  }

  return { url, waitSelector, waitTime, viewport, action };
}

// ──────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────

async function main() {
  const args = parseArgs(process.argv.slice(2));

  switch (args.action) {
    case 'stop':
      await stopDaemon();
      return;
    case 'restart':
      await stopDaemon();
      await new Promise(r => setTimeout(r, 500));
      await ensureDaemon();
      console.log('Daemon restarted.');
      return;
  }

  if (!args.url) {
    console.error('Error: URL is required');
    process.exit(1);
  }

  // Make sure daemon is alive, then send request
  await ensureDaemon();

  const result = await httpPost(`http://127.0.0.1:${HTTP_PORT}/fetch`, {
    url: args.url,
    waitSelector: args.waitSelector,
    waitTime: args.waitTime,
    viewport: args.viewport,
  });

  process.stdout.write(result.body);
}

main().catch(e => {
  console.error('Error:', e.message);
  process.exit(1);
});
