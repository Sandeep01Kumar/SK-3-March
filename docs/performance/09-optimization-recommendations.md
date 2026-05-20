# Optimization Recommendations

This chapter is the aggregated, tagged inventory of every optimization recommendation that the rest of this analysis surfaced. It consolidates the items proposed in [03-load-profile-and-methodology.md](./03-load-profile-and-methodology.md), [04-cpu-and-memory-profile.md](./04-cpu-and-memory-profile.md), [05-latency-and-throughput.md](./05-latency-and-throughput.md), [06-event-loop-and-concurrency.md](./06-event-loop-and-concurrency.md), [07-network-latency.md](./07-network-latency.md), [08-caching-analysis.md](./08-caching-analysis.md), [10-scalability-assessment.md](./10-scalability-assessment.md), and [11-observability-recommendations.md](./11-observability-recommendations.md), and it tags each item with exactly one of five categories so that reviewers can immediately distinguish what is applicable now from what is conditional on relaxing a governance constraint. The tagging scheme is defined formally in [README.md](./README.md) under "Recommendation Tags" and is summarized in one sentence here: **READY** items can be applied as-is without modifying any of the four committed source files (`server.js`, `package.json`, `package-lock.json`, `README.md`), without adding any application dependency, without expanding the server's single-purpose handler, and without introducing environment variables or configuration files; **ADVISORY-Cxxx** items require lifting the named constraint from `[Section 2.6.2]` before they can be applied. The codebase owner — and only the codebase owner — has the authority to lift any of those constraints; this chapter does not lift any of them, it merely names what each recommendation would require. Per AAP §0.8.1 ("Honesty rule"), every recommendation has been classified by the constraint set it would require relaxing, not by the impression of difficulty it might create at first reading; an apparently trivial header addition that nonetheless edits `[server.js]` is tagged ADVISORY-C001 with the same rigor as a wholesale rewrite, because both edits touch the same governed file and both require the same owner approval.

## Tag Legend

The five tags below appear at the start of every recommendation title in this chapter, in the matching `##` section heading, and in the Cross-Reference Index at the end of the chapter. They mirror the definitions canonicalized in [README.md](./README.md) ("Recommendation Tags") and in AAP §0.6.2 / §0.7 / §0.8.1.

- **READY** — applicable without modifying `server.js`, `package.json`, `package-lock.json`, `README.md`; without adding any entry to the application's `dependencies` or `devDependencies`; without adding a route, middleware, or alternate response path inside the handler at `[server.js:L6-L10]`; and without introducing an environment variable, `.env` file, or external config file into the application. READY recommendations may modify the host operating system (sysctl, ulimit), the harness package under `benchmarks/`, the runtime environment choice (Node.js major version), or the deployment infrastructure (CDN, reverse-proxy cache) — all of which live entirely outside the four committed source files.
- **ADVISORY-C001** — would modify one of the four committed source files (`server.js`, `package.json`, `package-lock.json`, `README.md`). Forbidden by the governance directive at `[README.md:L2]` ("Do not touch!") and codified as Constraint C-001 per `[Section 2.6.2]`. The codebase owner must explicitly approve the source edit before any ADVISORY-C001 recommendation can be applied.
- **ADVISORY-C002** — would add an entry to the application's `[package.json:L1-L11]` `dependencies` or `devDependencies` (currently empty per the resolved-dependency-graph evidence at `[package-lock.json:L6-L11]`). Forbidden by Constraint C-002 per `[Section 2.6.2]`. ADVISORY-C002 recommendations almost always co-occur with ADVISORY-C001 because the new dependency must be `require`'d somewhere in `[server.js]`.
- **ADVISORY-C003** — would expand the handler at `[server.js:L6-L10]` to handle more than the single unconditional `Hello, World!\n` response — for instance, by branching on `req.url` to add `/health` or `/metrics` endpoints, by introducing middleware, or by inserting an alternate response path. Forbidden by Constraint C-003 ("Single-purpose") per `[Section 2.6.2]`. ADVISORY-C003 recommendations always co-occur with ADVISORY-C001 because the routing branch itself is a source edit.
- **ADVISORY-C004** — would parameterize the hostname at `[server.js:L3]`, the port at `[server.js:L4]`, or the response body at `[server.js:L9]` via an environment variable, `.env` file, or external config file. Forbidden by Constraint C-004 ("Hardcoded configuration") per `[Section 2.6.2]`. ADVISORY-C004 recommendations always co-occur with ADVISORY-C001 because reading `process.env.X` requires editing `[server.js]`.

Multi-tag recommendations explicitly list every constraint they would require lifting, with the most "structural" constraint listed first. For example, an entry tagged "ADVISORY-C001 + ADVISORY-C002 + ADVISORY-C003" requires the codebase owner to lift all three constraints simultaneously, and the operator who consumes this report should not interpret the entry as partially applicable — it is all-or-nothing.

## READY Recommendations

The recommendations in this section are the operational subset of the report — every one of them is applicable as soon as the operator who runs the harness decides to apply it, without prior approval from the codebase owner to lift any of Constraints C-001 through C-004. They divide into three sub-themes: **host-level OS/kernel tuning** (R1, R2, R6, R7) that adjusts sysctl and ulimit values the application implicitly depends on; **harness-side measurement extensions** (R3, R5, R8, R9, R10, R11, R12) that live entirely inside the `benchmarks/` package and add observability without instrumenting `server.js`; and **deployment/environment choices** (R4, R13) that select a Node.js runtime version or place a cache in front of the application without modifying any of its source files. Reviewers should expect this section to be substantially longer than any single ADVISORY section because the harness-extension category accumulates one or more items from each preceding chapter; the length is a function of the report's honesty about what can be done without lifting a constraint, not of optimistic padding.

### R1. Tune the kernel TCP listen-backlog (`net.core.somaxconn`)

- **Tag**: **READY**
- **Finding.** [07-network-latency.md](./07-network-latency.md) ("TCP Listen-Backlog" and recommendation N1). The Node.js default listen-backlog is **511** on Linux (the value passed to the kernel by `net.Server.prototype.listen` when no explicit backlog is supplied), and `[server.js:L12]` invokes `server.listen(port, hostname, callback)` without supplying an explicit backlog argument — so the application implicitly accepts the framework default. The kernel-level cap on the listen-accept queue is the sysctl `net.core.somaxconn`, which on older long-term-support Linux distributions defaults to **128** and on recent stable distributions defaults to **4096**. When the host default is below the Node.js default, the kernel silently truncates the requested backlog to its cap, so the effective backlog is `min(net.core.somaxconn, requested_backlog)` — and on the c=1000 rung of the concurrency ladder defined in [03-load-profile-and-methodology.md](./03-load-profile-and-methodology.md), a backlog of 128 is easily exceeded by an autocannon connection burst, producing SYN drops or `accept()` queue overflow.
- **Proposed change.** On the host operating system, set `net.core.somaxconn` to at least 4096 (8192 is also reasonable for hosts that expect to run the c=1000 or higher rungs). Two ways:
  - **Transient** (until reboot): `sudo sysctl -w net.core.somaxconn=4096`
  - **Persistent** (across reboots): write a one-line file `net.core.somaxconn = 4096` to `/etc/sysctl.d/99-backlog.conf` and apply with `sudo sysctl --system`
  - **Verification**: `sysctl net.core.somaxconn` should report `net.core.somaxconn = 4096` after the change.
- **Constraint to relax.** None. The change modifies a kernel-level sysctl tunable on the host operating system; it does not touch `[server.js:L1-L14]`, does not add any entry to `[package.json:L1-L11]`, does not introduce a route or middleware into the handler, and does not introduce any environment variable or config file into the application package. Constraints C-001 through C-004 per `[Section 2.6.2]` are all preserved.
- **Expected effect.** At the c=1000 rung of the concurrency ladder, reduces or eliminates SYN drops and `accept()` queue overflows when the client burst rate exceeds the kernel's accept-queue drain rate. The observable consequence in the autocannon output is a reduction (often to zero) in the `errors` and `non2xx` counters at c=1000; in the kernel log (`dmesg`) it eliminates entries of the form "possible SYN flooding on port 3000. Sending cookies." See [07-network-latency.md](./07-network-latency.md) ("Detecting Backlog Saturation") for the three concurrent symptoms whose simultaneous presence is the diagnostic signature of backlog saturation.

### R2. Raise the process file-descriptor limit before measurement

- **Tag**: **READY**
- **Finding.** [06-event-loop-and-concurrency.md](./06-event-loop-and-concurrency.md) ("FD Pressure at c=1000") and [07-network-latency.md](./07-network-latency.md) (recommendation N4). On many Linux distributions the default soft file-descriptor limit (`ulimit -n`) is 1024, which means that the 1024th accepted socket connection in a c=1000 rung — once you account for stdio (fds 0/1/2), the listening socket itself, any open log files, and the connections autocannon holds open simultaneously — will return `EMFILE: too many open files` from the kernel's `accept(2)` call. The harness's `[../../benchmarks/run-baseline.sh](../../benchmarks/run-baseline.sh)` ("Pre-flight checks") emits a warning when the current `ulimit -n` is below 65535, but the warning is advisory; an operator who ignores it and runs the c=1000 rung will see autocannon `errors` and server `stderr.log` entries of the form `Error: accept EMFILE 127.0.0.1:3000`. This signal is easy to confuse with backlog saturation (R1 above) because both produce elevated autocannon error counts; the discriminator is the server's `stderr.log` — `EMFILE` is FD saturation, while the absence of `EMFILE` combined with kernel `dmesg` SYN-cookie warnings is backlog saturation.
- **Proposed change.** Before invoking the harness, raise the soft file-descriptor limit to a value that comfortably exceeds the c=1000 concurrent-connection target plus the harness's own overhead:
  - **Per shell session**: `ulimit -n 65535`. The value persists for the duration of the shell and any process spawned from it (the server, the load generator, and any inspector-protocol client).
  - **Systemd unit**: if the server is run as a systemd service, set `LimitNOFILE=65535` in the `[Service]` section of the unit file and reload with `sudo systemctl daemon-reload && sudo systemctl restart <unit>`.
  - **Container runtime**: when running inside Docker, pass `--ulimit nofile=65535:65535` on `docker run`; when running inside Kubernetes, the cluster's pod security policy or the container runtime's default applies.
- **Constraint to relax.** None. The change is per-shell or per-unit; it does not modify any of the four committed source files, does not add any entry to `[package.json:L1-L11]`, and does not touch the handler at `[server.js:L6-L10]`.
- **Expected effect.** Prevents `EMFILE` errors at the c=1000 rung; produces a clean latency histogram at the upper tier of the concurrency ladder; removes the most common environmental confound that obscures the application's true event-loop saturation behavior.

### R3. Extend the harness with additional concurrency rungs

- **Tag**: **READY**
- **Finding.** [03-load-profile-and-methodology.md](./03-load-profile-and-methodology.md) ("Concurrency Ladder") and [05-latency-and-throughput.md](./05-latency-and-throughput.md) ("RPS Curve and Saturation"). The canonical ladder published in this report — `1 → 10 → 100 → 1000` simultaneous open TCP connections — is a geometric 10× progression that is deliberately coarse to keep the report's data set manageable and the methodology reproducible across a wide range of hosts. The cost of that coarseness is that the saturation knee (the point on the RPS-vs-concurrency curve where throughput stops scaling linearly and tail latency starts climbing) can fall anywhere between the c=100 and c=1000 rungs, and the four-rung ladder cannot resolve where in that 10× interval it actually lies. The same coarseness applies above c=1000: on a fast multi-core host with a tuned kernel (after R1 and R2 are applied), the c=1000 rung may not yet have saturated the application, and one or more rungs above c=1000 would be needed to find the actual ceiling.
- **Proposed change.** Extend `[../../benchmarks/load-profile.json](../../benchmarks/load-profile.json)` with intermediate and super-high rungs as appropriate to the host. Two examples of useful extensions:
  - **Saturation-knee resolution between c=100 and c=1000**: add scenarios for c=200, c=400, c=600, c=800. Each scenario inherits the same 30-second duration and 10-second warm-up as the canonical rungs.
  - **Post-saturation behavior above c=1000**: add scenarios for c=2000, c=5000, c=10000. The harness's pre-flight checks (per [03-load-profile-and-methodology.md](./03-load-profile-and-methodology.md)) should be tightened to require `ulimit -n` ≥ `2 × max_concurrency` and `net.core.somaxconn` ≥ `max_concurrency` before allowing these higher rungs to run.
  - The new scenarios live entirely inside the `benchmarks/` package; no file under the application package boundary is touched.
- **Constraint to relax.** None. The change is to the harness's scenario configuration, which lives under `[../../benchmarks/](../../benchmarks/)` per AAP §0.6.1 and is isolated from the application's package boundary per Constraint C-002.
- **Expected effect.** Better resolution of the saturation knee on the RPS-vs-concurrency curve; characterization of the post-saturation tail-latency growth pattern (the rate at which p99 climbs once the saturation point is exceeded); a more defensible answer to the question "what is the maximum sustainable RPS on this host?" than the four-rung ladder alone can provide.

### R4. Run the harness on the highest stable Node.js LTS available

- **Tag**: **READY**
- **Finding.** `[Section "Node.js Version Compatibility"]` records that Node.js 20.x is in maintenance LTS through April 2026, 22.x is in maintenance LTS, and 24.x is the current active LTS. Major version upgrades typically bring V8 engine improvements (faster bytecode interpretation, improved inline caching, more aggressive Turbofan optimization), libuv improvements (better event-loop throughput), and HTTP-parser improvements (the `llhttp` parser has continued to improve through the 20 → 22 → 24 sequence). The current baseline measurements published in [05-latency-and-throughput.md](./05-latency-and-throughput.md) are captured under Node.js 20.20.2 (the system Node available in the development environment per the setup log), and the published numbers are therefore conservative against newer majors.
- **Proposed change.** Run the server under Node.js 24.x active LTS (and optionally also under 22.x maintenance LTS) on the same host with the same `[../../benchmarks/run-baseline.sh](../../benchmarks/run-baseline.sh)` invocation, recording the runtime version in `run-manifest.json` for each result set. The choice of runtime is an environment selection — `nvm install 24 && nvm use 24` or equivalent — not a source-code change. The application source at `[server.js:L1-L14]` is byte-identical between runs; only the `node` binary executing it differs.
- **Constraint to relax.** None. Switching the Node.js runtime is an environment choice that does not modify any of the four committed source files, does not add any entry to `[package.json:L1-L11]`, and does not change the handler at `[server.js:L6-L10]`. The `[package.json:L1-L11]` manifest declares no `engines` field, so neither version is "officially supported" or "officially unsupported" by the manifest; the application runs on whatever `node` version is on PATH.
- **Expected effect.** Provides a Node.js-version-attributable lift estimate. Reviewers can use the comparison to (a) inform hosting decisions (which Node.js LTS to deploy in production), (b) calibrate the published baseline against newer-runtime expectations, and (c) check whether any newly-observed regression or improvement correlates with the V8 / libuv / llhttp version bundled with each major.

### R5. Record run manifests alongside every results directory

- **Tag**: **READY**
- **Finding.** [03-load-profile-and-methodology.md](./03-load-profile-and-methodology.md) ("Reproducibility" and "Environmental Recording") and [05-latency-and-throughput.md](./05-latency-and-throughput.md) ("Comparison Against the Implicit SLA"). The harness's `[../../benchmarks/run-baseline.sh](../../benchmarks/run-baseline.sh)` already emits a `run-manifest.json` into each results directory; that manifest records the host's CPU model, kernel version, Node.js version, `ulimit -n` value, and `net.core.somaxconn` value at the moment the run started. The recommendation here is a process discipline rather than a code change: every published results table in the report (and every comparison across runs) should be accompanied by the path to the run manifest, so that a reviewer can verify that two compared runs were captured under sufficiently similar conditions to make the comparison meaningful.
- **Proposed change.** Adopt the practice of citing `run-manifest.json` paths inline next to every numeric measurement in published reports and analyses. The harness already produces the manifest; the recommendation is to consume it consistently.
- **Constraint to relax.** None. Citation discipline is a documentation practice that lives entirely in `[../../docs/performance/](../../docs/performance/)`; it does not touch the application package.
- **Expected effect.** Makes results comparable across runs and hosts. Reviewers and downstream analyses can trace each measurement to the environment in which it was captured, which is essential when an unexpected number appears — the first question to ask is always "what was different about that run?" and the manifest is the canonical record of differences.

### R6. Raise `net.ipv4.tcp_max_syn_backlog`

- **Tag**: **READY**
- **Finding.** [07-network-latency.md](./07-network-latency.md) (recommendation N2). The sysctl `net.ipv4.tcp_max_syn_backlog` controls the size of the **half-open** connection table — the kernel table that tracks connections in the `SYN_RECV` state, between the inbound `SYN` and the third leg (the client's `ACK`) of the TCP handshake. When a c=1000 burst arrives faster than the kernel can complete handshakes, the half-open table fills, and the kernel responds by either dropping further `SYN`s (older behavior) or emitting SYN cookies (`net.ipv4.tcp_syncookies=1`, the default on most modern distributions). On distributions where the cookies path is active, the symptom is `dmesg` warnings of the form "possible SYN flooding on port 3000. Sending cookies."; on distributions where it is not, the symptom is dropped `SYN`s and elevated client-side connection failures.
- **Proposed change.** Set `net.ipv4.tcp_max_syn_backlog` to at least 4096 (8192 is reasonable for c=1000+ workloads). Two ways:
  - **Transient**: `sudo sysctl -w net.ipv4.tcp_max_syn_backlog=4096`
  - **Persistent**: append `net.ipv4.tcp_max_syn_backlog = 4096` to `/etc/sysctl.d/99-backlog.conf` (the same file used for R1) and apply with `sudo sysctl --system`
  - **Verification**: `sysctl net.ipv4.tcp_max_syn_backlog` should report the new value.
- **Constraint to relax.** None. Sysctl tuning is external to the application; no source, dependency, scope, or config change.
- **Expected effect.** Eliminates SYN-flood `dmesg` warnings during c=1000 runs; resolves the half-open-table dimension of backlog saturation, complementary to R1's listen-accept-queue dimension. R1 and R6 are typically applied together because they address the two queues that together form the kernel's accept pipeline.

### R7. Enable TCP Fast Open (optional)

- **Tag**: **READY (optional)**
- **Finding.** [07-network-latency.md](./07-network-latency.md) (recommendation N3). TCP Fast Open (TFO) allows a client to include payload data in its `SYN` packet, eliminating one round-trip for connection establishment. It is enabled via `net.ipv4.tcp_fastopen` (`0` disabled, `1` client-only, `2` server-only, `3` both). For the loopback workload measured in this report, the round-trip elimination has no measurable effect — loopback RTT is a few microseconds and the additional handshake leg is dominated by kernel-internal cost rather than network propagation. TFO is recorded here for the operator who plans to deploy the application against real network clients, where the round-trip elimination is meaningful for short-lived HTTP/1.1 connections.
- **Proposed change.** Set `net.ipv4.tcp_fastopen=3` (client and server). On the loopback workload there will be no measurable change; on a real-network deployment, expect a small reduction in connection-establishment latency proportional to the network RTT.
- **Constraint to relax.** None. Sysctl tuning is external to the application.
- **Expected effect.** Loopback: none measurable. Real-network: small reduction in handshake latency for short-lived connections; no effect on the throughput ceiling.

### R8. Sample `process.memoryUsage()` periodically from a harness wrapper

- **Tag**: **READY**
- **Finding.** [04-cpu-and-memory-profile.md](./04-cpu-and-memory-profile.md) ("RSS Sampling"). The `--heap-prof` flag emits a single cumulative allocation profile per process exit, which captures **what was allocated** but not **when**. To correlate memory growth against the c=N rung timeline, the report needs a time series of RSS / heap-used / external sampled at fixed intervals during the measured window. Node.js exposes the in-process `process.memoryUsage()` API which returns RSS, heap-total, heap-used, external, and array-buffer totals in a few microseconds per call.
- **Proposed change.** Extend the harness with an out-of-process wrapper that connects to the server via the Node.js inspector protocol (after launching `node --inspect ../server.js`) and invokes the `Runtime.evaluate` method to sample `process.memoryUsage()` at a fixed cadence (e.g., 1 sample/second) during the measured window. Emit the resulting time series to `[../../benchmarks/results/](../../benchmarks/results/)<timestamp>/memory-usage.csv`. The wrapper lives in the harness package; no application file is modified.
- **Constraint to relax.** None. The inspector protocol is a Node.js built-in capability activated by a runtime flag, not an application-source change. The sampling code lives in the harness.
- **Expected effect.** Time-aligned RSS / heap-used trace alongside the latency/throughput trace, enabling direct attribution of any memory growth to a specific concurrency-ladder rung or to a specific time window within a rung.

### R9. Capture multiple back-to-back heap-profile runs and diff the totals

- **Tag**: **READY**
- **Finding.** [04-cpu-and-memory-profile.md](./04-cpu-and-memory-profile.md) ("Retained Memory Across Snapshots"). Identifying retention growth (as opposed to allocation rate) requires comparing heap profiles taken at two different points in time. The harness already supports single-run `[../../benchmarks/profile-heap.sh](../../benchmarks/profile-heap.sh)` capture; the recommendation is to formalize a multi-run mode that captures N back-to-back runs (typically 3 to 5) and emits the per-run `.heapprofile` files into a single timestamped results directory for downstream comparison.
- **Proposed change.** Add a shell-level loop around `[../../benchmarks/profile-heap.sh](../../benchmarks/profile-heap.sh)` invocation that records N consecutive runs into `[../../benchmarks/results/](../../benchmarks/results/)<timestamp>/heap-run-{1..N}.heapprofile`, then load each into Chrome DevTools or `node-heap-dump-analyzer` and compare the **Retained Size** column across runs to identify objects whose retained memory grows monotonically (a leak signal).
- **Constraint to relax.** None. The change is to harness orchestration; no application file is modified.
- **Expected effect.** Identifies retention growth without requiring an inspector-protocol session and without modifying `[server.js]`. The signal is weaker than a true V8 heap snapshot taken from within the running process (because the heap profile is sampled allocation data, not full retention data), but it is sufficient to flag the most common leak patterns (closure capture growing without bound, callback queue accumulation, listener registration without removal).

### R10. Record explicit `startup_time_ms` in the run manifest

- **Tag**: **READY**
- **Finding.** [05-latency-and-throughput.md](./05-latency-and-throughput.md) ("Comparison Against the Implicit SLA"). The SLA in `[Section 4.7.3]` states "startup ≤ 1 s", and the harness currently measures readiness by polling `curl -fsS --max-time 1 http://127.0.0.1:3000/` at 200 ms intervals up to 50 attempts — so it knows the time-to-ready to within ±200 ms — but it does not currently record the elapsed time as a dedicated field in `run-manifest.json`. The result is that the SLA verdict cell in chapter 05's table is "<TBD on first run — recommend harness extension>" rather than a measured number.
- **Proposed change.** Extend `[../../benchmarks/run-baseline.sh](../../benchmarks/run-baseline.sh)` to capture the spawn timestamp (`SPAWN_TS=$(date +%s%3N)` just before `node ../server.js &`) and the readiness timestamp (`READY_TS=$(date +%s%3N)` immediately after the first successful curl poll), compute `STARTUP_MS=$((READY_TS - SPAWN_TS))`, and write it to `run-manifest.json` as the `startup_time_ms` field. The change lives in the harness; no application file is modified.
- **Constraint to relax.** None. Harness-level instrumentation only.
- **Expected effect.** Makes the SLA verdict directly measurable on every run; eliminates the manual log-inspection step currently required to compute startup time; provides a regression signal if a future Node.js version, host kernel, or hardware swap changes the startup characteristics.

### R11. Add a passive `ss -ltn` `Recv-Q` sampler to the harness

- **Tag**: **READY**
- **Finding.** [07-network-latency.md](./07-network-latency.md) ("Detecting Backlog Saturation"). One of the three diagnostic symptoms of listen-backlog saturation is a non-zero `Recv-Q` value on the listening socket as reported by `ss -ltn`. This symptom is currently only observable by an operator who happens to run `ss -ltn` during the c=1000 window; the harness does not capture it automatically, so its absence from the archived results does not mean it was absent during the run — only that it was not recorded.
- **Proposed change.** Extend `[../../benchmarks/run-baseline.sh](../../benchmarks/run-baseline.sh)` to spawn, alongside the autocannon load generator, a background `ss` sampler that runs `ss -ltn | awk '/127\.0\.0\.1:3000/ {print $1,$2,$3}' >> recv-q.csv` at 200 ms intervals for the duration of the measured window. The output goes into the timestamped results directory; the sampler is killed when the harness's main `wait` returns.
- **Constraint to relax.** None. Harness-side sampler only.
- **Expected effect.** Closes the observability gap between symptom and diagnosis at the c=1000 rung; provides a time-aligned trace of the listening-socket accept-queue depth alongside the latency and error traces; allows the operator to confirm — or rule out — listen-backlog saturation without manual `ss` inspection during the run.

### R12. Sample RSS and CPU at 1-second cadence during each ladder rung

- **Tag**: **READY**
- **Finding.** [03-load-profile-and-methodology.md](./03-load-profile-and-methodology.md) ("OS-Process Sampling Cadence"). The methodology chapter records that a 1-second cadence is the recommended sampling interval for OS-level RSS and CPU% during each rung's measured window; the harness can be extended to spawn a `pidstat -r -u -p $SERVER_PID 1` (Linux) or equivalent sampler that captures the time series into a CSV alongside the autocannon output. This is complementary to R8 (which samples from inside the process via inspector protocol); R12 samples from outside via `ps`/`pidstat`/`/proc`, which has the advantage of working without an inspector connection but the disadvantage of being limited to OS-visible metrics (no internal V8 heap detail).
- **Proposed change.** Add a background sampler in `[../../benchmarks/run-baseline.sh](../../benchmarks/run-baseline.sh)` that runs `pidstat -r -u -p $SERVER_PID 1 >> rss-cpu.csv &` immediately after the server is ready and is killed when the measured window completes. On hosts where `pidstat` is not installed (it lives in the `sysstat` package), fall back to a shell loop: `while kill -0 $SERVER_PID 2>/dev/null; do ps -o rss=,pcpu= -p $SERVER_PID; sleep 1; done >> rss-cpu.csv &`.
- **Constraint to relax.** None. Harness-side sampler only.
- **Expected effect.** Time-aligned RSS / CPU% trace per rung; enables capacity-planning calculations (peak RSS, sustained CPU%) that the autocannon JSON alone cannot answer; provides an early-warning signal if a future change introduces memory growth or CPU regression.

### R13. Deploy a CDN or reverse-proxy cache in front of the application

- **Tag**: **READY (deployment-level)**
- **Finding.** [08-caching-analysis.md](./08-caching-analysis.md) (recommendation C5). Application-level caching has no substrate in this codebase — the response body is the 14-byte compile-time constant `'Hello, World!\n'` at `[server.js:L9]`, and there is no upstream computation whose result could be cached. The only caching layer that meaningfully reduces work in this system is **proxy-side caching**: placing a reverse proxy (nginx, Varnish, HAProxy with a cache module) or a CDN edge (CloudFront, Fastly, Cloudflare) in front of the application and configuring it to cache the response for some TTL. Because the response is identical for every request and has no query-string, header, or cookie variation, even a very short TTL (5 seconds, 1 minute) is sufficient to absorb the entire load — the application's request rate is reduced to roughly `1 / TTL` requests per second per proxy-cache key.
- **Proposed change.** Deploy a reverse proxy in front of the application:
  - **nginx**: enable `proxy_cache` with `proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=hello:10m max_size=10m`, `proxy_cache hello; proxy_cache_valid 200 1m;` in the location block. `proxy_pass http://127.0.0.1:3000/` to forward to the application.
  - **CDN**: configure the CDN distribution to forward to the host's public address (which would require a deployment that does not bind to loopback — out of scope for this loopback-only analysis report) and to cache `200 OK` responses for a TTL of choice.
- **Constraint to relax.** None *at the application level* — the proxy or CDN lives entirely outside the four committed source files and outside the application's package boundary. The caveat is that proxy-side caching is most effective when the application also emits `ETag` / `Last-Modified` / `Cache-Control` headers (which is recommendation A1-1 below, tagged ADVISORY-C001 because it requires editing `[server.js:L7-L9]`); without those headers, the proxy must rely on its own TTL configuration and cannot revalidate against the origin. For an operator who controls only the proxy, R13 alone is applicable; for an operator who controls both the proxy and the application source, R13 + A1-1 together produce the strongest result.
- **Expected effect.** Cuts the request rate hitting the Node.js process by the cache hit rate (potentially 99%+ for a workload with no per-request variation); the application becomes effectively "infinitely scalable" up to the proxy's own throughput limit, because the proxy serves the cached response without involving the application at all. The caveat from chapter 08 stands: the implementing agent of this analysis report does not deploy proxies and therefore cannot quote a measured effect; the recommendation is tagged READY because it does not violate any of C-001 through C-004, but it is the operator's responsibility to deploy and validate it.

## ADVISORY-C001 — Source Modification Required

The recommendations in this section would modify one of the four committed source files (in practice almost always `[server.js]`) and therefore require the codebase owner to lift Constraint C-001 ("Do not touch!") per `[README.md:L2]` and `[Section 2.6.2]` before they can be applied. None of these recommendations is presently applicable; they are listed here so the codebase owner has a complete inventory of the source-edit-conditional optimizations the analysis surfaced, with the size and shape of each edit recorded so the owner can weigh impact against governance risk.

### A1-1. Add HTTP caching headers (`ETag`, `Last-Modified`, `Cache-Control`) to the response

- **Tag**: **ADVISORY-C001**
- **Finding.** [08-caching-analysis.md](./08-caching-analysis.md) (recommendations C1, C2, C3, C4 — the four ADVISORY-C001 caching options surfaced in that chapter). The response body at `[server.js:L9]` is the 14-byte compile-time constant `'Hello, World!\n'`. Adding validator headers (`ETag` for strong validation or `Last-Modified` for weak validation) and freshness directives (`Cache-Control: public, max-age=...`) would enable HTTP-level conditional GET — clients that have a fresh cached copy can issue `If-None-Match` or `If-Modified-Since` against the server, and the server can respond `304 Not Modified` (with no body) instead of `200 OK` (with the 14-byte body). For repeat clients, the wire-byte savings is 100% of the response body; combined with the `Cache-Control` directive, the round-trip itself can be eliminated for the configured TTL.
- **Proposed change.** Modify `[server.js:L7-L9]` to:
  ```javascript
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain');
  res.setHeader('ETag', '"hello-v1"');
  res.setHeader('Cache-Control', 'public, max-age=3600');
  if (req.headers['if-none-match'] === '"hello-v1"') {
    res.statusCode = 304;
    res.end();
    return;
  }
  res.end('Hello, World!\n');
  ```
  This is approximately 5 added lines centered at `[server.js:L7-L9]`. The minimal variant (`Cache-Control` alone, recommendation C3 from chapter 08) adds only 1 line.
- **Constraint to relax.** **C-001** per `[README.md:L2]` and `[Section 2.6.2]` — every variant modifies `[server.js]`.
- **Expected effect.** Wire bytes for repeat-client requests drop to 0 (the 304 response has no body); the `Cache-Control` directive enables client-side caching that eliminates the request round-trip entirely for the configured TTL. Magnitude is bounded by the small body size — eliminating a 14-byte body produces only a modest absolute saving — but the structural improvement (the server correctly speaks the HTTP caching protocol) is real and is the prerequisite for getting full value out of R13 (proxy-side caching).

### A1-2. Replace the per-request `res.end('Hello, World!\n')` string write with a module-scope pre-buffered `Buffer`

- **Tag**: **ADVISORY-C001**
- **Finding.** [04-cpu-and-memory-profile.md](./04-cpu-and-memory-profile.md) ("CPU Profile" and "Heap Profile"). The call to `res.end('Hello, World!\n')` at `[server.js:L9]` passes a string to the response writer; the writer's path through Node.js's `http` module converts the string to a `Buffer` before pushing to the socket. V8 may intern the literal and cache the encoded form, but the conversion check is still present in the parser/writer path, and the per-request allocation behavior depends on the V8 version's interning aggressiveness.
- **Proposed change.** Hoist a pre-encoded `Buffer` to module scope and reuse it on every request:
  ```javascript
  const HELLO_BODY = Buffer.from('Hello, World!\n');
  // ...
  res.setHeader('Content-Length', HELLO_BODY.length);
  res.end(HELLO_BODY);
  ```
  The change is approximately 2 added lines (one at module scope, one in the handler) and one modified line (the `res.end` call). The setting of `Content-Length` is a free side-benefit because it removes the chunked-transfer-encoding path that the response would otherwise default to.
- **Constraint to relax.** **C-001** per `[README.md:L2]` and `[Section 2.6.2]` — modifies `[server.js:L9]`.
- **Expected effect.** Minor per-request CPU saving (eliminates the string-to-Buffer conversion step per request); minor per-request allocation reduction; removes the chunked-transfer-encoding path in favor of a fixed-length response. Magnitude is small because the body is short and V8 likely already optimizes the short-literal case; the change is structurally cleaner regardless of whether the measurable effect on RPS is detectable.

### A1-3. Adopt Node.js's `cluster` module to fork one worker per CPU core

- **Tag**: **ADVISORY-C001** (also borders on **ADVISORY-C003** because it expands the single-purpose nature of the process model)
- **Finding.** [06-event-loop-and-concurrency.md](./06-event-loop-and-concurrency.md) ("Event-Loop Saturation Signature") and [10-scalability-assessment.md](./10-scalability-assessment.md) (recommendation H1). Node.js is single-threaded per `[Section 5.2.1]`; the application currently uses exactly one CPU core regardless of how many cores the host has. The `cluster` module is the canonical Node.js mechanism for multi-process scaling on a single host: a master process forks N worker processes, each binding to the same port (the kernel uses `SO_REUSEPORT` to distribute incoming connections across workers). Throughput typically scales near-linearly with worker count up to the number of physical cores.
- **Proposed change.** Wrap `[server.js:L6-L14]` in a `cluster` master/worker pattern. The minimal version is approximately 12 added lines:
  ```javascript
  const cluster = require('cluster');
  const os = require('os');
  if (cluster.isPrimary) {
    for (let i = 0; i < os.cpus().length; i++) cluster.fork();
    cluster.on('exit', () => cluster.fork());
  } else {
    // existing [server.js:L1-L14] body here
  }
  ```
- **Constraint to relax.** **C-001** per `[README.md:L2]` and `[Section 2.6.2]` (substantially rewrites `[server.js:L1-L14]`). Borders on **C-003** because the master-worker structure expands the process model from "one process serves all requests" to "one process spawns workers that serve requests" — reasonable reviewers can disagree about whether this counts as "single-purpose" — but the C-001 violation is unambiguous.
- **Expected effect.** Throughput scales near-linearly with the host's physical core count for static-endpoint workloads. On an 8-core host, expect roughly 6×–8× the RPS of the single-process baseline (the sub-linear shortfall is mostly kernel overhead and `SO_REUSEPORT` distribution skew). Latency at low concurrency is unchanged; latency at the c=1000 saturation point is dramatically reduced because the workload is distributed across N event loops instead of saturating one.

### A1-4. Adopt `worker_threads` for in-process parallelism

- **Tag**: **ADVISORY-C001**
- **Finding.** [10-scalability-assessment.md](./10-scalability-assessment.md) (recommendation H4). Node.js's `worker_threads` module provides true OS-thread parallelism for JavaScript execution within a single process, using message-passing rather than shared memory (with the exception of `SharedArrayBuffer`). For CPU-bound workloads the parallelism gain is similar to `cluster`'s; for I/O-bound workloads the gain is generally smaller because the libuv I/O thread pool already provides background parallelism for I/O.
- **Proposed change.** Restructure `[server.js:L1-L14]` to use `worker_threads`: the main thread accepts connections and dispatches request handling to worker-thread instances via a message channel. The minimal structural change is similar to A1-3 in line count but more invasive in semantics because the request-handling code must be reachable from multiple threads.
- **Constraint to relax.** **C-001** per `[README.md:L2]` and `[Section 2.6.2]`.
- **Expected effect.** Comparable to A1-3 for CPU-bound workloads; less significant than A1-3 for the present I/O-bound static-endpoint workload because there is essentially no per-request CPU work to distribute. For this codebase specifically, A1-3 (cluster) is the better choice; A1-4 (worker_threads) is documented here for completeness because chapter 10 surfaced it.

### A1-5. Pass an explicit `backlog` argument to `server.listen`

- **Tag**: **ADVISORY-C001**
- **Finding.** [07-network-latency.md](./07-network-latency.md) (recommendation N5). The Node.js default listen-backlog is 511. After applying R1 (kernel `net.core.somaxconn` raised above 511) and R6 (`tcp_max_syn_backlog` raised), the binding constraint on the application-side backlog becomes the Node.js default. To align the application-side cap with the kernel-side cap, the operator must pass an explicit `backlog` argument to `server.listen`:
  ```javascript
  server.listen({ port, host: hostname, backlog: 4096 }, callback);
  ```
  or the positional form:
  ```javascript
  server.listen(port, hostname, 4096, callback);
  ```
- **Proposed change.** Modify `[server.js:L12]` to one of the two forms above.
- **Constraint to relax.** **C-001** per `[README.md:L2]` and `[Section 2.6.2]`.
- **Expected effect.** Aligns the application-side accept-queue cap with the kernel-side cap after R1 is applied. Note that this recommendation is only useful **after** R1 — without R1, the kernel cap (`net.core.somaxconn`, often 128 or 4096) still binds, and increasing the application-side backlog above the kernel cap has no effect.

### A1-6. Add periodic process-telemetry self-report (RSS / heap / event-loop lag) emitted to stdout

- **Tag**: **ADVISORY-C001**
- **Finding.** [11-observability-recommendations.md](./11-observability-recommendations.md) (recommendation O5 — the only single-constraint ADVISORY in chapter 11). The application currently emits exactly one line of output for its entire lifecycle: the startup log at `[server.js:L13]`. A self-report timer that emits `process.memoryUsage()` and event-loop lag readings to stdout at a fixed interval would expose long-running process state without requiring an external scraper, an inspector connection, or a dependency. The output is unstructured prose by default; an operator who wants structured output can post-process with `awk` / `jq`.
- **Proposed change.** Add approximately 5 lines to `[server.js]`:
  ```javascript
  setInterval(() => {
    const m = process.memoryUsage();
    console.log(`mem rss=${m.rss} heapUsed=${m.heapUsed} external=${m.external}`);
  }, 10000).unref();
  ```
- **Constraint to relax.** **C-001** per `[README.md:L2]` and `[Section 2.6.2]`. **C-002 is not relaxed** — `process.memoryUsage()` is a Node.js built-in, not a dependency.
- **Expected effect.** Provides a continuous operational signal of RSS / heap / external memory without instrumentation overhead from a scraper or inspector. The `unref()` call ensures the timer does not keep the process alive past its natural exit. Useful as a long-running observability signal even though it does not unlock per-request forensics (for which O1 — structured request logging, ADVISORY-C001 + ADVISORY-C002 — is the right tool).

## ADVISORY-C002 — Application Dependency Required

The recommendations in this section would add an entry to the application's `[package.json:L1-L11]` `dependencies` or `devDependencies` (currently empty per `[package-lock.json:L6-L11]`) and therefore require the codebase owner to lift Constraint C-002 ("Zero external dependencies") per `[Section 2.6.2]`. Every recommendation in this section also requires lifting C-001 because the new dependency must be `require`'d from `[server.js]`; multi-tag entries record both. Reviewers comparing items in this section should weigh **dependency footprint** (how many transitive packages the addition pulls in, what their licenses are, what their security posture is) alongside **expected effect**, because each new application dependency is an indefinite ongoing maintenance commitment.

### A2-1. Replace the built-in `http` module with `fastify`

- **Tag**: **ADVISORY-C002 + ADVISORY-C001**
- **Finding.** [04-cpu-and-memory-profile.md](./04-cpu-and-memory-profile.md) ("CPU Profile") and [05-latency-and-throughput.md](./05-latency-and-throughput.md). The built-in `http` module at `[server.js:L1]` is fully sufficient for the 14-byte static response workload, but higher-performance HTTP server frameworks (e.g., `fastify`) have, on similar workloads, demonstrated 1.2×–1.5× throughput improvements over the built-in module — primarily by using a different router (`find-my-way`) and by reducing per-request allocation overhead in the request-construction path.
- **Proposed change.** Add `fastify` to `[package.json:L1-L11]` `dependencies`; rewrite `[server.js:L1-L14]` to use:
  ```javascript
  const fastify = require('fastify')();
  fastify.get('/', (req, reply) => reply.send('Hello, World!\n'));
  fastify.listen({ port: 3000, host: '127.0.0.1' });
  ```
- **Constraint to relax.** **C-002** (dependency addition: `fastify` and its transitive deps — approximately 10 packages at current `fastify` 4.x); **C-001** (source rewrite of `[server.js:L1-L14]`).
- **Expected effect.** Typically 1.2×–1.5× RPS improvement on similar workloads. **Marginal value at this scale**: the 14-byte static-response workload spends most of its per-request time in the kernel's syscall path (`accept`, `read`, `write`) rather than in the JavaScript handler, so the framework-level overhead reduction is a small fraction of the total per-request cost. The recommendation is honest about its marginal nature; reviewers should weigh the 10-dependency footprint against the modest expected lift.

### A2-2. Add structured request logging via `pino`

- **Tag**: **ADVISORY-C002 + ADVISORY-C001**
- **Finding.** [11-observability-recommendations.md](./11-observability-recommendations.md) (recommendation O1 — the canonical entry for the C-001 + C-002 pair). The application currently emits no per-request log line; the only stdout output is the startup `console.log` at `[server.js:L13]`. Per-request structured logging — one log line per HTTP request, with fields for method, URL, status, duration, response size, and any error — is the foundational layer of operational observability, and it is the prerequisite for the forensic workflows (request-rate analysis, p99-latency forensics, error correlation) that operators expect from any production service.
- **Proposed change.** Add `pino` to `[package.json:L1-L11]` `dependencies`; add approximately 2 lines to `[server.js:L6-L10]`:
  ```javascript
  const log = require('pino')();
  const server = http.createServer((req, res) => {
    const start = process.hrtime.bigint();
    res.on('finish', () => log.info({
      method: req.method, url: req.url, status: res.statusCode,
      durMs: Number(process.hrtime.bigint() - start) / 1e6,
    }));
    res.statusCode = 200;
    res.setHeader('Content-Type', 'text/plain');
    res.end('Hello, World!\n');
  });
  ```
- **Constraint to relax.** **C-002** (`pino` is a single dependency with minimal transitive footprint); **C-001** (modifies `[server.js:L6-L10]`).
- **Expected effect.** Per-request log line at the `info` level emitted to stdout in NDJSON format; ready for direct ingestion by Loki, Elasticsearch, Splunk, or any line-oriented log collector. Negligible CPU/memory overhead on the per-request path (pino is one of the lowest-overhead Node.js loggers by design). Foundational observability layer.

### A2-3. Add OpenTelemetry tracing instrumentation

- **Tag**: **ADVISORY-C002 + ADVISORY-C001**
- **Finding.** [11-observability-recommendations.md](./11-observability-recommendations.md) (recommendation O3). OpenTelemetry is the CNCF standard for distributed tracing; the `@opentelemetry/sdk-node` package and its auto-instrumentations would create a `span` for every incoming HTTP request and propagate the trace context to any outbound HTTP calls (of which the application currently has none — see [02-workflow-gap-analysis.md](./02-workflow-gap-analysis.md) on the absence of outbound integrations).
- **Proposed change.** Add `@opentelemetry/sdk-node`, `@opentelemetry/auto-instrumentations-node`, and an exporter (e.g., `@opentelemetry/exporter-trace-otlp-http`) to `[package.json:L1-L11]` `dependencies`; add approximately 5 lines to the top of `[server.js]` to initialize the SDK before the `http` module is loaded. The SDK auto-instruments the `http` module, so no per-request code change is required beyond the initialization.
- **Constraint to relax.** **C-002** (3+ `@opentelemetry/*` deps and their transitive footprint — typically 15-20 packages); **C-001** (modifies the top of `[server.js]`).
- **Expected effect.** One span per request, exported via OTLP to a tracing backend (Jaeger, Zipkin, Tempo, Honeycomb, Lightstep). The single-span trace is the minimum useful unit; the per-request CPU overhead is meaningful (single-digit-percent of the per-request cost) but acceptable for any workload that values tracing. The value is highest in multi-service deployments where trace context propagates across hops; for a single-service deployment like this one the value is reduced but not zero (durations, error correlation).

### A2-4. Add `prom-client` for Prometheus `/metrics` exposition

- **Tag**: **ADVISORY-C002 + ADVISORY-C001 + ADVISORY-C003**
- **Finding.** [11-observability-recommendations.md](./11-observability-recommendations.md) (recommendation O2). Prometheus is the de-facto standard for metrics scraping in cloud-native deployments. The `prom-client` package provides counters, gauges, and histograms suitable for tracking request rates, error rates, and latency distributions; the `register.metrics()` API returns the OpenMetrics text format that Prometheus servers scrape from a `/metrics` endpoint.
- **Proposed change.** Add `prom-client` to `[package.json:L1-L11]` `dependencies`; instrument the handler at `[server.js:L6-L10]` with a counter and a histogram (approximately 5 added lines); add a URL branch to the handler so that requests to `/metrics` return `register.metrics()` instead of the static response (approximately 5 added lines).
- **Constraint to relax.** **C-002** (`prom-client` is a single dependency); **C-001** (modifies `[server.js:L6-L10]`); **C-003** (adds a `/metrics` URL branch — a routing decision).
- **Expected effect.** Prometheus-compatible `/metrics` endpoint exposing per-request counter, latency histogram, response-status histogram, and the default Node.js process metrics (event-loop lag, GC pauses, heap stats). The metrics endpoint becomes the canonical operational signal source for alerts and dashboards in Grafana / Alertmanager / equivalent. This recommendation appears in both A2-2 (here, viewed from the dependency side) and A3-2 (below, viewed from the routing side); the two entries describe the same change at different angles.

## ADVISORY-C003 — Single-Purpose Expansion Required

The recommendations in this section would expand the handler at `[server.js:L6-L10]` to handle more than the single unconditional `Hello, World!\n` response — either by branching on `req.url`, by introducing middleware, or by inserting an alternate response path — and therefore require the codebase owner to lift Constraint C-003 ("Single-purpose") per `[Section 2.6.2]`. Every recommendation in this section also requires lifting C-001 because the routing branch itself is a source edit; multi-tag entries record every constraint that would need to be lifted.

### A3-1. Add a `/health` route

- **Tag**: **ADVISORY-C003 + ADVISORY-C001**
- **Finding.** [11-observability-recommendations.md](./11-observability-recommendations.md) (recommendation O4 — the canonical entry for the C-001 + C-003 pair). Load balancers, orchestrators (Kubernetes, Amazon ECS, HashiCorp Nomad), and most CDN edge configurations expect a dedicated health endpoint — typically `GET /health` or `GET /healthz` — that returns 200 OK when the service is functioning and a non-2xx status when it is not. The current application has no such endpoint; any deployment behind a load balancer would either (a) configure the load balancer to use `GET /` as the health check (which works for this static-response application but does not generalize) or (b) accept that no health-check signal is available.
- **Proposed change.** Branch on `req.url` inside the handler at `[server.js:L6-L10]`:
  ```javascript
  if (req.url === '/health') {
    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/json');
    res.end('{"status":"ok"}\n');
    return;
  }
  // existing static response
  ```
  Approximately 5 added lines centered at `[server.js:L7]`.
- **Constraint to relax.** **C-003** (routing branch — handler now serves two distinct responses); **C-001** (source modification of `[server.js:L6-L10]`).
- **Expected effect.** Enables deployment behind a load balancer with health checks; enables Kubernetes liveness and readiness probes; provides a deterministic readiness signal that does not require the operator to interpret the static-response output. No measurable effect on the per-request latency or throughput of the primary `/` endpoint because the URL branch is essentially free (single string comparison).

### A3-2. Add a `/metrics` route exposing Prometheus exposition format

- **Tag**: **ADVISORY-C003 + ADVISORY-C001 + ADVISORY-C002**
- **Finding.** [11-observability-recommendations.md](./11-observability-recommendations.md) (recommendation O2). This is the same change as A2-4 above, listed here under the routing-side view: from the perspective of the single-purpose constraint, the change adds a new URL `/metrics` to the handler, which is a routing decision. From the perspective of the dependency constraint (A2-4), the change adds `prom-client` to the application's dependencies. Both views describe the same edit; reviewers should treat A2-4 and A3-2 as a single recommendation that requires lifting three constraints simultaneously.
- **Proposed change.** As described in A2-4.
- **Constraint to relax.** **C-003** (routing branch); **C-001** (source modification); **C-002** (dependency addition: `prom-client`).
- **Expected effect.** As described in A2-4.

### A3-3. Introduce a reverse proxy in front of multiple Node.js instances

- **Tag**: **ADVISORY-C003 + ADVISORY-C001** (and **ADVISORY-C004** if multi-port deployment is chosen)
- **Finding.** [06-event-loop-and-concurrency.md](./06-event-loop-and-concurrency.md) (recommendation A1-4 — the chapter's reverse-proxy entry) and [10-scalability-assessment.md](./10-scalability-assessment.md) (recommendation H2 — the chapter's multi-instance-behind-proxy entry). Two views of the same architecture: place an nginx or HAProxy in front of N Node.js instances and let the proxy distribute requests across them. The two chapters differ on which constraint is the primary blocker. Chapter 06 emphasizes that the reverse proxy expands the architecture from "one Node.js process serves all requests" to "a proxy plus N Node.js processes serve requests" — a scope expansion that the chapter tags as C-003. Chapter 10 emphasizes that running N Node.js processes on a single host requires each process to bind to a distinct port, which in turn requires parameterizing `[server.js:L4]` — a configuration parameterization that the chapter tags as C-004. Both views are correct; the consolidated entry here lists every constraint that the most common implementation (multi-port, single-host) would require.
- **Proposed change.** Two implementation choices:
  - **Same-port with cluster module (avoids C-004)**: combine A1-3 (cluster) with a single nginx upstream pointing at `127.0.0.1:3000`. The cluster module uses `SO_REUSEPORT` to let multiple workers share the listening socket; no port parameterization is needed. Tagged ADVISORY-C001 (cluster source change) + ADVISORY-C003 (proxy adds architectural component).
  - **Multi-port (requires C-004)**: run N independent `node server.js` processes, each on a distinct port (e.g., 3001, 3002, 3003), with nginx upstream containing all N. Requires parameterizing `[server.js:L4]` so each process can read its port from the environment. Tagged ADVISORY-C001 + ADVISORY-C003 + ADVISORY-C004.
- **Constraint to relax.** **C-003** (architecture expanded to proxy + N application instances); **C-001** (either cluster source change or port parameterization in `[server.js]`); **C-004** in the multi-port variant.
- **Expected effect.** Absorbs concurrent-connection spikes at the proxy layer (the proxy's accept-queue capacity is typically far larger than Node.js's); distributes load across N event loops; enables zero-downtime deployments by rolling restart of instances behind the proxy; gives operators a single point of TLS termination, header rewriting, request logging, and rate limiting. This is the conventional production-deployment shape for any Node.js HTTP service; the recommendation appears here as ADVISORY because the application's governance posture has not yet sanctioned the architectural expansion.

## ADVISORY-C004 — Configuration Parameterization Required

The recommendations in this section would introduce environment variables, `.env` files, or external config files into the application — parameterizing the hostname at `[server.js:L3]`, the port at `[server.js:L4]`, or the response body at `[server.js:L9]` — and therefore require the codebase owner to lift Constraint C-004 ("Hardcoded configuration") per `[Section 2.6.2]`. Every recommendation in this section also requires lifting C-001 because reading `process.env.X` is a source edit; multi-tag entries record both. The chapter notes for completeness that C-004 also covers `.env` files (which would not typically be checked in) and any `config/*.json` files; the criterion is whether *any* runtime input controls behavior, not the file format.

### A4-1. Parameterize `HOST` and `PORT`

- **Tag**: **ADVISORY-C004 + ADVISORY-C001**
- **Finding.** `[server.js:L3-L4]` hardcodes `127.0.0.1` and `3000` respectively. Running multiple instances on the same host — for example, behind a reverse proxy in the multi-port variant of A3-3 — requires that each instance bind to a different port, which is structurally impossible without parameterizing `[server.js:L4]`. Running the application behind a reverse proxy on a non-default port (the canonical pattern is `nginx` on 80/443 with `proxy_pass` to upstreams on 3001/3002/...) similarly requires port parameterization.
- **Proposed change.** Modify `[server.js:L3-L4]` to:
  ```javascript
  const hostname = process.env.HOST || '127.0.0.1';
  const port = Number(process.env.PORT) || 3000;
  ```
  Two added/modified lines.
- **Constraint to relax.** **C-004** (introduces `process.env.HOST` and `process.env.PORT` reads); **C-001** (modifies `[server.js:L3-L4]`).
- **Expected effect.** Enables multi-instance single-host deployments (multi-port variant of A3-3); enables deployment behind reverse proxies whose upstream port is not 3000; enables Docker/Kubernetes deployments where the orchestrator chooses the port. Defaults are preserved (`127.0.0.1`, `3000`) so existing single-instance invocations are unchanged. No effect on per-request behavior.

### A4-2. Parameterize the response body via environment variable or config file

- **Tag**: **ADVISORY-C004 + ADVISORY-C001**
- **Finding.** `[server.js:L9]` hardcodes the response body `'Hello, World!\n'`. Parameterizing it (e.g., `process.env.RESPONSE_BODY || 'Hello, World!\n'`) would allow tenant-specific or environment-specific responses without requiring a source change per environment.
- **Proposed change.** Modify `[server.js:L9]` to read from `process.env.RESPONSE_BODY` with the current literal as the default.
- **Constraint to relax.** **C-004** + **C-001**.
- **Expected effect.** Enables environment-specific responses. **Note**: this entry is included for completeness — it is unlikely to be a real performance optimization because the response body's contribution to latency and throughput is dominated by the per-request HTTP framing cost and the per-connection kernel overhead, not by the body's content. The entry exists so the chapter has full coverage of every C-004-conditional change, not because it is recommended for performance reasons.

### A4-3. Multi-host horizontal scaling

- **Tag**: **ADVISORY-C004 + ADVISORY-C001**
- **Finding.** [10-scalability-assessment.md](./10-scalability-assessment.md) (recommendation H3). Multi-host horizontal scaling — running N independent instances on N hosts behind an external load balancer — requires each instance to bind to a host-routable address (typically `0.0.0.0`) rather than the loopback address. The loopback binding at `[server.js:L3]` is documented as ADR-003 per `[Section 6.5.7]` and is a load-bearing security posture; lifting it has security implications that must be acknowledged explicitly, which is why this recommendation carries both ADVISORY-C001 and ADVISORY-C004 tags rather than being presented as a trivial "just change the string" edit.
- **Proposed change.** Modify `[server.js:L3]` to read from `process.env.HOST` (as in A4-1) and set `HOST=0.0.0.0` in the production environment. Deploy N instances on N hosts behind an external load balancer (cloud provider's L7 LB, HAProxy, nginx).
- **Constraint to relax.** **C-004** (introduces environment-variable read); **C-001** (modifies `[server.js:L3]`). Implicitly also lifts ADR-003 per `[Section 6.5.7]`; the security implication must be acknowledged explicitly because the loopback binding eliminated external attack surface and lifting it restores it.
- **Expected effect.** True multi-host horizontal scaling; throughput scales with the number of hosts (subject to load-balancer capacity and any shared downstream resources, of which this application has none). This is the conventional shape for any Node.js HTTP service deployed at production scale; the recommendation appears as ADVISORY here because the application's governance posture has not yet sanctioned the architectural and security change.

## Cross-Reference Index

The table below maps each preceding chapter to the recommendations in this chapter that it surfaced. A single chapter can surface multiple recommendations, and a single recommendation can be surfaced (or cross-referenced) by multiple chapters — the table records the primary source. Recommendations surfaced first in this chapter and not present in any other chapter are not included in the table because there is no "source chapter" for them; every recommendation listed below originated in another chapter and was aggregated here per the chapter's design (AAP §0.6.2).

| Source chapter | R-ID(s) produced |
|----------------|------------------|
| 03 — Methodology ([03-load-profile-and-methodology.md](./03-load-profile-and-methodology.md)) | R3, R4, R5, R12 |
| 04 — CPU/Memory ([04-cpu-and-memory-profile.md](./04-cpu-and-memory-profile.md)) | R8, R9, A1-2, A2-1 |
| 05 — Latency/Throughput ([05-latency-and-throughput.md](./05-latency-and-throughput.md)) | R10 (cross-references R3, R1, A1-2) |
| 06 — Event loop ([06-event-loop-and-concurrency.md](./06-event-loop-and-concurrency.md)) | R2, A1-3, A3-3 |
| 07 — Network ([07-network-latency.md](./07-network-latency.md)) | R1, R6, R7, R11, A1-5 |
| 08 — Caching ([08-caching-analysis.md](./08-caching-analysis.md)) | A1-1, R13 |
| 10 — Scalability ([10-scalability-assessment.md](./10-scalability-assessment.md)) | A1-3, A1-4, A3-3, A4-1, A4-3 |
| 11 — Observability ([11-observability-recommendations.md](./11-observability-recommendations.md)) | A1-6, A2-2, A2-3, A2-4 (= A3-2), A3-1 |

A few entries deserve explanation:

- **A1-3 appears under both chapters 06 and 10** because the `cluster` module is the canonical answer to both event-loop saturation (chapter 06's framing) and to single-process scaling (chapter 10's framing). The two chapters surface the same recommendation from different starting points; this chapter consolidates them as one entry.
- **A3-3 appears under both chapters 06 and 10** for the same reason: reverse-proxy-plus-multiple-instances is both an event-loop-saturation answer (chapter 06's A1-4) and a horizontal-scaling answer (chapter 10's H2). The constraint set differs slightly between the two framings — chapter 06 emphasizes C-001 + C-003 while chapter 10 emphasizes C-001 + C-004 — and the consolidated entry above records both implementation paths (same-port via cluster, or multi-port via parameterized binding).
- **A2-4 and A3-2 describe the same change** (adding `prom-client` and exposing `/metrics`) viewed from two different constraint angles. The agent prompt requested both entries to illustrate the multi-tag pattern; the consolidated description in A2-4 is the authoritative one, with A3-2 acting as the routing-side cross-reference.
- **A4-1 is mapped to chapter 10** because chapter 10's H3 (multi-host horizontal scaling) and the multi-port variant of A3-3 both require parameterizing `HOST` and `PORT` as a prerequisite. Chapter 10 carries the C-004 tag on those entries for exactly that reason, even though A4-1 itself is the canonical write-up.
- **A4-2 (parameterize response body)** is not mapped to any source chapter because no preceding chapter surfaced it; it appears in this chapter for completeness, as the agent prompt explicitly noted that it is "unlikely to be a real performance optimization". Reviewers may treat A4-2 as an inventory item rather than an actionable recommendation.

The Cross-Reference Index is canonical: any recommendation surfaced by a chapter that is not present in the index above represents either an authoring error (item missed during aggregation) or a deliberate choice to omit (item judged out of scope for this report). The implementing agent has reviewed each of chapters 03–11 to confirm that every surfaced recommendation has a corresponding row above; reviewers who notice an omission should add the row rather than rely on inference.

## Authoring Constraints — What This Chapter Did Not Recommend

For transparency, this chapter explicitly does **not** propose to fix any of the documented inconsistencies KI-001, KI-002, KI-003 recorded in `[Section 2.6.3]`. Those inconsistencies are accepted constraints per AAP §0.7 and per the codebase's governance posture; the analysis report cites them where relevant (for instance, the harness uses `node ../server.js` rather than `npm start` because no `start` script exists per KI-001 / `[package.json:L6-L8]`, and the harness does not `require('hello_world')` programmatically because `index.js` does not exist per KI-002 / `[package.json:L5]`) but it does not propose to resolve them. Reviewers who wish to resolve any of KI-001 through KI-003 should treat that decision as separate from any recommendation in this chapter and should reference the governance discussion in `[Section 2.6.3]` rather than this report.

This chapter also explicitly does **not** propose to fabricate measurements or recommendations for the absent workflows enumerated in [02-workflow-gap-analysis.md](./02-workflow-gap-analysis.md). Authentication, dashboard rendering, file upload/download, third-party integration, database query, frontend rendering, and background-job execution are all ABSENT from this codebase per the gap chapter's analysis; their absence is recorded honestly there and inherited everywhere else in the report. Any future work that adds one of those workflows to the application would necessarily lift Constraint C-001 (source modification) and almost certainly C-002 (dependency addition) and C-003 (scope expansion) as well; this chapter does not pre-recommend any such addition because the analysis report's scope per AAP §0.3 is the application as it currently exists, not a hypothetical future version.
