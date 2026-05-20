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
- **Purpose:** Launches `node --cpu-prof ../server.js` so the V8 CPU profiler is attached for the lifetime of the process, drives sustained load via `autocannon`, then sends `SIGINT` to the server so V8 flushes the profile to disk.
- **Output:** `results/<timestamp>/CPU.<pid>.<timestamp>.cpuprofile` (the filename is emitted by V8; the script collects whatever `*.cpuprofile` files V8 writes into the timestamped results directory).
- **Inspection:** Open the `.cpuprofile` in Chrome DevTools (`chrome://inspect` → Performance → Load) or in Speedscope (`https://www.speedscope.app/`).
- **Approximate duration:** ~45 seconds.

### `profile-heap.sh` — V8 heap profile capture

- **Command:** `./profile-heap.sh`
- **Purpose:** Launches `node --heap-prof ../server.js` so the V8 sampling heap profiler is attached for the lifetime of the process, drives sustained load via `autocannon`, then sends `SIGINT` to the server so V8 flushes the profile to disk.
- **Output:** `results/<timestamp>/Heap.<pid>.<timestamp>.heapprofile` (the filename is emitted by V8).
- **Inspection:** Open the `.heapprofile` in Chrome DevTools (Memory tab → Load profile) or Speedscope.
- **Approximate duration:** ~45 seconds.

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
2. **Launch** — `node ../server.js &` (or `node --cpu-prof ../server.js &` / `node --heap-prof ../server.js &` for the profiling scripts), then `pid=$!` to capture the child PID.
3. **Readiness probe** — poll `curl -s http://127.0.0.1:3000/` until it returns HTTP 200, or until a timeout fires. The startup log line `Server running at http://127.0.0.1:3000/` (per `[server.js:L12-L14]`) is an additional readiness signal that scripts may tail from server stdout.
4. **Drive load** — invoke `npx autocannon` with the parameters for the active scenario.
5. **Shutdown** — `kill -INT "$pid"` (`SIGINT`) so V8 flushes any pending profile files; `wait "$pid"` to reap the child.
6. **Collect artifacts** — move/copy any emitted `*.cpuprofile` / `*.heapprofile` files into `results/<timestamp>/`.

## Profiling Overhead

The Node.js flags `--cpu-prof` and `--heap-prof` attach V8 sampling profilers to the process for the lifetime of the run. These profilers add measurable but bounded overhead to the profiled process: CPU sampling introduces a sub-millisecond interrupt at a fixed sampling rate, and heap profiling records a stack trace at each sampled allocation site. The latency and throughput numbers produced while these flags are active are therefore **profiled** numbers, not production numbers. Measurements taken with `run-baseline.sh` (which does **not** enable these flags) are the canonical baseline for latency and throughput; measurements taken with `profile-cpu.sh` or `profile-heap.sh` are interpretive — they identify where time and memory are spent, not how fast the unprofiled server runs. This labelling convention mirrors AAP §0.5.4.

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
