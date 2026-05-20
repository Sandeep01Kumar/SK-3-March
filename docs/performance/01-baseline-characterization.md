# Baseline Characterization

This chapter walks through every line of `[server.js:L1-L14]` and identifies the application's hot path: the request handler at `[server.js:L6-L10]`. It is the canonical description of the code path under analysis; every other chapter that references the application's runtime behaviour defers to the per-line table and the hot-path enumeration below. The full application code is 14 lines per `[server.js:L1-L14]` — there are no other source files in the repository. Notably, no `index.js` exists despite `[package.json:L5]`'s `"main": "index.js"` declaration; this is documented inconsistency KI-002 per `[Section 2.6.3]` and accepted (not fixed) per AAP §0.7. The harness therefore launches the server with `node ../server.js` rather than `require('hello_world')` or `npm start`.

## The Complete Source

The following is the complete, byte-identical content of `[server.js:L1-L14]`:

```javascript
const http = require('http');

const hostname = '127.0.0.1';
const port = 3000;

const server = http.createServer((req, res) => {
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain');
  res.end('Hello, World!\n');
});

server.listen(port, hostname, () => {
  console.log(`Server running at http://${hostname}:${port}/`);
});
```

Anyone reproducing the measurements in subsequent chapters MUST verify that the contents of `server.js` on disk match the block above before publishing or quoting any benchmark result. Per Constraint C-001 (`[README.md:L2]`, `[Section 2.6.2]`), the file is immutable; any drift from the block above indicates a violation of the governance directive and invalidates the analysis.

## Per-Line Walk-Through

The table below enumerates every line of `[server.js:L1-L14]` exactly once and in order. The **Cost** column distinguishes one-time work (module load or startup) from per-request work (the hot path).

| Line | Code | Role | Cost |
|------|------|------|------|
| 1 | `const http = require('http');` | Loads Node.js built-in HTTP module | One-time at module load |
| 2 | (blank) | Spacing | None |
| 3 | `const hostname = '127.0.0.1';` | Loopback bind address (Constraint C-004) | One-time |
| 4 | `const port = 3000;` | TCP port literal (Constraint C-004) | One-time |
| 5 | (blank) | Spacing | None |
| 6 | `const server = http.createServer((req, res) => {` | Constructs HTTP server with inline request handler | One-time at module load |
| 7 | `  res.statusCode = 200;` | Sets response status (per request) | Per request |
| 8 | `  res.setHeader('Content-Type', 'text/plain');` | Sets response header (per request) | Per request |
| 9 | `  res.end('Hello, World!\n');` | Writes 14-byte body and terminates response (per request) | Per request |
| 10 | `});` | Closes server constructor | None |
| 11 | (blank) | Spacing | None |
| 12 | `server.listen(port, hostname, () => {` | Binds to port; registers startup callback | One-time |
| 13 | ``  console.log(`Server running at http://${hostname}:${port}/`); `` | Emits startup confirmation | One-time at startup |
| 14 | `});` | Closes listen callback | None |

Three cost categories emerge from the table. The **module-load cost** is paid exactly once per process start and covers `[server.js:L1]` (`require('http')`), `[server.js:L6]` (the `http.createServer` call), and `[server.js:L12]` (the `server.listen` call). The **per-request cost** is paid on every inbound HTTP request and covers lines 7, 8, and 9 inside the handler at `[server.js:L6-L10]` — three operations: assign status, set one header, write body. The **per-startup cost** is paid exactly once when the server begins listening and covers only `[server.js:L13]` (the `console.log` confirmation).

## Hot Path

The only repeating code path in the application is the request handler at `[server.js:L6-L10]`. Within that handler, lines 7, 8, and 9 execute exactly once per HTTP request. There is no other code that runs more than once per process start.

What the hot path does **not** do is equally important for interpreting the CPU and memory profiles in chapter 04:

- **No request parsing**: `req.url`, `req.method`, `req.headers`, and `req.body` are never read. This is explicit in `[Section 5.1.3]`: "No data from the incoming request — method, path, headers, or body — is read, evaluated, or stored." The Node.js HTTP parser still parses the inbound request line and headers internally, but the JavaScript handler never inspects the result.
- **No branching**: there is no `if`, `switch`, ternary, or conditional anywhere in `[server.js:L6-L10]`. Every request gets the same 200/`text/plain`/`Hello, World!\n` response.
- **No async/await**: the handler is synchronous. `res.end` returns immediately; the kernel may buffer the write at the socket layer, but the JavaScript handler does not await it.
- **No allocation in the handler body**: the response body string `'Hello, World!\n'` at `[server.js:L9]` is a compile-time literal that V8 interns and reuses across invocations.
- **No external calls**: no database, no outbound HTTP client, no filesystem I/O, no third-party service. Per `[Section 3.4.1]` and `[Section 5.1.4]`, the application has zero outbound integrations.

The implication for profiling is that the hot path produces the simplest possible HTTP-server CPU profile achievable in Node.js. On-CPU samples are concentrated in Node.js's HTTP parser (`llhttp`), the JavaScript wrapper functions invoked by `res.statusCode = …`, `res.setHeader(…)`, and `res.end(…)`, and the socket write path inside the libuv/`net` layer. Chapter 04 ("CPU and Memory Profile") interprets the captured flame graph against this expectation.

## Module Load Footprint

The single `require('http')` at `[server.js:L1]` loads Node.js's built-in HTTP module from the Node binary itself; no npm packages are loaded because none exist. This is confirmed empirically by `[package-lock.json:L6-L11]`, which shows an empty `packages` map containing only the root `""` self-entry. There is no `dotenv` load, no `config/*` file read, and no environment-variable parsing per `[Section 2.4.1]` (Constraint C-004 mandates hardcoded configuration). There is also no transpilation, no bundling, and no ahead-of-time compilation per `[Section 3.6.2]`, because no build system is defined.

The implication for startup is that process initialization is bounded by Node.js's own startup time (roughly 30–100 ms on modern hardware) plus the time to bind TCP port 3000 and emit the startup `console.log`. Per `[Section 4.7.3]`'s SLA of "startup ≤ 1 s", there is significant headroom — at least an order of magnitude — between the measured startup time and the budget.

## Runtime Baseline Footprint

Per `[Section "Node.js Version Compatibility"]`, a typical Node.js process serving a static handler at idle uses approximately 30–50 MB of resident set size (RSS). This is the floor: an idle process holding nothing more than the Node binary, the V8 heap, the libuv event loop, and the listening socket. Under load, each accepted TCP connection consumes on the order of ~10 KB for libuv-side bookkeeping plus the transient JavaScript `IncomingMessage` and `ServerResponse` objects allocated per request. Rough projections (to be verified empirically in chapter 04) are: ~40–80 MB at concurrency c=100, ~60–150 MB at c=1000. These ranges are inferred from common Node.js HTTP-server behaviour on Node.js 20.x and not yet measured against this specific application.

The implementing agent running the harness should confirm the actual idle RSS by sampling `ps -o rss= -p <pid>` immediately after the server emits "Server running at http://127.0.0.1:3000/" and before any load is applied. That measurement is the canonical baseline; the projections above are advisory until replaced with measured values in chapter 04.

## Single Integration Point

Per `[Section 5.1.4]`, the application has exactly one integration point: the inbound HTTP listener on `127.0.0.1:3000` defined at `[server.js:L3]`, `[server.js:L4]`, and bound at `[server.js:L12]`. The loopback binding at `[server.js:L3]` is exhaustive — there is no `0.0.0.0` fallback, no IPv6 socket, no Unix domain socket. There are no outbound integrations of any kind per `[Section 3.4.1]` and `[Section 5.1.4]`: no database driver, no HTTP client, no message-queue client, no third-party SDK. The application is, in the language of Constraint C-003 (`[Section 2.6.2]`), a "single-purpose static-response endpoint", and the integration topology is correspondingly minimal.

## Manifests

The application's `[package.json:L1-L11]` declares the project name as `hello_world` per `[package.json:L2]`, the description as "Hello world in Node.js" per `[package.json:L4]`, and the entry-point file as `index.js` per `[package.json:L5]` — but no `index.js` exists in the repository. This is the documented inconsistency KI-002 catalogued in `[Section 2.6.3]` and accepted (not to be fixed) per AAP §0.7. The consequence is that `require('hello_world')` cannot resolve the package entry point, which is why the benchmark harness invokes the server via the filesystem path `node ../server.js` rather than via module require. The `scripts` block contains only the `test` entry per `[package.json:L6-L8]`, and that entry is a placeholder that prints "Error: no test specified" and exits with code 1. Crucially, there are no `dependencies` and no `devDependencies` keys at all in the manifest — confirming the zero-dependency posture mandated by Constraint C-002 (`[Section 2.6.2]`).

The lockfile `[package-lock.json:L1-L13]` declares lockfileVersion 3 per `[package-lock.json:L4]` and an empty `packages` map containing only the root `""` self-entry per `[package-lock.json:L6-L11]`. The empirical implication is that `npm install` against this lockfile is a no-op: it resolves nothing, downloads nothing, and produces no `node_modules/` directory. This is consistent with the zero-dependency posture of the manifest and is the reason no dependency-scanning, supply-chain-audit, or transitive-vulnerability discussion appears in the rest of this performance report.

## Repository Governance

The repository's `[README.md:L1-L2]` contains exactly two lines: the repository title `# hao-backprop-test` at `[README.md:L1]` and the directive "test project for backprop integration. Do not touch!" at `[README.md:L2]`. The second line is the textual origin of Constraint C-001 (`[Section 2.6.2]`) — the immutability directive that every recommendation in this performance report defers to. This entire analysis is observational rather than transformational specifically because of `[README.md:L2]`: no source modification is performed, no instrumentation is injected into `[server.js:L1-L14]`, and every optimization recommendation in chapter 09 that would entail editing `server.js`, `package.json`, `package-lock.json`, or `README.md` is tagged ADVISORY-C001 to surface the governance prerequisite to reviewers.
