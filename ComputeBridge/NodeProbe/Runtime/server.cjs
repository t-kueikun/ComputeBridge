'use strict';

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { Worker } = require('node:worker_threads');
const tar = require('tar');

const token = process.env.BRIDGE_TOKEN;
const support = process.cwd();
const project = path.join(support, 'active-project');
const wasmDirectory = path.join(__dirname, 'swc-wasm-nodejs');
const hasProject = fs.existsSync(path.join(project, 'package.json'));
const state = hasProject
  ? { phase: 'uploaded', message: 'Project available; start Next.js' }
  : { phase: 'waiting', message: 'Waiting for a Next.js project' };
let busy = false;
let nextWorker = null;
let startGeneration = 0;

function authorized(request) {
  const supplied = request.headers['x-bridge-token'];
  if (typeof supplied !== 'string' || !token) return false;
  const left = Buffer.from(supplied);
  const right = Buffer.from(token);
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function respond(reply, code, body) {
  const data = Buffer.from(JSON.stringify(body));
  reply.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': data.length,
    'connection': 'close'
  });
  reply.end(data);
}

async function saveRequest(request, destination, maximumBytes, onProgress = () => {}) {
  let size = 0;
  let lastReported = 0;
  const limit = new Transform({
    transform(chunk, _encoding, done) {
      size += chunk.length;
      if (size - lastReported >= 5 * 1024 * 1024) {
        lastReported = size;
        onProgress(size);
      }
      done(size > maximumBytes ? new Error('Upload exceeds the size limit') : null, chunk);
    }
  });
  await pipeline(request, limit, fs.createWriteStream(destination, { flags: 'wx' }));
  return size;
}

function safeSourcePath(raw) {
  const decoded = decodeURIComponent(raw);
  if (!decoded || decoded.startsWith('/') || decoded.includes('\\')) throw new Error('Invalid path');
  const parts = decoded.split('/');
  if (parts.some(part => part === '' || part === '.' || part === '..')) throw new Error('Invalid path');
  if (parts.some(part => part === '.git' || part === '.next' || part === 'node_modules' || part === '.npmrc' || part.startsWith('.env'))) {
    throw new Error('This path is excluded from source sync');
  }
  return path.join(project, ...parts);
}

async function sourceFile(request, reply, pathname) {
  if (state.phase !== 'ready') return respond(reply, 409, { error: 'Start the project first' });
  const destination = safeSourcePath(pathname);
  const parent = path.dirname(destination);
  await fsp.mkdir(parent, { recursive: true });
  const realParent = await fsp.realpath(parent);
  if (realParent !== project && !realParent.startsWith(project + path.sep)) {
    return respond(reply, 400, { error: 'Path leaves the project directory' });
  }
  if (request.method === 'DELETE') {
    await fsp.rm(destination, { force: true });
    return respond(reply, 200, { ok: true });
  }
  const temporary = destination + '.upload-' + crypto.randomUUID();
  try {
    const size = await saveRequest(request, temporary, 100 * 1024 * 1024);
    await fsp.rename(temporary, destination);
    return respond(reply, 200, { ok: true, bytes: size });
  } catch (error) {
    await fsp.rm(temporary, { force: true });
    throw error;
  }
}

function patchNextForIOS(directory) {
  const nextRoot = path.join(directory, 'node_modules', 'next');
  const nextPackage = JSON.parse(fs.readFileSync(path.join(nextRoot, 'package.json'), 'utf8'));
  if (!/^1[56]\./.test(nextPackage.version)) throw new Error(`Next.js ${nextPackage.version} is not supported by this prototype`);
  if (nextPackage.version.startsWith('16.')) {
    const projectWasm = path.join(directory, 'node_modules', '@next', 'swc-wasm-nodejs');
    if (!fs.existsSync(path.join(projectWasm, 'package.json'))) {
      throw new Error(`Next.js ${nextPackage.version} requires matching @next/swc-wasm-nodejs`);
    }
    const wasmPackage = JSON.parse(fs.readFileSync(path.join(projectWasm, 'package.json'), 'utf8'));
    if (wasmPackage.version !== nextPackage.version) {
      throw new Error(`Next.js ${nextPackage.version} requires matching @next/swc-wasm-nodejs`);
    }
  }
  const startPath = path.join(nextRoot, 'dist/server/lib/start-server.js');
  let start = fs.readFileSync(startPath, 'utf8');
  const titleLine = /process\.title = `next-server \(v\$\{[^}]+\}\)`;/;
  if (!titleLine.test(start) && !start.includes('iOS embedded Node: skip process.title')) {
    throw new Error('Could not locate Next.js process.title assignment');
  }
  start = start.replace(titleLine, '/* iOS embedded Node: skip process.title */');
  if (!start.includes('/* iOS embedded Node: stop hook */')) {
    const signalSetup = /if \(!process\.env\.NEXT_MANUAL_SIG_HANDLE\) \{/;
    if (!signalSetup.test(start)) throw new Error('Could not locate Next.js shutdown handler');
    start = start.replace(signalSetup,
      '/* iOS embedded Node: stop hook */ globalThis.__COMPUTEBRIDGE_STOP_NEXT = cleanup;\n                if (!process.env.NEXT_MANUAL_SIG_HANDLE) {');
  }
  fs.writeFileSync(startPath, start);

  const defaultsPath = path.join(nextRoot, 'dist/server/config-shared.js');
  let defaults = fs.readFileSync(defaultsPath, 'utf8');
  if (!defaults.includes('workerThreads: false') && !defaults.includes('workerThreads: true')) {
    throw new Error('Could not locate Next.js workerThreads setting');
  }
  defaults = defaults.replace('workerThreads: false', 'workerThreads: true');
  if (nextPackage.version.startsWith('16.')) {
    if (!defaults.includes('useTypeScriptCli: true') && !defaults.includes('useTypeScriptCli: false')) {
      throw new Error('Could not locate Next.js useTypeScriptCli setting');
    }
    defaults = defaults.replace('useTypeScriptCli: true', 'useTypeScriptCli: false');
  }
  fs.writeFileSync(defaultsPath, defaults);
}

async function uploadProject(request, reply) {
  if (busy || nextWorker || state.phase === 'starting' || state.phase === 'stopping') {
    return respond(reply, 409, { error: 'Project is busy or already running; reopen the app to replace it' });
  }
  busy = true;
  state.phase = 'uploading';
  state.message = 'Receiving project from Mac';
  const archive = path.join(support, 'project-upload-' + crypto.randomUUID() + '.tar.gz');
  const incoming = path.join(support, 'incoming-project');
  try {
    const size = await saveRequest(request, archive, 1024 * 1024 * 1024, bytes => {
      state.message = `Receiving project: ${Math.round(bytes / 1024 / 1024)} MB`;
    });
    state.phase = 'extracting';
    state.message = 'Extracting project on iPhone';
    await fsp.rm(incoming, { recursive: true, force: true });
    await fsp.mkdir(incoming, { recursive: true });
    await tar.x({ file: archive, cwd: incoming, strip: 1, strict: true });
    const packageData = JSON.parse(await fsp.readFile(path.join(incoming, 'package.json'), 'utf8'));
    if (!packageData.scripts?.dev?.includes('next dev')) throw new Error('The selected folder does not use next dev');
    patchNextForIOS(incoming);
    await fsp.rm(project, { recursive: true, force: true });
    await fsp.rename(incoming, project);
    state.phase = 'uploaded';
    state.message = `${packageData.name || 'Next.js project'} uploaded (${Math.round(size / 1024 / 1024)} MB)`;
    respond(reply, 200, { ok: true, name: packageData.name, bytes: size });
  } catch (error) {
    state.phase = 'error';
    state.message = `Upload failed: ${error.message}`;
    respond(reply, 400, { error: state.message });
  } finally {
    busy = false;
    await fsp.rm(archive, { force: true });
  }
}

async function startProject(reply) {
  if ((state.phase !== 'uploaded' && state.phase !== 'stopped') || nextWorker) {
    return respond(reply, 409, { error: 'Upload a project or stop the current server before starting it' });
  }
  state.phase = 'starting';
  state.message = 'Starting Next.js on iPhone';
  respond(reply, 202, { ok: true });
  const generation = ++startGeneration;
  setImmediate(() => {
    if (state.phase !== 'starting' || generation !== startGeneration) return;
    try {
      process.env.NEXT_TELEMETRY_DISABLED = '1';
      process.env.NEXT_TEST_WASM = '1';
      process.env.NODE_ENV = 'development';
      process.env.__NEXT_DEV_SERVER = '1';
      const nextVersion = JSON.parse(fs.readFileSync(path.join(project, 'node_modules', 'next', 'package.json'), 'utf8')).version;
      process.env.NEXT_TEST_WASM_DIR = nextVersion.startsWith('16.')
        ? path.join(project, 'node_modules', '@next', 'swc-wasm-nodejs')
        : wasmDirectory;
      delete process.env.TURBOPACK;
      process.env.WATCHPACK_POLLING = '1000';
      process.chdir(project);
      patchNextForIOS(project);
      const worker = new Worker(path.join(__dirname, 'next-dev-worker.cjs'), {
        workerData: { project }
      });
      nextWorker = worker;
      worker.on('message', message => {
        if (nextWorker !== worker) return;
        if (message.phase === 'ready' && state.phase === 'starting') {
          state.phase = 'ready';
          state.message = 'Next.js ready on port 3001';
        } else if (message.phase === 'error' && state.phase !== 'stopping') {
          state.phase = 'error';
          state.message = `Next.js failed: ${message.message}`;
          worker.terminate().catch(console.error);
        }
      });
      worker.on('error', error => {
        if (nextWorker !== worker) return;
        if (state.phase === 'stopping') return;
        state.phase = 'error';
        state.message = `Next.js failed: ${error.message}`;
        console.error(error);
      });
      worker.on('exit', code => {
        if (nextWorker !== worker) return;
        nextWorker = null;
        process.chdir(support);
        if (state.phase === 'stopping') {
          state.phase = 'stopped';
          state.message = 'Next.js stopped on iPhone';
        } else if (state.phase !== 'error') {
          state.phase = 'error';
          state.message = `Next.js exited with code ${code}`;
        }
      });
    } catch (error) {
      state.phase = 'error';
      state.message = `Next.js failed: ${error.message}`;
      console.error(error);
    }
  });
}

async function stopProject(reply) {
  if (state.phase === 'starting' && !nextWorker) {
    startGeneration++;
    state.phase = 'stopped';
    state.message = 'Next.js stopped on iPhone';
    return respond(reply, 200, { ok: true });
  }
  if (!nextWorker) return respond(reply, 409, { error: 'Next.js is not running' });
  if (state.phase === 'stopping') return respond(reply, 202, { ok: true });
  state.phase = 'stopping';
  state.message = 'Stopping Next.js on iPhone';
  respond(reply, 202, { ok: true });
  const worker = nextWorker;
  try {
    worker.postMessage({ type: 'stop' });
    setTimeout(() => {
      if (nextWorker === worker && state.phase === 'stopping') {
        worker.terminate().catch(console.error);
      }
    }, 10000).unref();
  } catch (error) {
    state.phase = 'error';
    state.message = `Could not stop Next.js: ${error.message}`;
    console.error(error);
  }
}

const server = http.createServer(async (request, reply) => {
  try {
    if (!authorized(request)) return respond(reply, 401, { error: 'Invalid pairing token' });
    const url = new URL(request.url, 'http://localhost');
    if (request.method === 'GET' && url.pathname === '/status') {
      return respond(reply, 200, {
        phase: state.phase,
        message: state.message,
        node: process.version,
        platform: process.platform,
        architecture: process.arch
      });
    }
    if (request.method === 'PUT' && url.pathname === '/project') return await uploadProject(request, reply);
    if (request.method === 'POST' && url.pathname === '/start') return await startProject(reply);
    if (request.method === 'POST' && url.pathname === '/stop') return await stopProject(reply);
    if ((request.method === 'PUT' || request.method === 'DELETE') && url.pathname.startsWith('/file/')) {
      return await sourceFile(request, reply, url.pathname.slice('/file/'.length));
    }
    return respond(reply, 404, { error: 'Unknown endpoint' });
  } catch (error) {
    console.error(error);
    return respond(reply, 500, { error: error.message });
  }
});
server.requestTimeout = 0;
server.listen(3100, '0.0.0.0', () => console.log('ComputeBridge Node runtime listening on port 3100'));
