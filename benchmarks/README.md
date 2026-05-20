# Benchmarks

This directory contains the performance-measurement harness for `../server.js`. The harness is a **separate Node.js package**, isolated from the application's root `package.json` per Constraint **C-002** (AAP §0.7); its dev-dependencies resolve only inside `benchmarks/node_modules/` and never bubble to the application package. All measurement is **observational** — `../server.js` is never modified, never instrumented, and never patched, per Constraint **C-001** (AAP §0.7). The harness reaches the server exclusively through its public HTTP/1.1 interface on `http://127.0.0.1:3000/` and through the filesystem path `../server.js` (read-only).

## Prerequisites

Before running any script in this directory, confirm that the host satisfies the following:

- **Node.js** — a currently supported LTS line: 20.x maintenance LTS, 22.x maintenance LTS, or 24.x active LTS (AAP §0.8.2 / `[Section "Node.js Version Compatibility"]`). The scripts honor `benchmarks/package.json`'s `engines.node` field (`>=20.0.0`).
- **npm** — bundled with Node.js. Used only to install harness dev-dependencies into `benchmarks/node_modules/`.
- **POSIX-compatible shell (bash)** — the orchestration scripts are bash scripts and are required to run on a POSIX shell per AAP §0.8.2 ("Compatibility requirement"). They have not been validated against non-POSIX shells (e.g., PowerShell, fish).
- **Free TCP port `3000` on `127.0.0.1`** — the server binds to loopback hostname `127.0.0.1` per `[server.js:L3]` and port `3000` per `[server.js:L4]`. A second instance of `../server.js` (or any other process holding port 3000) will fail with `EADDRINUSE`, per Assumption **A-002** (AAP §0.7). Each script performs a pre-flight port-availability check before launching the server.
- **`lsof` or `ss`** — used by the orchestrator scripts (notably `run-baseline.sh`) for the port pre-flight check. Either tool is sufficient; the scripts detect whichever is present.
- **`curl`** — used by all scripts as the readiness probe against `http://127.0.0.1:3000/` after launching the server in the background.
- **`autocannon`** — installed automatically into `benchmarks/node_modules/` by `npm install` (declared in `benchmarks/package.json`). The scripts invoke it via `npx autocannon`, so a global install is **not** required.

## Installation

Install the harness's isolated dev-dependencies:

```bash
cd benchmarks
npm install
```

> **IMPORTANT** — `npm install` MUST be run from inside the `benchmarks/` directory. Running `npm install` at the repository root would be a no-op against the application's empty root `package.json` per `[package-lock.json:L6-L11]` (the `packages` map contains only the root package and zero resolved dependencies) and would not install any of the harness's tools.

The above command populates `benchmarks/node_modules/` and writes `benchmarks/package-lock.json`. The application's root `package.json` and root `package-lock.json` remain byte-identical — this isolation is the explicit guarantee of AAP §0.4.2 and the operational meaning of Constraint **C-002**.

## Quick Start

Run the latency/throughput baseline against the running server:

```bash
cd benchmarks
npm install            # one-time
./run-baseline.sh
```

The first run creates a timestamped directory under `results/` (e.g., `results/1716200000/`) containing the JSON output produced by `autocannon` (one file per concurrency rung) and the captured server `stderr`. The directory layout is documented under [Result Layout](#result-layout) below.

## Scripts

Each script in this directory is documented below. All scripts are designed to be invoked from inside the `benchmarks/` directory.

### `run-baseline.sh` — Latency / throughput baseline orchestrator

- **Command:** `./run-baseline.sh`
- **Purpose:** Drives `autocannon` against `http://127.0.0.1:3000/` over the concurrency ladder defined in `load-profile.json` — 1 → 10 → 100 → 1000 simultaneous connections, with a 30-second sustained window per rung and a 10-second warm-up window that is discarded.
- **Output:** `results/<timestamp>/autocannon-1.json`, `autocannon-10.json`, `autocannon-100.json`, `autocannon-1000.json`, and `results/<timestamp>/server.stderr.log`.
- **Approximate duration:** ~3 minutes (4 rungs × 30 s sustained + 4 × 10 s warm-up + inter-rung quiesce).

### `profile-cpu.sh` — V8 CPU profile capture

- **Command:** `./profile-cpu.sh`
- **Purpose:** Launches `node --inspect=127.0.0.1:9229 ../server.js` (exposing the V8 Inspector socket on the loopback interface), runs the `inspector-driver.mjs` helper which uses the V8 Chrome DevTools Protocol (`Profiler.enable` → `Profiler.start` → `Profiler.stop`) to capture a CPU profile, drives sustained load via `autocannon` in parallel, then asks the inspected process to exit cleanly via `Runtime.evaluate(process.exit(0))`. The driver writes the captured profile data to disk; the script verifies a non-empty `.cpuprofile` was produced and exits non-zero (code 5) if not.
- **Output:** `results/<timestamp>/CPU.<YYYYMMDD>.<HHMMSS>.<server_pid>.0.001.cpuprofile` (filename pattern matches V8's `--cpu-prof` default so downstream tooling globbing for `CPU.*.cpuprofile` keeps working). The driver's own log lands at `results/<timestamp>/inspector-driver.log`.
- **Inspection:** Open the `.cpuprofile` in Chrome DevTools (`chrome://inspect` → Performance → Load) or in Speedscope (`https://www.speedscope.app/`).
- **Approximate duration:** ~35 seconds.

### `profile-heap.sh` — V8 heap profile capture

- **Command:** `./profile-heap.sh`
- **Purpose:** Launches `node --inspect=127.0.0.1:9229 ../server.js` (exposing the V8 Inspector socket on the loopback interface), runs the `inspector-driver.mjs` helper which uses the V8 Chrome DevTools Protocol (`HeapProfiler.startSampling` → `HeapProfiler.stopSampling`) to capture a sampling heap profile, drives sustained load via `autocannon` in parallel, then asks the inspected process to exit cleanly via `Runtime.evaluate(process.exit(0))`. The driver writes the captured profile data to disk; the script verifies a non-empty `.heapprofile` was produced and exits non-zero (code 5) if not.
- **Output:** `results/<timestamp>/Heap.<YYYYMMDD>.<HHMMSS>.<server_pid>.0.001.heapprofile` (filename pattern matches V8's `--heap-prof` default). The driver's own log lands at `results/<timestamp>/inspector-driver.log`.
- **Inspection:** Open the `.heapprofile` in Chrome DevTools (Memory tab → Load profile).
- **Approximate duration:** ~35 seconds.

### `measure-event-loop-lag.sh` — Event-loop lag sampler

- **Command:** `./measure-event-loop-lag.sh`
- **Purpose:** Launches `node ../server.js`, starts a separate helper Node process that samples event-loop delay at fixed intervals using `perf_hooks.monitorEventLoopDelay()`, drives sustained `autocannon` load against `http://127.0.0.1:3000/`, and writes one CSV row per sampling interval. Per Constraint **C-001**, the helper samples its **own** event loop and is **not** injected into `../server.js`; the sampled lag therefore approximates system-wide event-loop pressure under load rather than the server process's exact event-loop lag.
- **Output:** `results/<timestamp>/event-loop-lag.csv`.
- **Approximate duration:** ~60 seconds.

## Result Layout

All scripts write under `benchmarks/results/`. The structure is:

```
results/
├── .gitkeep                     # committed; preserves directory
└── <unix-timestamp>/            # NOT committed; environment-specific
    ├── autocannon-1.json
    ├── autocannon-10.json
    ├── autocannon-100.json
    ├── autocannon-1000.json
    ├── server.stderr.log
    ├── CPU.<pid>.*.cpuprofile
    ├── Heap.<pid>.*.heapprofile
    └── event-loop-lag.csv
```

Only `results/.gitkeep` is tracked in version control. Every timestamped subdirectory is intentionally excluded — its contents are environment-specific (CPU, kernel, Node.js minor version, concurrent host load) and the binary profile artifacts may be very large. This matches AAP §0.8.2: the implementing agent must NOT commit binary profile artifacts under version control.

## Constraints

The four governance constraints below are absolute (AAP §0.7). Every script and every recommendation in `docs/performance/` was designed around them; operators should not work around them without first obtaining owner approval and lifting the corresponding constraint in the codebase's governance contract.

- **C-001 (Do not touch!)** — The harness only reads `../server.js` via its filesystem path and only interacts with the running process through its public HTTP/1.1 interface. No source-code modification, instrumentation, or patching of `../server.js` is performed. The application's root `README.md`, `package.json`, `package-lock.json`, and `server.js` remain byte-identical before and after every harness run.
- **C-002 (Zero application dependencies)** — The single dev-dependency (`autocannon`) is declared only in `benchmarks/package.json` and resolves only into `benchmarks/node_modules/`. The application's root `package.json` and root `package-lock.json` are never modified. This boundary is why `npm install` must be run from inside `benchmarks/` and never at the repository root. AAP §0.4 lists `clinic` and `0x` as *optional* additional dev-dependencies; this checkpoint deliberately omits them because their dependency graphs currently include packages with critical and high severity npm-audit findings (e.g., `request`/`form-data`). If a future checkpoint adopts audit-clean alternatives, they can be reintroduced under explicit security review.
- **C-003 (Single-purpose server)** — The harness uses only the existing single endpoint exposed by `../server.js`: `GET /` returning `text/plain` body `"Hello, World!\n"` (per `[server.js:L6-L10]`). The harness does not add routes, middleware, alternate response paths, a `/health` endpoint, a `/metrics` endpoint, or any conditional behavior to the server.
- **C-004 (Hardcoded configuration)** — Hostname `127.0.0.1` and port `3000` are read as constants from the values hardcoded in `[server.js:L3]` and `[server.js:L4]`. The harness does not introduce environment variables, `.env` files, or runtime parameters that would parameterize the server's host, port, or response body. If the constants in `../server.js` ever change, the harness scripts and `load-profile.json` would also need updating — but that change would itself violate C-001.

## How the harness launches the server

Every script launches the server with the literal command `node ../server.js &` (bash background) — **not** with `npm start` and **not** with `require('hello_world')`. The rationale is:

- **No `start` script exists.** `[package.json:L6-L8]` declares only a single placeholder `test` script (`echo "Error: no test specified" && exit 1`). There is no `start` script, no `dev` script, and no `bench` script. Adding one would modify the application's root `package.json` and violate **C-001**.
- **`require('hello_world')` would fail.** `[package.json:L5]` declares `"main": "index.js"`, but `index.js` does not exist in the repository. This is the accepted inconsistency **KI-002** (AAP §0.7 and §0.4.3). The harness honors this gap rather than resolving it — resolving it would require creating `index.js`, which is outside the scope of this analysis work.

The lifecycle each script follows is:

1. **Pre-flight check** — verify TCP port 3000 is free on `127.0.0.1`; abort with a clear operator message if not.
2. **Launch** — `node ../server.js &` (for `run-baseline.sh`), `node --inspect=127.0.0.1:9229 ../server.js &` (for the profile scripts so the V8 Inspector socket is available for CDP-based profile capture), or `node ../server.js &` (for `measure-event-loop-lag.sh` since the lag sampler runs in a separate helper process). After launch, `pid=$!` captures the child PID.
3. **Readiness probe** — poll `curl -s http://127.0.0.1:3000/` until it returns HTTP 200, or until a timeout fires. The startup log line `Server running at http://127.0.0.1:3000/` (per `[server.js:L12-L14]`) is an additional readiness signal that scripts may tail from server stdout.
4. **Drive load** — invoke `npx autocannon` with the parameters for the active scenario. For the profile scripts, `inspector-driver.mjs` is launched in parallel with `autocannon` so the V8 CPU / heap profiler is sampling for the entirety of the autocannon load window.
5. **Shutdown** — for `run-baseline.sh` and `measure-event-loop-lag.sh`: `kill -INT "$pid"` and `wait "$pid"` to reap the server cleanly. For the profile scripts: `inspector-driver.mjs` issues `Runtime.evaluate({expression: "process.exit(0)"})` via the V8 Inspector Protocol so the server exits gracefully without relying on signal-handling timing; the harness then runs `wait "$pid"`. SIGINT remains the fallback in the cleanup trap and is also used to reap the harness's own background subprocesses (the inspector driver and the event-loop-lag sampler).
6. **Collect artifacts** — `inspector-driver.mjs` writes the `.cpuprofile` / `.heapprofile` directly to `results/<timestamp>/`. Other artifacts (autocannon JSON, manifests, server logs, sampler scripts) are written to that directory by the orchestrator scripts themselves.

The four scripts share the same `trap` discipline. Each registers three handlers — `trap 'cleanup' EXIT`, `trap 'cleanup; exit 130' INT`, `trap 'cleanup; exit 143' TERM` — and the `cleanup` body is idempotent via a `CLEANUP_DONE` guard. This guarantees that a script interrupted by SIGINT exits with the canonical 130 code (signal 2) so CI / automation can distinguish operator interruption from clean completion; a script interrupted by SIGTERM exits 143; and a script that completes successfully exits 0. The previous trap pattern (`trap cleanup EXIT INT TERM` with `cleanup` ending in `exit "$rc"`) captured the exit code of the last completed command instead of the signal-induced exit code, so interrupted runs falsely reported 0 — this was QA Issue #3 and is fixed in the current revision.

## V8 Inspector Protocol — Why It Replaces `--cpu-prof` / `--heap-prof`

Earlier revisions of `profile-cpu.sh` and `profile-heap.sh` launched the server with V8's `--cpu-prof` / `--heap-prof` runtime flags and used `SIGINT` for shutdown. The V8 flags emit their profile artifacts only when the process exits *gracefully* — either by event-loop drain or by a `process.exit()` call — because the file write happens inside V8's `before-exit` / `exit` hooks. When SIGINT is delivered to a Node.js process that has installed no custom signal handler (which is exactly the state of `[server.js:L1-L14]` under Constraint **C-001**, the "Do not touch!" rule from `[README.md:L2]`), the default signal action terminates the process and the V8 exit hooks do NOT run. The result was that the previous profile scripts ran to completion, exited 0, and produced no `.cpuprofile` / `.heapprofile` artifact — QA found this empirically (Issues #1 and #2) and verified the V8 behavior with direct experiments.

The current implementation replaces the V8 flags with the V8 Inspector Protocol. `node --inspect=127.0.0.1:9229 ../server.js` exposes V8's debugging interface on the loopback interface; the harness's `inspector-driver.mjs` helper connects via WebSocket and speaks the Chrome DevTools Protocol (CDP). The CDP `Profiler.stop` and `HeapProfiler.stopSampling` commands return the profile JSON synchronously over the inspector connection — no graceful-exit timing is required. After the driver has the profile bytes safely on disk, it issues `Runtime.evaluate({expression: "process.exit(0)"})` so the server exits cleanly. The output profile files use the same `CPU.<date>.<pid>.<id>.<seq>.cpuprofile` / `Heap.<date>.<pid>.<id>.<seq>.heapprofile` naming pattern that V8's flags would have produced, so Chrome DevTools, Speedscope, and any downstream tooling continue to work without changes.

The driver uses **only** Node.js built-in modules (`node:net`, `node:crypto`, `node:http`, `node:fs`); the WebSocket protocol (RFC 6455) is implemented inline. This preserves Constraint **C-002**: the harness's only declared devDependency remains `autocannon` per `benchmarks/package.json`. The end-to-end mechanism — `--inspect` flag (a Node.js runtime flag, not a source modification) + the inspector-driver helper (lives entirely under `benchmarks/`) + the standard `Runtime.evaluate` CDP call — satisfies every governance constraint (C-001 through C-004) without relaxation.

This is QA-recommended **Option C** ("READY — no constraint relaxation needed") from the QA report's resolution suggestions for Issues #1 and #2.

## Profiling Overhead

The V8 Inspector connection samples the running JavaScript stack at the configured sampling interval (100 µs for CPU profiles in the current driver configuration, well above the V8 default of 1 ms — set explicitly in `inspector-driver.mjs` to capture higher-resolution stacks against the static-response handler). The CPU sampler introduces a sub-millisecond interrupt at each tick; the heap sampler records a stack trace at each sampled allocation site (default 32768 bytes between samples). The latency and throughput numbers produced while these profilers are active are therefore **profiled** numbers, not production numbers. Measurements taken with `run-baseline.sh` (which uses a vanilla `node ../server.js` launch with no `--inspect` flag and no profiler attached) are the canonical baseline for latency and throughput; measurements taken with `profile-cpu.sh` or `profile-heap.sh` are interpretive — they identify where time and memory are spent, not how fast the unprofiled server runs. This labelling convention mirrors AAP §0.5.4.

## Known Gaps

The harness measures only what the application actually does: serve a fixed `text/plain` response from a single endpoint. It does **not** measure any of the following user-requested workflow categories, because none of the corresponding subsystems exist in the application (AAP §0.1.4 and §0.3.2):

- **Authentication flows** — no authentication mechanism exists.
- **Dashboard rendering** — no UI surface exists; the response is `text/plain`, not HTML.
- **File upload / download operations** — `../server.js` never reads the request body and never performs file I/O.
- **Database query performance** — no database, driver, or ORM exists.
- **Third-party integrations** — zero outbound network connections.
- **Frontend rendering** (including redundant re-renders) — no client-side rendering surface exists.
- **Background job execution** — no queues, workers, or schedulers exist.

For the canonical evidence behind each absence and the methodology decision flowing from each, see `docs/performance/02-workflow-gap-analysis.md`. Each dimension chapter under `docs/performance/` defers to that gap analysis whenever it touches one of these categories.
