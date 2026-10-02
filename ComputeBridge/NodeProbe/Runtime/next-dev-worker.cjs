'use strict';

const path = require('node:path');
const { parentPort, workerData } = require('node:worker_threads');

process.env.NEXT_MANUAL_SIG_HANDLE = '1';
parentPort.on('message', message => {
  if (message?.type !== 'stop') return;
  const cleanup = globalThis.__COMPUTEBRIDGE_STOP_NEXT;
  if (typeof cleanup === 'function') cleanup();
  else process.exit(0);
});

async function main() {
  try {
    const { startServer } = require(path.join(workerData.project, 'node_modules/next/dist/server/lib/start-server'));
    await startServer({
      dir: workerData.project,
      isDev: true,
      hostname: '0.0.0.0',
      port: 3001,
      allowRetry: false
    });
    parentPort.postMessage({ phase: 'ready' });
  } catch (error) {
    parentPort.postMessage({ phase: 'error', message: error.message });
  }
}

main();
