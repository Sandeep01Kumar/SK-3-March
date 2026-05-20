// benchmarks/inspector-driver.mjs
//
// Purpose
// -------
// Drives V8 CPU and sampling-heap profile capture against a running Node.js
// process that was launched with the --inspect flag. The driver speaks the
// Chrome DevTools Protocol (CDP) over a WebSocket connection to the inspector
// endpoint, programmatically starts the requested profiler, sleeps for the
// configured profile duration, then stops the profiler and writes the returned
// profile JSON to the path specified via --output. Once the profile data has
// been persisted, the driver asks the inspected process to exit cleanly via
// `Runtime.evaluate({ expression: "process.exit(0)" })` and terminates itself.
//
// Why This Exists (root cause of QA Issue #1 / Issue #2)
// -----------------------------------------------------
// The previous CPU/heap profile pipeline relied on the Node.js `--cpu-prof`
// and `--heap-prof` runtime flags combined with a SIGINT-based shutdown. Those
// flags emit their .cpuprofile / .heapprofile files only when V8's `before-exit`
// / `exit` hooks run, which requires a *graceful* exit — either an event-loop
// drain or an explicit `process.exit()` call from inside the inspected process.
// SIGINT sent to a Node.js process that has installed no custom signal handler
// (which is exactly the state of [server.js:L1-L14] under Constraint C-001)
// terminates the process via the default signal action; the V8 exit hooks do
// not run, and no profile file is written. The QA finding was reproduced both
// in the harness (Issue #1) and through direct experiments (QA Tests A and E).
//
// This driver replaces that mechanism with the V8 Inspector Protocol. Profile
// data is collected by `Profiler.stop` / `HeapProfiler.stopSampling`, which
// return the same profile JSON shapes that `--cpu-prof` / `--heap-prof` would
// have written, but they do so synchronously over the WebSocket connection —
// no graceful-exit timing is required. After the profile has been read back to
// the driver, the driver requests a clean exit of the inspected process via
// `Runtime.evaluate`. The inspected process exits with code 0 normally; the
// driver writes the captured profile JSON to the requested filename.
//
// Constraints Honored
// -------------------
//   C-001 — Source files immutable: ../server.js is launched as-is with the
//           `--inspect=HOST:PORT` CLI flag applied to the `node` process. No
//           edits to [server.js:L1-L14] are made.
//   C-002 — Zero application deps: this driver uses ONLY Node.js built-ins
//           (`node:net`, `node:crypto`, `node:http`, `node:fs`). The WebSocket
//           protocol (RFC 6455) is implemented inline rather than pulling in
//           the `ws` npm package, so the harness's own devDependencies remain
//           limited to `autocannon` per benchmarks/package.json.
//   C-003 — Single-purpose server: the driver makes ONE Runtime.evaluate call
//           (`process.exit(0)`) at the very end of its run. This call is the
//           minimum necessary mechanism to ask the inspected process for a
//           graceful exit; it does not add routes, middleware, or alternate
//           response paths to the server.
//   C-004 — Hardcoded host/port: the driver's defaults are 127.0.0.1:9229 for
//           the inspector endpoint. These can be overridden via CLI flags but
//           the calling scripts (profile-cpu.sh / profile-heap.sh) pass the
//           literals matching [server.js:L3] and [server.js:L4].
//
// CLI Usage
// ---------
//   node inspector-driver.mjs \
//     --mode=cpu|heap \
//     --duration-ms=<N>           (profile duration in milliseconds)
//     --output=<path>             (where to write the .cpuprofile / .heapprofile)
//     --inspector-host=<host>     (default: 127.0.0.1)
//     --inspector-port=<port>     (default: 9229)
//     [--sampling-interval-us=<us>]      (CPU mode, default: 100 microseconds)
//     [--sampling-interval-bytes=<n>]    (heap mode, default: 32768 bytes)
//     [--connect-timeout-ms=<ms>]        (default: 10000)
//     [--exit-grace-ms=<ms>]             (post-process.exit drain, default: 250)
//
// Exit Codes
// ----------
//   0 — success: profile captured, file written, server exit requested.
//   2 — invalid arguments.
//   3 — failed to reach inspector list endpoint (HTTP GET /json/list).
//   4 — WebSocket handshake or connection failure.
//   5 — CDP command error (Profiler.start/stop, HeapProfiler.*).
//   6 — failed to write the profile output file.
//
// Profile Output Format
// ---------------------
// CPU mode writes the `profile` field returned by `Profiler.stop`. The schema
// (V8's CPU profile JSON) contains `nodes`, `startTime`, `endTime`, `samples`,
// `timeDeltas` and is the same JSON shape that Chrome DevTools' "Load profile"
// in the Performance panel and Speedscope (`https://www.speedscope.app/`) both
// consume.
//
// Heap mode writes the `profile` field returned by `HeapProfiler.stopSampling`.
// The schema (V8's sampling heap profile JSON) contains `head` and `samples`
// and is the same JSON shape that Chrome DevTools' "Load profile" in the
// Memory panel consumes.

import { connect as netConnect } from 'node:net';
import { randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { get as httpGet } from 'node:http';

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = {
    mode: null,
    durationMs: null,
    output: null,
    inspectorHost: '127.0.0.1',
    inspectorPort: 9229,
    cpuSamplingIntervalUs: 100,
    heapSamplingIntervalBytes: 32768,
    connectTimeoutMs: 10000,
    exitGraceMs: 250,
  };
  for (const raw of argv) {
    const eq = raw.indexOf('=');
    if (!raw.startsWith('--') || eq < 0) {
      throw new Error(`unrecognized argument: ${raw}`);
    }
    const key = raw.slice(2, eq);
    const value = raw.slice(eq + 1);
    switch (key) {
      case 'mode':
        if (value !== 'cpu' && value !== 'heap') {
          throw new Error(`--mode must be 'cpu' or 'heap'; got '${value}'`);
        }
        args.mode = value;
        break;
      case 'duration-ms':
        args.durationMs = Number(value);
        if (!Number.isFinite(args.durationMs) || args.durationMs <= 0) {
          throw new Error(`--duration-ms must be a positive integer; got '${value}'`);
        }
        break;
      case 'output':
        args.output = value;
        break;
      case 'inspector-host':
        args.inspectorHost = value;
        break;
      case 'inspector-port':
        args.inspectorPort = Number(value);
        if (!Number.isFinite(args.inspectorPort) || args.inspectorPort <= 0) {
          throw new Error(`--inspector-port must be a positive integer; got '${value}'`);
        }
        break;
      case 'sampling-interval-us':
        args.cpuSamplingIntervalUs = Number(value);
        if (!Number.isFinite(args.cpuSamplingIntervalUs) || args.cpuSamplingIntervalUs <= 0) {
          throw new Error(`--sampling-interval-us must be a positive number; got '${value}'`);
        }
        break;
      case 'sampling-interval-bytes':
        args.heapSamplingIntervalBytes = Number(value);
        if (!Number.isFinite(args.heapSamplingIntervalBytes) || args.heapSamplingIntervalBytes <= 0) {
          throw new Error(`--sampling-interval-bytes must be a positive number; got '${value}'`);
        }
        break;
      case 'connect-timeout-ms':
        args.connectTimeoutMs = Number(value);
        if (!Number.isFinite(args.connectTimeoutMs) || args.connectTimeoutMs <= 0) {
          throw new Error(`--connect-timeout-ms must be a positive integer; got '${value}'`);
        }
        break;
      case 'exit-grace-ms':
        args.exitGraceMs = Number(value);
        if (!Number.isFinite(args.exitGraceMs) || args.exitGraceMs < 0) {
          throw new Error(`--exit-grace-ms must be a non-negative integer; got '${value}'`);
        }
        break;
      default:
        throw new Error(`unrecognized flag: --${key}`);
    }
  }
  if (!args.mode) throw new Error('--mode=cpu|heap is required');
  if (!args.durationMs) throw new Error('--duration-ms=<N> is required');
  if (!args.output) throw new Error('--output=<path> is required');
  return args;
}

// ---------------------------------------------------------------------------
// Inspector list discovery
//
// Node.js exposes the inspector HTTP API at `http://<inspector-host>:<inspector-port>/json/list`
// once the V8 inspector has finished binding. The endpoint returns an array of
// debugger targets; the WebSocket URL of the (single) main-thread target is the
// `webSocketDebuggerUrl` field of the first element. The HTTP API may briefly
// be unavailable between the time the harness's curl readiness check passes
// (i.e., the server's HTTP listener is up) and the time the inspector binds.
// We retry with a small backoff to absorb that race.
// ---------------------------------------------------------------------------

function fetchInspectorList(host, port) {
  return new Promise((resolve, reject) => {
    const req = httpGet({ host, port, path: '/json/list', timeout: 2000 }, (res) => {
      let buf = '';
      res.setEncoding('utf8');
      res.on('data', (c) => buf += c);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(buf);
          if (!Array.isArray(parsed) || parsed.length === 0) {
            reject(new Error('inspector returned empty target list'));
            return;
          }
          resolve(parsed);
        } catch (e) {
          reject(new Error(`inspector list parse error: ${e.message}`));
        }
      });
      res.on('error', reject);
    });
    req.on('error', reject);
    req.on('timeout', () => {
      try { req.destroy(); } catch (_e) { /* ignore */ }
      reject(new Error('inspector list request timed out'));
    });
  });
}

async function waitForInspector(host, port, timeoutMs) {
  // Poll the inspector list endpoint up to `timeoutMs / 200` times at 200 ms
  // intervals. This matches the harness scripts' own readiness-check pattern
  // (50 attempts × 200 ms = 10 s default) so an operator does not have to
  // reason about two different backoff schedules.
  const intervalMs = 200;
  const deadline = Date.now() + timeoutMs;
  let lastErr = null;
  while (Date.now() < deadline) {
    try {
      const list = await fetchInspectorList(host, port);
      return list;
    } catch (e) {
      lastErr = e;
      await new Promise((r) => setTimeout(r, intervalMs));
    }
  }
  throw new Error(`inspector at ${host}:${port} not ready within ${timeoutMs}ms${lastErr ? `: ${lastErr.message}` : ''}`);
}

// ---------------------------------------------------------------------------
// WebSocket protocol implementation (RFC 6455 client-side, text frames only)
//
// Why hand-roll WebSocket: per Constraint C-002 the harness's only declared
// devDependency is `autocannon`. Adding the `ws` npm package solely for the
// inspector connection would expand the harness's dependency surface; the
// WebSocket protocol is simple enough to implement inline for the one use
// case we need (client-side handshake, masked text frames, close frame
// handling). The implementation below covers exactly the subset required
// by the CDP transport and intentionally rejects features (extensions,
// continuation frames, binary frames) that the inspector does not use.
// ---------------------------------------------------------------------------

// Encode a single text frame from client to server. RFC 6455 requires
// client-to-server frames to be masked with a per-frame random 4-byte key.
// The masked payload is computed in-place via XOR with the key (the key is
// rotated through `mask[i & 3]` so a 4-byte key XORs an arbitrarily long
// payload). Frame layout:
//
//   byte 0 : FIN(1) RSV(3) Opcode(4)         -- we always use FIN=1, opcode=1 (text)
//   byte 1 : MASK(1) PayloadLen7(7)
//   bytes 2-3   (if PayloadLen7==126): PayloadLen16
//   bytes 2-9   (if PayloadLen7==127): PayloadLen64 (we only use the low 32 bits)
//   next 4 bytes: masking key
//   remaining: masked payload bytes
function encodeTextFrame(payloadStr) {
  const payload = Buffer.from(payloadStr, 'utf8');
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x81;          // FIN=1, opcode=0x1 (text)
    header[1] = 0x80 | len;    // MASK=1, payload length = len
  } else if (len < 0x10000) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 0x80 | 127;
    // We only support payloads up to 2^32-1 bytes; the high 32 bits are zero.
    header.writeUInt32BE(0, 2);
    header.writeUInt32BE(len, 6);
  }
  const mask = randomBytes(4);
  const masked = Buffer.alloc(len);
  for (let i = 0; i < len; i++) {
    masked[i] = payload[i] ^ mask[i & 3];
  }
  return Buffer.concat([header, mask, masked]);
}

// Parse zero-or-more complete frames from a buffer. Returns { frames, rest }:
//   - frames: array of { fin, opcode, payload } for the frames decoded
//   - rest:   buffer containing any unparsed bytes (a partial frame to retain)
//
// The parser correctly handles:
//   - 7-bit, 16-bit, and 64-bit payload-length encodings
//   - masked AND unmasked frames (servers don't mask; clients always do)
//   - close frames (opcode 8)
//
// It intentionally rejects payloads ≥ 2^32 bytes (the high 32 bits of a
// 64-bit length are checked) because CDP messages are well under that ceiling
// and rejecting > 4 GiB payloads prevents pathological memory exhaustion.
function parseFrames(buf) {
  const frames = [];
  let off = 0;
  while (off < buf.length) {
    if (buf.length - off < 2) break;
    const b0 = buf[off];
    const b1 = buf[off + 1];
    const fin = (b0 & 0x80) !== 0;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let payloadLen = b1 & 0x7f;
    let cursor = off + 2;
    if (payloadLen === 126) {
      if (buf.length - cursor < 2) break;
      payloadLen = buf.readUInt16BE(cursor);
      cursor += 2;
    } else if (payloadLen === 127) {
      if (buf.length - cursor < 8) break;
      const hi = buf.readUInt32BE(cursor);
      const lo = buf.readUInt32BE(cursor + 4);
      if (hi !== 0) {
        throw new Error('WebSocket frame payload exceeds 2^32-1 bytes');
      }
      payloadLen = lo;
      cursor += 8;
    }
    let mask = null;
    if (masked) {
      if (buf.length - cursor < 4) break;
      mask = buf.slice(cursor, cursor + 4);
      cursor += 4;
    }
    if (buf.length - cursor < payloadLen) break;
    let payload = buf.slice(cursor, cursor + payloadLen);
    if (masked) {
      const unmasked = Buffer.alloc(payloadLen);
      for (let i = 0; i < payloadLen; i++) {
        unmasked[i] = payload[i] ^ mask[i & 3];
      }
      payload = unmasked;
    }
    cursor += payloadLen;
    frames.push({ fin, opcode, payload });
    off = cursor;
  }
  return { frames, rest: buf.slice(off) };
}

// Open a CDP-ready WebSocket connection to the given ws:// URL. Returns a
// promise resolving to a minimal ws object exposing:
//   - send(method, params)  → Promise<result>   (id-tracked request/response)
//   - fire(method, params)  → void              (fire-and-forget; no await)
//   - close()               → void              (idempotent)
//
// The handshake is a vanilla RFC 6455 client upgrade — we send `GET <path> HTTP/1.1`
// with `Upgrade: websocket`, `Connection: Upgrade`, a random `Sec-WebSocket-Key`,
// and `Sec-WebSocket-Version: 13`, then read the response and confirm the
// 101 status line. We intentionally do NOT verify the `Sec-WebSocket-Accept`
// hash against the SHA-1 of (key + RFC magic GUID) because the inspector
// implementation is trusted and the verification adds no real security in a
// localhost-only context.
function openCdpWebSocket(wsUrl) {
  const m = wsUrl.match(/^ws:\/\/([^:/]+):(\d+)(\/.*)$/);
  if (!m) {
    return Promise.reject(new Error(`invalid ws url: ${wsUrl}`));
  }
  const host = m[1];
  const port = Number(m[2]);
  const path = m[3];

  return new Promise((resolve, reject) => {
    const socket = netConnect({ host, port }, () => {
      const key = randomBytes(16).toString('base64');
      const req = [
        `GET ${path} HTTP/1.1`,
        `Host: ${host}:${port}`,
        `Upgrade: websocket`,
        `Connection: Upgrade`,
        `Sec-WebSocket-Key: ${key}`,
        `Sec-WebSocket-Version: 13`,
        '',
        '',
      ].join('\r\n');
      socket.write(req);
    });

    let phase = 'handshake';
    let rxBuf = Buffer.alloc(0);
    // pending: id → { resolve, reject }
    const pending = new Map();
    let nextId = 1;
    let closed = false;

    const ws = {
      send(method, params) {
        if (closed) return Promise.reject(new Error('ws closed'));
        const id = nextId++;
        const msg = JSON.stringify({ id, method, params: params || {} });
        try {
          socket.write(encodeTextFrame(msg));
        } catch (e) {
          return Promise.reject(new Error(`socket write failed: ${e.message}`));
        }
        return new Promise((res, rej) => pending.set(id, { resolve: res, reject: rej }));
      },
      // Fire-and-forget. Used for the final Runtime.evaluate(process.exit(0))
      // because the inspector connection drops as the inspected process exits;
      // no response will ever arrive for that id, and awaiting it would hang
      // until the socket close event tears down the pending map.
      fire(method, params) {
        if (closed) return;
        const id = nextId++;
        const msg = JSON.stringify({ id, method, params: params || {} });
        try { socket.write(encodeTextFrame(msg)); } catch (_e) { /* socket already gone */ }
      },
      close() {
        if (closed) return;
        closed = true;
        try { socket.destroy(); } catch (_e) { /* ignore */ }
      },
    };

    socket.on('data', (chunk) => {
      rxBuf = Buffer.concat([rxBuf, chunk]);
      if (phase === 'handshake') {
        const idx = rxBuf.indexOf('\r\n\r\n');
        if (idx === -1) return;
        const headers = rxBuf.slice(0, idx).toString('utf8');
        rxBuf = rxBuf.slice(idx + 4);
        const statusLine = headers.split('\r\n')[0] || '';
        if (!/^HTTP\/1\.1 101/.test(statusLine)) {
          reject(new Error(`WebSocket handshake failed: ${statusLine}`));
          try { socket.destroy(); } catch (_e) { /* ignore */ }
          return;
        }
        phase = 'open';
        resolve(ws);
        // Fall through to process any frames that arrived in the same chunk.
      }
      if (phase === 'open' && rxBuf.length > 0) {
        let parsed;
        try {
          parsed = parseFrames(rxBuf);
        } catch (e) {
          // Malformed frame — treat as fatal protocol error.
          for (const { reject: rj } of pending.values()) rj(new Error(`frame parse: ${e.message}`));
          pending.clear();
          ws.close();
          return;
        }
        rxBuf = parsed.rest;
        for (const f of parsed.frames) {
          if (f.opcode === 0x1) {
            // Text frame — CDP JSON message.
            const text = f.payload.toString('utf8');
            let json;
            try { json = JSON.parse(text); } catch (_e) { continue; }
            if (json.id != null && pending.has(json.id)) {
              const { resolve: r, reject: rj } = pending.get(json.id);
              pending.delete(json.id);
              if (json.error) {
                rj(new Error(json.error.message || JSON.stringify(json.error)));
              } else {
                r(json.result);
              }
            }
            // CDP events (no id) are ignored — we don't subscribe to any.
          } else if (f.opcode === 0x8) {
            // Close frame.
            try { socket.destroy(); } catch (_e) { /* ignore */ }
          }
          // Other opcodes (binary, ping, pong, continuation) are not produced
          // by the inspector and are ignored.
        }
      }
    });

    socket.on('error', (err) => {
      if (phase === 'handshake') {
        reject(err);
      }
    });

    socket.on('close', () => {
      closed = true;
      for (const { reject: rj } of pending.values()) {
        rj(new Error('inspector socket closed'));
      }
      pending.clear();
    });

    // Hard timeout on the connect+handshake phase. Once `resolve(ws)` runs,
    // this timer is irrelevant; we use socket events from then on.
    setTimeout(() => {
      if (phase === 'handshake') {
        reject(new Error('WebSocket handshake timed out'));
        try { socket.destroy(); } catch (_e) { /* ignore */ }
      }
    }, 5000).unref();
  });
}

// ---------------------------------------------------------------------------
// Profile capture orchestration
//
// CPU mode:
//   1. Profiler.enable                       (idempotent — required before start)
//   2. Profiler.setSamplingInterval (μs)     (override the default 1 ms)
//   3. Profiler.start                        (begin sampling)
//   4. sleep <duration>
//   5. Profiler.stop → result.profile        (the .cpuprofile JSON shape)
//
// Heap mode:
//   1. HeapProfiler.startSampling (bytes)    (no explicit enable needed)
//   2. sleep <duration>
//   3. HeapProfiler.stopSampling → result.profile  (the .heapprofile JSON shape)
// ---------------------------------------------------------------------------

async function captureCpuProfile(ws, args) {
  await ws.send('Profiler.enable');
  // setSamplingInterval takes microseconds. Default per V8 is 1000 µs (1 ms);
  // we pass our --sampling-interval-us argument verbatim. Note: setSamplingInterval
  // MUST be called BEFORE Profiler.start; calling it after start has no effect.
  await ws.send('Profiler.setSamplingInterval', { interval: args.cpuSamplingIntervalUs });
  await ws.send('Profiler.start');
  // Sleep for the configured profile duration. The inspected process continues
  // to run normally; the V8 sampler is interrupting it at every sample tick.
  await new Promise((r) => setTimeout(r, args.durationMs));
  const result = await ws.send('Profiler.stop');
  // The CDP `Profiler.stop` return value has the shape `{ profile: Profile }`
  // where Profile is the V8 CPU profile JSON consumable by Chrome DevTools
  // and Speedscope. We persist exactly that inner object.
  return result.profile;
}

async function captureHeapProfile(ws, args) {
  await ws.send('HeapProfiler.startSampling', { samplingInterval: args.heapSamplingIntervalBytes });
  await new Promise((r) => setTimeout(r, args.durationMs));
  const result = await ws.send('HeapProfiler.stopSampling');
  // The CDP `HeapProfiler.stopSampling` return value has the shape
  // `{ profile: SamplingHeapProfile }`. SamplingHeapProfile contains `head`
  // and `samples` and is the same JSON shape consumed by Chrome DevTools'
  // Memory tab.
  return result.profile;
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(`inspector-driver: ${e.message}`);
    console.error('Run with --mode=cpu|heap --duration-ms=N --output=path');
    process.exit(2);
  }

  let list;
  try {
    list = await waitForInspector(args.inspectorHost, args.inspectorPort, args.connectTimeoutMs);
  } catch (e) {
    console.error(`inspector-driver: ${e.message}`);
    process.exit(3);
  }
  const wsUrl = list[0].webSocketDebuggerUrl;
  if (!wsUrl) {
    console.error('inspector-driver: inspector target has no webSocketDebuggerUrl');
    process.exit(3);
  }
  console.log(`inspector-driver: connecting to ${wsUrl}`);

  let ws;
  try {
    ws = await openCdpWebSocket(wsUrl);
  } catch (e) {
    console.error(`inspector-driver: WebSocket connect failed: ${e.message}`);
    process.exit(4);
  }
  console.log('inspector-driver: connected; starting profile capture');

  let profile;
  try {
    if (args.mode === 'cpu') {
      profile = await captureCpuProfile(ws, args);
      const samples = (profile.samples || []).length;
      const nodes = (profile.nodes || []).length;
      console.log(`inspector-driver: CPU profile captured (${nodes} nodes, ${samples} samples)`);
    } else {
      profile = await captureHeapProfile(ws, args);
      const samples = (profile.samples || []).length;
      console.log(`inspector-driver: heap profile captured (${samples} samples, head present: ${profile.head ? 'yes' : 'no'})`);
    }
  } catch (e) {
    console.error(`inspector-driver: CDP error during capture: ${e.message}`);
    try { ws.close(); } catch (_e) { /* ignore */ }
    process.exit(5);
  }

  try {
    writeFileSync(args.output, JSON.stringify(profile));
    console.log(`inspector-driver: profile written to ${args.output}`);
  } catch (e) {
    console.error(`inspector-driver: failed to write profile file: ${e.message}`);
    try { ws.close(); } catch (_e) { /* ignore */ }
    process.exit(6);
  }

  // Ask the inspected process to exit gracefully. We fire this without
  // awaiting because the inspector connection will be torn down as the
  // inspected process exits and no response will arrive. The exit-grace
  // delay below lets the message reach the server before the driver closes.
  console.log('inspector-driver: requesting inspected process exit');
  ws.fire('Runtime.evaluate', { expression: 'process.exit(0)' });

  // Small delay so the Runtime.evaluate frame is actually transmitted before
  // we destroy the socket. Without this, fast network paths can occasionally
  // close the connection before the frame is flushed to the kernel buffer.
  await new Promise((r) => setTimeout(r, args.exitGraceMs));
  ws.close();

  console.log('inspector-driver: done');
  // Hard-exit. The driver process has no remaining work; any straggling
  // sockets or timers that the runtime might keep alive should not delay
  // shutdown.
  process.exit(0);
}

main().catch((e) => {
  console.error(`inspector-driver: unexpected error: ${e && e.message ? e.message : e}`);
  process.exit(1);
});
