#!/usr/bin/env node
// Start Astro dev on a kernel-assigned random port, then sync the port to
// puma-dev so http://agent-tts.test always proxies to the live dev server.

import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync, existsSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const APP = 'agent-tts';
const pumaDir = join(homedir(), '.puma-dev');
const pumaFile = join(pumaDir, APP);

function pickFreePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

const port = await pickFreePort();

if (existsSync(pumaDir)) {
  writeFileSync(pumaFile, String(port));
  console.log(`puma-dev → http://${APP}.test  (proxy → :${port})`);
} else {
  console.log(`(puma-dev not installed — skipping ~/.puma-dev/${APP})`);
  console.log(`local URL → http://localhost:${port}`);
}

const child = spawn('astro', ['dev', '--port', String(port)], {
  stdio: 'inherit',
  env: process.env,
});

const cleanup = () => {
  try { if (existsSync(pumaFile)) unlinkSync(pumaFile); } catch {}
};

process.on('SIGINT', () => { cleanup(); child.kill('SIGINT'); });
process.on('SIGTERM', () => { cleanup(); child.kill('SIGTERM'); });
child.on('exit', (code) => { cleanup(); process.exit(code ?? 0); });
