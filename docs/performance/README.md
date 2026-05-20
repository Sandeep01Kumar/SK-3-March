# Performance Analysis

This folder contains the comprehensive performance analysis of the `hao-backprop-test` application defined in `[server.js:L1-L14]`. The analysis is **observational**: it does not modify the application's source code, dependencies, configuration, or response shape. The reason for observational-only analysis is the governance directive in `[README.md:L2]` ("Do not touch!") which is codified as Constraint **C-001** (`[Section 2.6.2]`). The deliverable is this set of CommonMark Markdown chapters plus the measurement harness at [`../../benchmarks/`](../../benchmarks/).

## How to Read This Report

1. Start with [Chapter 00 — Executive Summary](./00-executive-summary.md) for headline findings, baseline numbers, and the top READY/ADVISORY recommendations.
2. If you are interested in *what was measured* and *how*, follow with [Chapter 03 — Load Profile and Methodology](./03-load-profile-and-methodology.md) and then the data-driven chapters: [Chapter 04 — CPU and Memory Profile](./04-cpu-and-memory-profile.md), [Chapter 05 — Latency and Throughput](./05-latency-and-throughput.md), [Chapter 06 — Event Loop and Concurrency](./06-event-loop-and-concurrency.md), and [Chapter 07 — Network Latency](./07-network-latency.md).
3. If you are interested in *what to do next*, follow with [Chapter 09 — Optimization Recommendations](./09-optimization-recommendations.md), which carries every actionable item tagged with whether it can be applied directly (READY) or requires the codebase owner to relax a specific governance constraint (ADVISORY-Cxxx).

## Chapter Map

| Chapter | File | Topic |
|---------|------|-------|
| — | [README.md](./README.md) | Index and reader's guide (this file) |
| 00 | [00-executive-summary.md](./00-executive-summary.md) | Headline findings; populated last |
| 01 | [01-baseline-characterization.md](./01-baseline-characterization.md) | Per-line walk-through of `[server.js:L1-L14]` |
| 02 | [02-workflow-gap-analysis.md](./02-workflow-gap-analysis.md) | Canonical PRESENT/ABSENT record for the user-named workflows |
| 03 | [03-load-profile-and-methodology.md](./03-load-profile-and-methodology.md) | Concurrency ladder, durations, sample sizes, warm-up policy |
| 04 | [04-cpu-and-memory-profile.md](./04-cpu-and-memory-profile.md) | V8 CPU profile and heap profile findings |
| 05 | [05-latency-and-throughput.md](./05-latency-and-throughput.md) | Latency histograms and RPS curves |
| 06 | [06-event-loop-and-concurrency.md](./06-event-loop-and-concurrency.md) | Event-loop lag and concurrent-connection behavior |
| 07 | [07-network-latency.md](./07-network-latency.md) | Loopback RTT and TCP listen-backlog characterization |
| 08 | [08-caching-analysis.md](./08-caching-analysis.md) | HTTP-level caching opportunities (advisory) |
| 09 | [09-optimization-recommendations.md](./09-optimization-recommendations.md) | Tagged recommendations (READY / ADVISORY-Cxxx) |
| 10 | [10-scalability-assessment.md](./10-scalability-assessment.md) | Concurrent-user scaling posture |
| 11 | [11-observability-recommendations.md](./11-observability-recommendations.md) | Advisory instrumentation guidance |

The chapter numbering (00–11) is canonical and matches the AAP's §0.6.1 "File-by-File Execution Plan" — it must not be altered, renumbered, or reordered. Cross-references throughout the chapters assume this ordering.

## How to Reproduce

Measurements in this report are produced by the harness at [`../../benchmarks/`](../../benchmarks/). The harness is a **separate Node.js package** with its own `package.json` and its own `package-lock.json` — per Constraint **C-002** (`[Section 2.6.2]`), the application's root `[package.json:L1-L11]` has zero `dependencies` and zero `devDependencies` and must remain byte-identical. Running `npm install` at the repository root would be a no-op against the empty root manifest (`[package-lock.json:L6-L11]`); the harness's dev-dependencies (notably `autocannon`) install **only** inside `benchmarks/node_modules/` and never bubble into the application package.

To reproduce the baseline latency/throughput numbers, run the three-command sequence documented in [`../../benchmarks/README.md`](../../benchmarks/README.md):

```bash
cd benchmarks
npm install
./run-baseline.sh
```

The harness ships four scripts:

- `run-baseline.sh` — latency/throughput baseline orchestrator. Drives `autocannon` against `http://127.0.0.1:3000/` across the concurrency ladder defined in `load-profile.json`.
- `profile-cpu.sh` — V8 CPU profile capture. Wraps `node --cpu-prof ../server.js` under sustained load and collects the emitted `*.cpuprofile`.
- `profile-heap.sh` — V8 heap profile capture. Wraps `node --heap-prof ../server.js` under sustained load and collects the emitted `*.heapprofile`.
- `measure-event-loop-lag.sh` — event-loop lag sampler. Drives sustained load while sampling event-loop delay via `perf_hooks.monitorEventLoopDelay()` and emits CSV.

Each invocation creates a fresh `../../benchmarks/results/<unix-timestamp>/` directory containing the artifacts produced by that run. Chapters 04–07 cite these artifacts by relative path.

## Recommendation Tags

Every recommendation in this report carries one of five tags. The tag indicates whether the recommendation can be applied directly or requires the codebase owner to first relax a specific governance constraint. Tagging exists so that a reviewer can immediately separate items they can act on today from items that need an explicit constraint-relaxation decision.

- **READY** — No constraint must be relaxed. The recommendation can be applied without touching `server.js`, `package.json`, `package-lock.json`, or `README.md`. Typical examples include kernel-level tuning (`net.core.somaxconn`, `ulimit -n`), harness extensions under [`../../benchmarks/`](../../benchmarks/), and OS-level limit adjustments external to the application.
- **ADVISORY-C001** — Would require modifying `server.js`, `package.json`, `package-lock.json`, or `README.md`. Forbidden by the governance directive in `[README.md:L2]` and codified as Constraint **C-001** in `[Section 2.6.2]` until the codebase owner approves.
- **ADVISORY-C002** — Would require adding entries to the application's `dependencies` or `devDependencies` in `[package.json:L1-L11]`. Forbidden by Constraint **C-002** in `[Section 2.6.2]`. Note that the harness's own dev-dependencies under [`../../benchmarks/`](../../benchmarks/) do **not** trigger this constraint — they are isolated to a separate npm package.
- **ADVISORY-C003** — Would require expanding the server beyond its single-purpose static response (e.g., adding routes like `/health` or `/metrics`, alternate response paths, or any conditional behavior). Forbidden by Constraint **C-003** in `[Section 2.6.2]`.
- **ADVISORY-C004** — Would require parameterizing the hostname `[server.js:L3]`, port `[server.js:L4]`, or response body `[server.js:L9]` via environment variables, `.env` files, or other runtime configuration. Forbidden by Constraint **C-004** in `[Section 2.6.2]`.

## Constraints

The following governance constraints are in force throughout this report. They originate in the application's root `[README.md:L2]` and the tech spec's `[Section 2.6.2]`, and they shape every recommendation in [Chapter 09](./09-optimization-recommendations.md) and [Chapter 11](./11-observability-recommendations.md):

- **C-001** — "Do not touch!" — `[README.md:L2]`, `[Section 2.6.2]`. No application-source modifications: `server.js`, `package.json`, `package-lock.json`, and `README.md` are read-only.
- **C-002** — Zero application dependencies — `[Section 2.6.2]`. The application package retains an empty dependency graph (`[package-lock.json:L6-L11]`). The measurement harness lives in [`../../benchmarks/`](../../benchmarks/) as a separate npm package precisely to preserve this constraint.
- **C-003** — Single-purpose server — `[Section 2.6.2]`. The server returns a fixed 14-byte `text/plain` response for every request. No new routes, middleware, or alternate response paths may be added.
- **C-004** — Hardcoded configuration — `[Section 2.6.2]`. The hostname `[server.js:L3]`, port `[server.js:L4]`, and response body `[server.js:L9]` remain literals. No environment variables, `.env` files, or runtime parameters may be introduced.

## Scope Notes

- **Workflow gap** — Of the seven workflow categories the user named (authentication flows, dashboard rendering, file upload/download, third-party integrations, database queries, frontend rendering, background jobs), **none exist in the codebase**. Only the static HTTP endpoint at `[server.js:L6-L10]` exists. See [Chapter 02 — Workflow Gap Analysis](./02-workflow-gap-analysis.md) for the canonical PRESENT/ABSENT record; every other chapter defers to it rather than restating presence/absence independently.
- **Result files are not committed** — Per AAP §0.8.2, the actual binary profile artifacts (`*.cpuprofile`, `*.heapprofile`), timestamped `autocannon` JSON outputs, and event-loop-lag CSVs under `../../benchmarks/results/<timestamp>/` are environment-specific (host CPU, kernel, and Node.js version dependent) and intentionally excluded from version control. Only `../../benchmarks/results/.gitkeep` is committed to reserve the directory.
