# Load Profile and Methodology

This chapter defines the methodology used to produce every number in chapters 04 ("CPU and Memory Profile"), 05 ("Latency and Throughput"), 06 ("Event Loop and Concurrency"), and 07 ("Network Latency"). It is the **reproducibility contract** of this performance report — a reviewer with access only to this chapter and the `[../../benchmarks/](../../benchmarks/)` harness must be able to re-execute the entire measurement campaign and obtain results that match the published numbers to within the natural variance of the host environment (CPU model, kernel version, Node.js minor version). The user provided no example workflows, latency targets, or named tools (per AAP §0.1.3 and §0.5.3); the methodology therefore defaults to standard HTTP-benchmark practice as captured below. Every parameter in this chapter has either a direct citation back to the source files (`[server.js:L1-L14]`, `[package.json:L1-L11]`, `[package-lock.json:L1-L13]`), a specific tech-spec section reference (for example `[Section 5.1.3]` for the data-flow invariant, `[Section 5.2.1]` for the single-threaded event loop, `[Section 1.3.2]` for the explicit out-of-scope list, or `[Section 2.6.1]` for assumptions A-001 through A-004), or the machine-readable harness configuration at `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)`; nothing is fabricated.

## Target System Under Test

The target of every measurement in this report is a single instance of the `hao-backprop-test` application launched with no profiling flags (for chapters 05–07) or with one V8 diagnostic flag (`--cpu-prof` for chapter 04, `--heap-prof` for chapter 04). The application's runtime characteristics are fixed by `[server.js:L1-L14]` and are summarized here so that every downstream chapter cites this single block rather than re-deriving them independently:

- **Process**: a single Node.js process running `[server.js:L1-L14]` — CommonJS, built-in `http` module loaded at `[server.js:L1]`, no framework, no middleware, no third-party packages.
- **Endpoint**: `GET http://127.0.0.1:3000/`. This is the only endpoint that exists; per `[Section 5.1.3]`, "No data from the incoming request — method, path, headers, or body — is read, evaluated, or stored," so any method against any path produces the identical response.
- **Bind address**: `127.0.0.1` (loopback) per `[server.js:L3]`. All load is generated from the same host because the server does not accept remote connections (per ADR-003, `[Section 6.5.7]`).
- **Port**: `3000` per `[server.js:L4]`. The port is a hardcoded literal per Constraint C-004 (`[Section 2.6.2]`); no environment-variable override exists.
- **Response**: `200 OK`, `Content-Type: text/plain`, body `'Hello, World!\n'` — a 14-byte compile-time constant per `[server.js:L7-L9]`.
- **Concurrency model**: single-threaded JavaScript event loop per `[Section 5.2.1]`. No `cluster`, no `worker_threads`, no thread pool used by user code (libuv's internal thread pool exists but is not exercised by the handler at `[server.js:L6-L10]`).
- **Process model**: single instance per Assumption A-002 (`[Section 2.6.1]`). A second instance of `../server.js` would fail with `EADDRINUSE` on port 3000; horizontal scaling is therefore structurally impossible without first lifting C-001/C-004 (this is documented in chapter 10 and tagged ADVISORY in chapter 09).
- **Dependencies**: zero. The application's resolved dependency graph is empty per `[package-lock.json:L6-L11]`'s empty `packages` map, and the application's manifest declares no `dependencies` and no `devDependencies` per `[package.json:L1-L11]`. The benchmark harness is a **separate** package under `[../../benchmarks/](../../benchmarks/)` with its own manifest at `[../../benchmarks/package.json](../../benchmarks/package.json)`; per Constraint C-002 (`[Section 2.6.2]`), no harness dependency may be added to the application's root `package.json`.

The implication for every downstream measurement is that the system under test is the simplest possible HTTP server expressible in Node.js. Any "optimization" mentioned in this report cannot reduce the body size (it is already a 14-byte literal), cannot remove a framework (none exists), and cannot remove a database round-trip (none exists). The methodology below targets the only dimensions where measurement is meaningful: per-request latency at varying concurrency, sustained throughput, event-loop lag under load, and CPU/memory profile under load.

## Concurrency Ladder

The harness drives the server through a fixed four-rung **concurrency ladder**: `1 → 10 → 100 → 1000` simultaneous open TCP connections. Per AAP §0.5.3, this ladder is the canonical methodology default; it is not extended, narrowed, or re-spaced in this report. Chapter 09 ("Optimization Recommendations") may propose extensions as READY recommendations for future runs, but the published numbers in chapters 04–07 use exactly the four rungs below.

| Rung | Connections | Scenario name in `load-profile.json` | Notes |
|------|-------------|--------------------------------------|-------|
| c=1 | 1 | `c1` | Single-connection baseline; isolates per-request latency from concurrency effects. The numbers from this rung are the floor against which all higher-rung latencies are compared. |
| c=10 | 10 | `c10` | Low concurrency; representative of light interactive load. Sufficient to populate tail-percentile buckets meaningfully but well below any structural saturation point. |
| c=100 | 100 | `c100` | Mid-tier concurrency; representative of typical sustained service load. The p99.9 percentile becomes statistically stable at this rung's sample size. |
| c=1000 | 1000 | `c1000` | High concurrency; exercises the TCP listen-backlog (Node.js default 511 per the `http.Server` documentation) and the host's per-process file-descriptor limit. The saturation behaviour observed here is interpreted in chapter 06. |

These four rungs match the four `scenarios` entries in `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)` exactly. The machine-readable harness configuration is the **authoritative source of truth**; if a future change to that file modifies the ladder, this chapter MUST be updated to match (per AAP §0.6.4 "Documentation consistency needs") or the harness MUST be reverted to agree with this chapter. The two artifacts MUST agree numerically.

The ladder is **geometric** (each rung is 10× the previous) rather than arithmetic. The rationale is that the qualitative behaviour at each tier — single-connection baseline, light interactive, mid-tier sustained, near-saturation — is what the measurements characterize; a fine-grained sweep (e.g., 1, 2, 5, 10, 20, 50, 100, 200, 500, 1 000) would multiply wall-clock time by ~3× without changing any qualitative finding. Operators who need a finer sweep can extend `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)` and re-run the harness; the methodology in this chapter would still apply unchanged to each new rung.

## Duration and Warm-up

Every rung is run with the following three time windows, in order:

- **Warm-up duration per rung**: **10 seconds** (data discarded). Matches `meta.warmup_discard_seconds = 10` and each scenario's `warmup: 10` field in `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)`.
- **Sustained-measurement duration per rung**: **30 seconds** (data retained). Matches each scenario's `duration: 30` field in `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)`.
- **Inter-rung quiesce**: **2 seconds**, between consecutive rungs. Matches `meta.inter_rung_quiesce_seconds = 2` in `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)`.

Total wall-clock per full ladder is therefore `4 × (10 + 30) + 3 × 2 = 166` seconds, plus the startup readiness poll (≤ 10 seconds, see "Server Lifecycle" below) and the graceful-shutdown wait (≤ a few seconds). The published `run-baseline.sh` is approximately 3 minutes per the `[../../benchmarks/README.md](../../benchmarks/README.md)`'s "Approximate duration" statement.

The rationale for each window:

- **The 10-second warm-up** lets V8 tier-up the request handler from the interpreter to the Sparkplug (baseline) compiler and then to TurboFan (the optimizing compiler). Modern V8 begins promoting hot functions to TurboFan after a few thousand invocations; at autocannon's typical sustained RPS for a static handler, 10 seconds easily clears that threshold for the handler at `[server.js:L6-L10]`. Discarding the warm-up window prevents tier-up jitter from polluting the latency tail.
- **The 30-second measurement window** provides a sample size sufficient for stable tail-percentile estimates at all four concurrency rungs (see "Sample-Size Targets" below). It is long enough that transient host effects (a sudden GC pause, a kernel scheduler hiccup) are averaged out, and short enough that the full ladder completes in a single operator session.
- **The 2-second inter-rung quiesce** lets the kernel drain TCP buffers, time-wait sockets begin recycling, and the autocannon worker fully terminate before the next rung's connection storm begins. Without this gap, the c=10 rung's tail-recycle activity would bleed into the c=100 rung's connection-establishment phase and corrupt the latter's connect-time measurements.

The warm-up window is **discarded** rather than reported separately. The harness's autocannon invocation runs once per rung for the sustained 30 seconds (autocannon itself does not natively support discarding a leading interval), so the orchestrator at `../../benchmarks/run-baseline.sh` (deferred to a later checkpoint per AAP §0.6.1) drives a separate 10-second warm-up pass against the same endpoint before the measured 30-second pass. The published numbers therefore reflect only the measured window; the warm-up pass produces no committed JSON output.

## Sample-Size Targets

Each rung has an **expected minimum sample size** below which the harness emits a warning. The targets are sized to make the highest reported percentile (p99.9) statistically stable; for a target percentile `p`, a rule-of-thumb minimum is `≥ 10 / (1 − p)` independent samples, which for `p = 0.999` gives `≥ 10 000` samples. The c=100 and c=1000 rungs target `≥ 100 000` samples to provide an order of magnitude beyond this floor.

| Rung | Expected min samples | `expected_min_samples` in `load-profile.json` | Rationale |
|------|---------------------|------------------------------------------------|-----------|
| c=1  | 1 000 | `1000`     | Small but non-trivial — p99 stable, p99.9 noisier than higher rungs. The c=1 baseline characterizes per-request latency in the absence of concurrency, where head-of-line blocking on the single connection caps achievable RPS to roughly the reciprocal of the per-request mean latency. |
| c=10 | 10 000 | `10000`   | Tail percentiles meaningful through p99.9. Ten parallel connections sustain enough RPS that 30 seconds easily produces tens of thousands of samples. |
| c=100 | 100 000 | `100000` | p99.9 statistically stable. The mid-tier concurrency at sustained RPS comfortably produces the target sample count within the 30-second window on any modern host. |
| c=1000 | 100 000 | `100000` | **Capped — at this concurrency, FD/backlog limits, not application throughput, are the dominant constraint.** The expected-min count is intentionally the same as c=100; the qualitative finding at this rung is the saturation behaviour (connection refusals, listen-backlog drops, event-loop lag spikes), not raw throughput. Chapter 06 interprets the c=1000 numbers against this expectation. |

These expected minimums match the `expected_min_samples` field on each scenario in `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)` exactly. The actual sample count realized on the measurement host appears in each rung's autocannon JSON output (the `requests.total` field) and is recorded in `run-manifest.json` (see "Environmental Recording" below). If the actual count falls below the expected minimum, the harness emits a warning to `stderr` so that the operator can adjudicate before publishing the numbers; a low actual count usually indicates that the host failed to deliver the expected RPS (often because of a runaway background process or kernel-level throttling).

## Request Mix

The request mix is **`GET / only`** for every rung of every scenario. This is the only endpoint that exists in the application — per `[Section 5.1.3]`, "No data from the incoming request — method, path, headers, or body — is read, evaluated, or stored," so the choice of method, path, and headers is structurally irrelevant; any combination produces the identical 200 / `text/plain` / `Hello, World!\n` response. The harness uses `GET /` because it is the conventional default for HTTP benchmarking and matches what autocannon emits when no other method or path is supplied. The `meta.request_method` and `meta.request_path` fields in `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)` codify `GET` and `/` as the canonical request method and path; `meta.request_mix` records the verbatim string `GET / only`.

Other request-shape variations are explicitly excluded from this baseline methodology:

- **No request bodies**. Per `[Section 1.3.2]`, request bodies are never read by the application. Sending a body would force the kernel and Node.js's HTTP parser to allocate read buffers, but the application's JavaScript handler still would not inspect the result; the measured CPU and memory impact would reflect parser overhead rather than handler behaviour. The baseline therefore omits request bodies.
- **No custom request headers** beyond what `autocannon` emits by default — typically `Host: 127.0.0.1:3000`, `Connection: keep-alive`, `User-Agent: <autocannon version>`. The exact header set used in a given run is recorded indirectly via the autocannon version field of `run-manifest.json` (see below); a future autocannon release that alters default headers would change the wire footprint slightly, which is one reason the harness records the autocannon version per run.
- **No keep-alive vs. no-keep-alive A/B**. The harness uses autocannon's default — keep-alive **on**. The single-purpose Node.js HTTP server accepts keep-alive connections without any configuration. A no-keep-alive variant would force a fresh TCP handshake per request and would dominate the measured latency with three-way-handshake cost; that is a different measurement (and is briefly discussed in chapter 07) and not the baseline.
- **No HTTP/1.1 pipelining**. The harness uses autocannon's default `pipelining` factor of 1 (each connection issues one outstanding request at a time, awaiting the response before sending the next). The application's handler at `[server.js:L6-L10]` is synchronous and Node.js's HTTP server supports pipelining transparently, but pipelining changes the latency arithmetic in a way that is more characteristic of the client driver than the server — and is therefore deferred to a future scenario.
- **No request-body variants**. There is exactly one shape on the wire per request: the autocannon-default GET line and minimal header set. The c=N rungs differ only in how many such requests are in flight simultaneously.

## Reporting Fields

For each measured rung, the harness records the following fields:

- **Latency** (milliseconds): `p50`, `p95`, `p99`, `p99.9`, `max`, `mean`, `stddev`. The p50, p95, p99, and p99.9 fields are the canonical percentiles for chapter 05 ("Latency and Throughput") and appear as `latency_p50_ms`, `latency_p95_ms`, `latency_p99_ms`, and `latency_p99_9_ms` in the `meta.reporting_fields` list of `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)`. The `max`, `mean`, and `stddev` fields are autocannon defaults and are retained without being designated canonical — they appear in the JSON for context but are not the headline numbers in chapter 05.
- **Throughput**: `requests` (total over the measured window), `rps` (mean requests per second), `bytes/sec` (mean bytes per second). The `rps` and `throughput_bytes_per_sec` fields are designated canonical in `meta.reporting_fields`.
- **Errors**: `non-2xx count`, `timeouts`, `socket errors`. The `non_2xx_count` field is canonical per `meta.reporting_fields`; the other two are autocannon-emitted defaults. In a fully successful run against the static handler at `[server.js:L6-L10]` all three are zero — any non-zero value indicates either backlog saturation at c=1000 (connection refusals → `socket errors`) or a host-level resource issue.
- **Connection-level**: `sockets opened`, `connections successful`. Recorded for diagnostics in case the c=1000 rung shows the host's effective concurrency to be below the requested 1000 (e.g., because of an `EMFILE` limit).

All these fields are emitted by `autocannon -j` (autocannon's machine-readable JSON output) and captured to `benchmarks/results/<timestamp>/autocannon-<N>.json`, where `<N>` is the connection count for the rung (i.e., `autocannon-1.json`, `autocannon-10.json`, `autocannon-100.json`, `autocannon-1000.json`). The exact JSON-key shape inside each file is whatever the autocannon major version pinned in `[../../benchmarks/package.json](../../benchmarks/package.json)`'s `devDependencies` emits (currently `^8.0.0`, i.e., autocannon 8.x); the canonical `latency_p99_9_ms`, `rps`, and similar names declared in `meta.reporting_fields` are the **semantic** field names referenced by chapter 05, not the literal JSON path inside autocannon's output.

## Pre-Flight Checks

Before launching the server and the load generator, the orchestrator at `../../benchmarks/run-baseline.sh` (deferred to a later checkpoint per AAP §0.6.1) performs the following pre-flight checks. If any required check fails, the harness exits **without** starting the server, so a botched run cannot leave a dangling process on the host. The exit codes below are the same shape used by the existing diagnostic scripts at `[../../benchmarks/profile-heap.sh](../../benchmarks/profile-heap.sh)` and `[../../benchmarks/measure-event-loop-lag.sh](../../benchmarks/measure-event-loop-lag.sh)`:

- **`node` is on `$PATH`**. The orchestrator runs `command -v node`. If absent, exit code **2** with a message advising installation of Node.js `>= 20.0.0` (the value of `engines.node` in `[../../benchmarks/package.json](../../benchmarks/package.json)`).
- **`../server.js` exists at the expected location**. The orchestrator tests for `-f $BENCH_DIR/../server.js`. If absent, exit code **2**. This guards against running the harness from the wrong working directory.
- **`load-profile.json` exists**. The orchestrator tests for `-f $BENCH_DIR/load-profile.json`. If absent, exit code **2**. The harness refuses to invent a ladder if its declarative source of truth is missing.
- **`benchmarks/node_modules/.bin/autocannon` exists**. The orchestrator invokes autocannon via `npx --no-install autocannon` so the binary must already be installed by a prior `npm install` inside `[../../benchmarks/](../../benchmarks/)`. If absent, exit code **2** with a message recommending `npm install` from inside `benchmarks/` (and explicitly NOT from the repository root, per Constraint C-002 — see `[../../benchmarks/README.md](../../benchmarks/README.md)`'s "Installation" section).
- **Port 3000 is free**. Tested via `lsof -iTCP:3000 -sTCP:LISTEN`, falling back to `ss -ltn '( sport = :3000 )'` if `lsof` is unavailable, falling back to a tiny Node.js TCP-probe if neither is on `PATH`. If a process is already bound to port 3000, exit code **3**. This guards against the documented `EADDRINUSE` failure of a second instance per Assumption A-002 (`[Section 2.6.1]`).
- **`ulimit -n` ≥ 65535**. A **warning**, not an error: the harness emits a `stderr` message recommending `ulimit -n 65535` if the current per-process soft limit on open file descriptors is below 65535. The 65535 threshold matches the canonical FD-pressure recommendation **R2** in `[09-optimization-recommendations.md](./09-optimization-recommendations.md)` ("Raise the process file-descriptor limit before measurement"). The c=1000 rung needs 1000+ sockets simultaneously open from autocannon (plus a few hundred from the server's `accept` queue and from libuv's internal pipes); a 1024 default ulimit on some Linux distributions can cause spurious `EMFILE` errors and corrupt the c=1000 measurement, and even intermediate ulimits (4096, 8192, 16384) leave less headroom than the documented R2 baseline. The warning is non-fatal because lower-rung scenarios (c=1, c=10, c=100) still run correctly on a tight ulimit.

The readiness probe (curl-polling `http://127.0.0.1:3000/`) is documented under "Server Lifecycle" below; its failure exit code is **4**, not 2 or 3.

## OS-Process Sampling Cadence

The **baseline harness** (`../../benchmarks/run-baseline.sh`, deferred to a later checkpoint per AAP §0.6.1) does not sample `ps` or `pidstat` at fixed intervals during each rung. The published baseline numbers in chapter 05 are autocannon-internal — client-observed latency, RPS, and byte throughput — and do not include in-rung RSS or CPU% snapshots of the server process. This is the methodology's deliberate scope choice for the baseline: keep the harness simple and let the diagnostic scripts (heap-profile, CPU-profile, event-loop-lag) carry the in-rung resource-sampling responsibility.

This chapter records a READY recommendation (carried forward into chapter 09) that the baseline harness be extended to sample RSS and CPU at a **1-second cadence** during each rung's measured window, via `ps -o rss=,pcpu= -p $SERVER_PID` or `pidstat -r -u -p $SERVER_PID 1`. Such an extension would not require modifying `../server.js`, would not add any application dependency, and would not change the published latency/RPS numbers — it would supplement them with a per-rung memory-and-CPU trace. The recommendation is READY because all three of the constraints C-001, C-002, and C-003 remain satisfied; the only change is to add a sampler subprocess inside the harness package.

The diagnostic harnesses **do** sample at fixed intervals:

- `[../../benchmarks/profile-heap.sh](../../benchmarks/profile-heap.sh)` launches the server with `node --heap-prof ../server.js`, which directs V8 to periodically sample allocation sites and emit a `Heap.<pid>.<id>.<seq>.<thread>.heapprofile` on graceful shutdown. The sampling cadence is V8's internal default; the resulting profile is interpreted in chapter 04.
- `[../../benchmarks/measure-event-loop-lag.sh](../../benchmarks/measure-event-loop-lag.sh)` runs a separate helper Node process that calls `perf_hooks.monitorEventLoopDelay()` at a fixed interval (200 ms by default, per the helper's `SAMPLE_INTERVAL_MS` constant) and writes one CSV row per tick; the helper also issues an HTTP probe to `http://127.0.0.1:3000/` at each tick and records the probe RTT. The output is interpreted in chapter 06.

A CPU-profile harness analogous to the heap-profile harness — launching the server with `node --cpu-prof ../server.js`, driving sustained load via autocannon, then SIGINTing for profile emission — completes the trio. Its CPU-profile artifact is interpreted in chapter 04.

## Server Lifecycle

Every harness script in `[../../benchmarks/](../../benchmarks/)` follows the same server-lifecycle sequence. The orchestrator at `../../benchmarks/run-baseline.sh` (deferred to a later checkpoint per AAP §0.6.1) is the canonical implementation; the diagnostic harnesses mirror it.

1. **Launch the server in the background**. The orchestrator runs `node ../server.js &` (a plain shell background, no `nohup` so the parent shell still owns the child PID). For the diagnostic harnesses, the `node` invocation includes the appropriate V8 flag (`--cpu-prof`, `--heap-prof`). The harness does **not** use `npm start` because no `start` script exists in the application's `package.json` per `[package.json:L6-L8]` (the only declared script is the placeholder `test` script); the harness does **not** use `require('hello_world')` because that would fail per documented inconsistency KI-002 (`[Section 1.3.3]`, `[Section 2.6.3]`) — the manifest declares `"main": "index.js"` at `[package.json:L5]` but no `index.js` exists in the repository. The harness's choice of `node ../server.js` is therefore the only correct invocation pattern. The shell pattern used is `node ../server.js > server.stdout.log 2> server.stderr.log &` so that the startup `console.log` from `[server.js:L13]` is captured and so that any later runtime error appears in `server.stderr.log` rather than mixing into the harness's own stdout.

2. **Capture `$!` as the server PID**. Stored in a `SERVER_PID` shell variable. The cleanup `trap` registered immediately after the launch references `SERVER_PID` so that if the harness is interrupted by SIGINT or SIGTERM, the server is shut down cleanly rather than being orphaned.

3. **Curl-poll `http://127.0.0.1:3000/` for up to 10 seconds**. The orchestrator runs `curl -fsS --max-time 1 http://127.0.0.1:3000/` in a loop with 0.2-second sleeps for up to 50 attempts (10 seconds total budget). On the first successful 2xx response, the readiness wait ends and the rung loop begins. If the budget is exhausted without a successful probe, the harness exits with code **4** and the captured `server.stderr.log` is the diagnostic of choice.

4. **Run each rung**. For each scenario in `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)`:
   - run the 10-second warm-up pass (autocannon at the rung's `connections` value, duration 10 s, output discarded);
   - run the 30-second measured pass (autocannon at the rung's `connections` value, duration 30 s, output captured to `autocannon-<N>.json`);
   - sleep for the 2-second inter-rung quiesce before the next rung.

5. **Graceful shutdown**. After the last rung, the orchestrator sends `kill -INT $SERVER_PID` and then `wait "$SERVER_PID"` to block until the server exits. **SIGINT (not SIGKILL)** is required when the server was launched with `--cpu-prof` or `--heap-prof`: V8 only flushes its `.cpuprofile` / `.heapprofile` output to disk on graceful exit. A `SIGKILL` would leave no profile artifact, which is why the existing diagnostic scripts at `[../../benchmarks/profile-heap.sh](../../benchmarks/profile-heap.sh)` and `[../../benchmarks/measure-event-loop-lag.sh](../../benchmarks/measure-event-loop-lag.sh)` use `SIGINT` exclusively. The baseline orchestrator follows the same convention even though it does not enable any V8 diagnostic flag, so that any future operator who copies the orchestrator's shutdown pattern into a new diagnostic harness inherits the correct termination signal.

If any rung fails mid-run (for example, an autocannon process exits non-zero), the cleanup trap still runs and the server is still shut down cleanly. The partial autocannon outputs that were captured before the failure are retained in `results/<timestamp>/` for diagnostics.

## Environmental Recording

Benchmark numbers are only meaningful against the host environment that produced them. The harness therefore writes a **`run-manifest.json`** per run, recording:

- **Timestamp** — UTC ISO-8601 form, matching the directory name under `results/`.
- **Node.js version** — captured via `node --version` (e.g., `v20.20.2`). Recorded so that a reader of the numbers can correlate them against Node.js's known version-to-version performance variance.
- **Platform** — `uname -srm` output (operating-system kernel name, kernel release, machine hardware). Recorded because TCP listen-backlog defaults, scheduler behaviour under saturation, and per-process FD limits vary across Linux distributions and macOS versions.
- **`ulimit -n`** — the per-process open-file-descriptor soft limit at run time. Recorded because a tight ulimit corrupts the c=1000 rung; the manifest field is the audit trail that reviewers consult when a c=1000 sample count is suspiciously low.
- **autocannon version** — read non-mutatingly from the installed package metadata (`require('./node_modules/autocannon/package.json').version`) at manifest-write time (e.g., `8.0.0` or a later 8.x release, depending on what `npm install` resolved from `[../../benchmarks/package.json](../../benchmarks/package.json)`'s `^8.0.0` constraint). Recorded because autocannon's default header set and its connection-management behaviour have evolved across major versions; a future major-version bump should be paired with a re-run of the baseline.
- **Scenarios that ran** — the names from `load-profile.json` (`c1`, `c10`, `c100`, `c1000`). Recorded so that a partial run (e.g., an operator interrupted after c=100) is clearly distinguishable from a complete run.
- **Output filenames** — the list of files written under `results/<timestamp>/` (e.g., `autocannon-1.json`, `autocannon-10.json`, …, `server.stdout.log`, `server.stderr.log`).

Comparing numbers across runs is meaningful **only when these environmental fields match** along the dimensions the comparison cares about: Node.js minor version for tier-up-related comparisons, kernel release for backlog-related comparisons, autocannon version for header-set-related comparisons, ulimit for high-concurrency-related comparisons. The manifest is therefore the canonical evidence file that any chapter making a cross-run comparison cites.

## Reproducibility

A reviewer can re-run the entire measurement campaign in three commands:

```bash
cd benchmarks
npm install            # populates benchmarks/node_modules/ — one-time
./run-baseline.sh
```

The first command navigates into the isolated harness package (`[../../benchmarks/](../../benchmarks/)`). The second installs autocannon and the other harness dev-dependencies into `benchmarks/node_modules/` only — per Constraint C-002 (`[Section 2.6.2]`), no packages are added to the application's root `package.json` or root `package-lock.json` (their byte-identical content is the operational meaning of the constraint, confirmed empirically by `[package-lock.json:L6-L11]`'s empty `packages` map). The third command runs the full ladder and writes results to `benchmarks/results/<unix-timestamp>/`.

For each diagnostic scenario (chapter 04 inputs), the analogous commands are:

```bash
cd benchmarks
./profile-cpu.sh                  # input for chapter 04 (CPU profile)
./profile-heap.sh                 # input for chapter 04 (heap profile)
./measure-event-loop-lag.sh       # input for chapter 06 (event-loop lag)
```

Each diagnostic script produces its own timestamped subdirectory under `results/`.

Numbers will vary across hosts — CPU model, memory subsystem, kernel version, Node.js minor version, and host load all change the absolute latency and throughput figures. The **methodology** — concurrency ladder, 30-second sustained window, 10-second discarded warm-up, GET / only request mix, p50/p95/p99/p99.9 reporting fields — is identical across hosts. Two reviewers who run the harness on different hosts should obtain different numbers but should reach the **same qualitative conclusions** about which dimensions saturate where, which percentiles diverge as concurrency rises, and whether the listen-backlog or the FD ulimit dominates the c=1000 behaviour.

## User-Provided Methodology Overrides

The user provided no methodology overrides. The defaults above are authoritative. (Per AAP §0.5.3 and §0.1.3 — the user named no specific endpoints, payloads, latency targets, sample workflows, or named tools, and the methodology therefore defaults to standard HTTP-benchmark practice as documented in every section above.)

If the user provides overrides in a follow-up turn — for example, a specific RPS target, a payload variant (a POST with a sized body, a request-header variation, an HTTP/1.1 pipelining factor), a named tool (`wrk`, `vegeta`, `hey`), or a longer sustained window (e.g., 5 minutes per rung instead of 30 seconds) — this section will be updated to incorporate those overrides verbatim before the harness is re-run, and the affected parameters in `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)` will be updated to match. Until then, this section is intentionally short — its presence is the placeholder, and its emptiness is the canonical record that no overrides were provided.
