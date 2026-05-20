#!/usr/bin/env bash
# benchmarks/measure-event-loop-lag.sh
#
# Purpose
# -------
# Drives sustained HTTP/1.1 load against ../server.js (AAP §0.6.2) while a SEPARATE
# helper Node process samples event-loop delay at a fixed interval. The helper streams
# per-interval rows to a CSV at $RESULTS_DIR/event-loop-lag.csv. The CSV is consumed
# by docs/performance/06-event-loop-and-concurrency.md (per AAP §0.6.1).
#
# Sampler Approach
# ----------------
# Per Constraint C-001 (AAP §0.7), ../server.js is NEVER modified or instrumented.
# Event-loop lag is sampled from a SEPARATE helper Node process that uses Node's
# built-in perf_hooks.monitorEventLoopDelay() API. The helper runs alongside the
# server but never alters its source code.
#
# IMPORTANT LIMITATION: The helper samples ITS OWN event loop, NOT the server's.
# This serves as a proxy for system-wide event-loop pressure under load — when the
# host is heavily loaded, both processes' event loops experience lag.
#
# To supplement the helper-process lag signal with one that DOES reflect the server's
# load, the helper also issues an HTTP probe to http://127.0.0.1:3000/ at each
# sample interval and records the measured probe RTT and HTTP status code. Use the
# probe_rtt_ms column as the primary signal for server-perceived latency under load
# and the lag_* columns as the system-wide event-loop pressure signal.
#
# AAP §0.6.2 suggests using node --inspect plus the inspector protocol to retrieve
# the server's own ELU histogram. That approach is more complex; the helper-process
# approach used here is preferred because: (a) it requires no debug-protocol tooling,
# (b) it does not depend on the inspector socket being available, and (c) it cleanly
# isolates the sampler's event-loop activity from the server's.
#
# CSV Schema (event-loop-lag.csv)
# -------------------------------
#   epoch_ms       tick time in epoch milliseconds; captured at the top of each
#                  helper tick. Rows are not strictly monotonic in write-order
#                  because probes complete in parallel — downstream consumers
#                  should sort by epoch_ms.
#   interval_ms    nominal sample interval ($SAMPLE_INTERVAL_MS). The actual
#                  wall-clock window may differ slightly under scheduler jitter.
#   elu_pct        event-loop utilization of the HELPER process (%) since the
#                  previous tick (via performance.eventLoopUtilization).
#   lag_min_ns     minimum event-loop delay observed in the just-ended window, ns
#   lag_mean_ns    mean event-loop delay, ns
#   lag_p50_ns     50th-percentile event-loop delay, ns
#   lag_p99_ns     99th-percentile event-loop delay, ns
#   lag_max_ns     maximum event-loop delay, ns
#   probe_rtt_ms   HTTP GET round-trip time to $URL in milliseconds. Reflects
#                  server-perceived latency including kernel/loopback scheduling.
#   probe_status   HTTP status code from the probe (0 if probe errored / timed out)
#
# Constraints Honored
# -------------------
#   C-001 — Source files immutable: ../server.js is launched as-is, never edited.
#   C-002 — Zero application deps: only the harness's own devDependency
#           (autocannon) is consumed for load generation; the sampler uses only
#           Node.js built-ins (perf_hooks, http, fs).
#   C-003 — Single-purpose server: no routing or middleware is added; the probe
#           hits the same GET / endpoint the load generator hits.
#   C-004 — Hardcoded host/port: HOST=127.0.0.1 and PORT=3000 are literals
#           matching [server.js:L3] and [server.js:L4].
#
# Exit Codes
# ----------
#   0 — success
#   2 — pre-flight failure (missing node, server.js, or autocannon)
#   3 — port 3000 already bound
#   4 — server failed to become ready within $READINESS_TIMEOUT_S seconds
#
# Outputs (written to $RESULTS_DIR == benchmarks/results/<timestamp>/)
# --------------------------------------------------------------------
#   event-loop-lag.csv              the sample stream (header + per-interval rows)
#   autocannon-during-elag.json     load generator's machine-readable report
#   event-loop-lag-manifest.json    run metadata (timestamp, node version, params)
#   sampler.mjs                     the helper program written by this script
#   server.stdout.log               captured stdout of the server
#   server.stderr.log               captured stderr of the server

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$SCRIPT_DIR"
SERVER_SCRIPT="$BENCH_DIR/../server.js"
HOST="127.0.0.1"
PORT=3000
URL="http://${HOST}:${PORT}/"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$BENCH_DIR/results/$TIMESTAMP"

# Load-generation parameters. The agent prompt specifies LOAD_DURATION=60 and
# LOAD_CONNECTIONS=100 — longer than the standard 30 s baseline runs to yield a
# CSV with sufficient samples (with SAMPLE_INTERVAL_MS=200, expect ~300 rows).
LOAD_DURATION=60
LOAD_CONNECTIONS=100

# Sampling parameters
SAMPLE_INTERVAL_MS=200           # 5 samples per second
READINESS_TIMEOUT_S=10           # max seconds to wait for the server to accept connections
HEADER_WAIT_S=1                  # let the sampler write the CSV header before load begins

CSV_FILE="$RESULTS_DIR/event-loop-lag.csv"
SAMPLER_SCRIPT="$RESULTS_DIR/sampler.mjs"

# Mutable PID slots — guarded in the cleanup trap
SERVER_PID=""
SAMPLER_PID=""

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: 'node' is not on PATH. Install Node.js (>=20.0.0) and retry." >&2
  exit 2
fi

if [ ! -f "$SERVER_SCRIPT" ]; then
  echo "ERROR: Server script not found at $SERVER_SCRIPT" >&2
  exit 2
fi

AUTOCANNON_BIN="$BENCH_DIR/node_modules/.bin/autocannon"
if [ ! -x "$AUTOCANNON_BIN" ]; then
  echo "ERROR: autocannon is not installed in $BENCH_DIR/node_modules/" >&2
  echo "       Run 'npm install' inside $BENCH_DIR before invoking this script." >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: 'curl' is not on PATH. curl is required for readiness checks." >&2
  exit 2
fi

# Port availability: a successful HTTP response means SOMETHING is already bound.
# Note that curl exit 7 (couldn't connect) is the success case for this check.
if curl --silent --output /dev/null --max-time 1 "$URL" 2>/dev/null; then
  echo "ERROR: Port $PORT appears to be in use (got an HTTP response from $URL)." >&2
  echo "       Stop the process bound to port $PORT and retry." >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Results directory
# ---------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"
echo "Results directory: $RESULTS_DIR"

# ---------------------------------------------------------------------------
# Generate sampler helper (perf_hooks-based) — quoted heredoc emits JS literally
# ---------------------------------------------------------------------------
cat > "$SAMPLER_SCRIPT" <<'SAMPLER_EOF'
// sampler.mjs — Event-loop-lag and HTTP-probe sampler.
//
// Written by benchmarks/measure-event-loop-lag.sh. This file is regenerated on
// every run and lives inside the timestamped results directory. Do not edit it
// directly; edit the heredoc in the parent shell script.
//
// CLI:
//   node sampler.mjs <url> <intervalMs> <csvPath>
//
// Behaviour:
//   - At process start, opens <csvPath> for append and writes the header row.
//   - Enables a perf_hooks event-loop delay histogram with 10 ms resolution.
//   - Every <intervalMs> milliseconds:
//       1. Reads the histogram min/mean/p50/p99/max (nanoseconds) for the
//          window that just ended.
//       2. Resets the histogram so the next window starts fresh.
//       3. Computes event-loop utilization (%) of THIS process since the
//          previous tick via performance.eventLoopUtilization().
//       4. Issues an HTTP GET probe to <url>, measures the round-trip time
//          with performance.now(), and records the HTTP status code (0 if the
//          probe errored or timed out).
//       5. Writes a CSV row containing all of the above.
//   - On SIGINT / SIGTERM: cancels the interval, disables the histogram,
//     flushes and closes the CSV stream, and exits 0.
//
// CSV header (must match the documentation in the parent shell script):
//   epoch_ms,interval_ms,elu_pct,lag_min_ns,lag_mean_ns,lag_p50_ns,lag_p99_ns,lag_max_ns,probe_rtt_ms,probe_status

import { monitorEventLoopDelay, performance } from 'node:perf_hooks';
import { createWriteStream } from 'node:fs';
import { get as httpGet } from 'node:http';

const [, , URL_ARG, INTERVAL_ARG, CSV_PATH] = process.argv;
if (!URL_ARG || !INTERVAL_ARG || !CSV_PATH) {
  console.error('sampler.mjs: usage: node sampler.mjs <url> <intervalMs> <csvPath>');
  process.exit(2);
}

const intervalMs = Number.parseInt(INTERVAL_ARG, 10);
if (!Number.isFinite(intervalMs) || intervalMs <= 0) {
  console.error('sampler.mjs: intervalMs must be a positive integer; got ' + INTERVAL_ARG);
  process.exit(2);
}

// HTTP probe timeout — must comfortably exceed expected RTT under load but not
// stall shutdown for too long. 5 s is generous for a loopback endpoint.
const PROBE_TIMEOUT_MS = 5000;

// Histogram resolution in milliseconds. 10 ms matches the AAP recommendation
// and gives sub-tick precision for sampling event-loop delay.
const HISTOGRAM_RESOLUTION_MS = 10;

// Open the CSV file. Per the agent prompt the stream is opened in append mode;
// the parent script guarantees the file does not pre-exist because RESULTS_DIR
// is timestamped, so the header row is written as the very first line.
const csv = createWriteStream(CSV_PATH, { flags: 'a' });

csv.on('error', (err) => {
  console.error('sampler.mjs: CSV write error: ' + err.message);
});

csv.write(
  'epoch_ms,interval_ms,elu_pct,lag_min_ns,lag_mean_ns,lag_p50_ns,lag_p99_ns,lag_max_ns,probe_rtt_ms,probe_status\n'
);

const histogram = monitorEventLoopDelay({ resolution: HISTOGRAM_RESOLUTION_MS });
histogram.enable();

// Anchor for eventLoopUtilization delta. The first sample's elu_pct is the
// fraction of helper-process event-loop time active since process start; from
// the second sample onward it's the delta since the previous tick.
let prevElu = performance.eventLoopUtilization();

let shuttingDown = false;
let tickHandle = null;

function safeFinite(value, fallback) {
  return Number.isFinite(value) ? value : fallback;
}

function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  if (tickHandle) {
    clearInterval(tickHandle);
    tickHandle = null;
  }
  try { histogram.disable(); } catch (_e) { /* histogram may already be off */ }
  csv.end(() => process.exit(0));
  // Hard stop after 1 s in case csv.end's drain never resolves (extremely unlikely
  // but defends against a stuck pipe during shutdown). .unref() ensures this timer
  // does not itself prevent exit.
  setTimeout(() => process.exit(0), 1000).unref();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

// Issue one HTTP probe; resolves with { rtt: number_ms, status: number }.
// On any error or timeout, resolves with status=0.
function sendProbe() {
  return new Promise((resolve) => {
    const start = performance.now();
    let settled = false;
    const settle = (status) => {
      if (settled) return;
      settled = true;
      resolve({ rtt: performance.now() - start, status });
    };
    let req;
    try {
      req = httpGet(URL_ARG, (res) => {
        // Drain the body so the socket can be released cleanly even though we
        // only care about the status code.
        res.resume();
        res.on('end', () => settle(res.statusCode || 0));
        res.on('error', () => settle(0));
      });
    } catch (_e) {
      settle(0);
      return;
    }
    req.setTimeout(PROBE_TIMEOUT_MS, () => {
      try { req.destroy(); } catch (_e) { /* already destroyed */ }
      settle(0);
    });
    req.on('error', () => settle(0));
  });
}

async function tick() {
  // Capture the tick timestamp BEFORE awaiting the probe. Rows are sorted by
  // epoch_ms downstream because probes complete in parallel and rows may be
  // written out of order under load.
  const epochMs = Date.now();

  // Snapshot the histogram for the window that just ended, then reset for the
  // next window. Defensive coercion guards against the rare empty-window case
  // where histogram percentile lookups can return non-finite sentinels.
  const lagMin = safeFinite(histogram.min, 0);
  const lagMean = safeFinite(histogram.mean, 0);
  const lagP50 = safeFinite(histogram.percentile(50), 0);
  const lagP99 = safeFinite(histogram.percentile(99), 0);
  const lagMax = safeFinite(histogram.max, 0);
  histogram.reset();

  // ELU delta since the previous tick. The two-argument form returns the
  // difference between curElu and prevElu.
  const curElu = performance.eventLoopUtilization();
  const deltaElu = performance.eventLoopUtilization(curElu, prevElu);
  prevElu = curElu;
  const eluPct = safeFinite(deltaElu.utilization, 0) * 100;

  // Probe the server. Multiple probes may be in-flight if RTT exceeds the
  // sample interval — that itself is a useful signal of server overload.
  const { rtt, status } = await sendProbe();

  // If shutdown was requested while awaiting the probe, drop the row rather
  // than writing to an already-closed stream.
  if (shuttingDown) return;

  csv.write(
    [
      epochMs,
      intervalMs,
      eluPct.toFixed(2),
      Math.round(lagMin),
      Math.round(lagMean),
      Math.round(lagP50),
      Math.round(lagP99),
      Math.round(lagMax),
      rtt.toFixed(3),
      status,
    ].join(',') + '\n'
  );
}

tickHandle = setInterval(() => {
  // Swallow tick errors so a single failure does not crash the sampler.
  tick().catch((err) => {
    console.error('sampler.mjs: tick error: ' + (err && err.message ? err.message : err));
  });
}, intervalMs);

// Keep the process alive until SIGINT/SIGTERM. setInterval alone keeps the
// loop active, but we also resume stdin so a parent that closes our stdio
// pipes does not silently kill us before SIGINT propagates.
process.stdin.resume();
SAMPLER_EOF

echo "Sampler written to: $SAMPLER_SCRIPT"

# ---------------------------------------------------------------------------
# Cleanup trap — must be defined BEFORE the server is launched so an early
# failure still cleans up the child process.
# ---------------------------------------------------------------------------
cleanup() {
  # Capture and suppress the original exit code so each step below cannot abort
  # cleanup partway through under set -e.
  local rc=$?
  set +e
  if [ -n "${SAMPLER_PID:-}" ] && kill -0 "$SAMPLER_PID" 2>/dev/null; then
    kill -INT "$SAMPLER_PID" 2>/dev/null || true
    wait "$SAMPLER_PID" 2>/dev/null || true
  fi
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -INT "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Launch server
# ---------------------------------------------------------------------------
echo "Launching server: node $SERVER_SCRIPT"
node "$SERVER_SCRIPT" > "$RESULTS_DIR/server.stdout.log" 2> "$RESULTS_DIR/server.stderr.log" &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# ---------------------------------------------------------------------------
# Await readiness — poll $URL with curl until the server responds, with a
# hard deadline of $READINESS_TIMEOUT_S seconds.
# ---------------------------------------------------------------------------
echo "Waiting for server readiness at $URL (timeout ${READINESS_TIMEOUT_S}s)..."
ready=0
deadline=$(( $(date +%s) + READINESS_TIMEOUT_S ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl --silent --output /dev/null --max-time 1 "$URL"; then
    ready=1
    break
  fi
  # If the server has already died, surface its stderr immediately.
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "ERROR: Server process $SERVER_PID exited before becoming ready." >&2
    echo "----- server.stderr.log -----" >&2
    cat "$RESULTS_DIR/server.stderr.log" >&2 || true
    echo "-----------------------------" >&2
    exit 4
  fi
  sleep 0.25
done

if [ "$ready" -ne 1 ]; then
  echo "ERROR: Server did not become ready within ${READINESS_TIMEOUT_S}s." >&2
  exit 4
fi
echo "Server ready."

# ---------------------------------------------------------------------------
# Launch sampler
# ---------------------------------------------------------------------------
echo "Launching sampler: node $SAMPLER_SCRIPT $URL $SAMPLE_INTERVAL_MS $CSV_FILE"
node "$SAMPLER_SCRIPT" "$URL" "$SAMPLE_INTERVAL_MS" "$CSV_FILE" &
SAMPLER_PID=$!
echo "Sampler PID: $SAMPLER_PID"

# Give the sampler a beat to open the CSV and write the header before load starts.
sleep "$HEADER_WAIT_S"

# Confirm the sampler is still alive after the warm-up.
if ! kill -0 "$SAMPLER_PID" 2>/dev/null; then
  echo "ERROR: Sampler exited prematurely. CSV header may be missing." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Apply sustained load with autocannon
# ---------------------------------------------------------------------------
echo "Applying ${LOAD_CONNECTIONS} concurrent connections for ${LOAD_DURATION}s while sampling event-loop lag..."
# Run autocannon from $BENCH_DIR so 'npx --no-install' resolves the locally
# installed binary out of $BENCH_DIR/node_modules/.bin/.
( cd "$BENCH_DIR" && npx --no-install autocannon \
    -c "$LOAD_CONNECTIONS" \
    -d "$LOAD_DURATION" \
    -j "$URL" ) > "$RESULTS_DIR/autocannon-during-elag.json"
echo "Load complete."

# ---------------------------------------------------------------------------
# Stop sampler, then server, in that order so the sampler can flush the CSV
# while the server is still reachable (any in-flight probe completes quickly).
# ---------------------------------------------------------------------------
if kill -0 "$SAMPLER_PID" 2>/dev/null; then
  kill -INT "$SAMPLER_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
fi
SAMPLER_PID=""  # mark as reaped so the EXIT trap skips it

if kill -0 "$SERVER_PID" 2>/dev/null; then
  kill -INT "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
fi
SERVER_PID=""   # mark as reaped so the EXIT trap skips it

echo "Event-loop lag CSV: $CSV_FILE"

# Quick summary of the CSV (row count includes the header).
if [ -f "$CSV_FILE" ]; then
  TOTAL_LINES=$(wc -l < "$CSV_FILE" | tr -d ' ')
  # Data rows = total lines - 1 (header)
  if [ "$TOTAL_LINES" -gt 0 ]; then
    DATA_ROWS=$(( TOTAL_LINES - 1 ))
  else
    DATA_ROWS=0
  fi
  APPROX_DURATION_S=$(( DATA_ROWS * SAMPLE_INTERVAL_MS / 1000 ))
  echo "CSV rows: $DATA_ROWS data rows (+1 header) covering ~${APPROX_DURATION_S}s at ${SAMPLE_INTERVAL_MS}ms interval."
else
  echo "WARNING: CSV file was not produced." >&2
fi

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
NODE_VERSION="$(node --version)"
MANIFEST_FILE="$RESULTS_DIR/event-loop-lag-manifest.json"
# Pass run metadata as positional argv to node -e. With -e, argv[0]=node and the
# first positional arg becomes argv[1]. We destructure in order.
node -e '
  const fs = require("fs");
  const [
    ,
    manifestFile,
    timestamp,
    nodeVersion,
    host,
    port,
    url,
    loadConnections,
    loadDurationS,
    sampleIntervalMs,
    csvPath,
    autocannonReport,
    samplerScript,
    serverScript,
    resultsDir,
  ] = process.argv;
  const manifest = {
    timestamp,
    node_version: nodeVersion,
    host,
    port: Number(port),
    url,
    load_connections: Number(loadConnections),
    load_duration_s: Number(loadDurationS),
    sample_interval_ms: Number(sampleIntervalMs),
    csv_path: csvPath,
    autocannon_report: autocannonReport,
    sampler_script: samplerScript,
    server_script: serverScript,
    results_dir: resultsDir,
    csv_columns: [
      "epoch_ms",
      "interval_ms",
      "elu_pct",
      "lag_min_ns",
      "lag_mean_ns",
      "lag_p50_ns",
      "lag_p99_ns",
      "lag_max_ns",
      "probe_rtt_ms",
      "probe_status",
    ],
    notes: "lag_* values reflect the helper process event loop; probe_rtt_ms reflects server-perceived loopback latency. Rows may not be strictly time-ordered under load — sort by epoch_ms before analysis.",
  };
  fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + "\n");
' \
  "$MANIFEST_FILE" \
  "$TIMESTAMP" \
  "$NODE_VERSION" \
  "$HOST" \
  "$PORT" \
  "$URL" \
  "$LOAD_CONNECTIONS" \
  "$LOAD_DURATION" \
  "$SAMPLE_INTERVAL_MS" \
  "$CSV_FILE" \
  "$RESULTS_DIR/autocannon-during-elag.json" \
  "$SAMPLER_SCRIPT" \
  "$SERVER_SCRIPT" \
  "$RESULTS_DIR"

echo "Manifest: $MANIFEST_FILE"
echo "Event-loop lag measurement complete."
