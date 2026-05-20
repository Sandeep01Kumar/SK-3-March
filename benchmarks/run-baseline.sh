#!/usr/bin/env bash
# benchmarks/run-baseline.sh
#
# Purpose
# -------
# Latency-and-throughput baseline orchestrator. This is the canonical entry
# point for the harness (AAP §0.6.2). It (a) performs pre-flight checks
# (node/server.js/load-profile.json/autocannon/curl presence, port-3000
# availability, ulimit-n soft warning), (b) launches `node ../server.js` in
# the background and captures its stdout/stderr to per-run log files,
# (c) awaits HTTP readiness on http://127.0.0.1:3000/, (d) iterates the
# concurrency ladder declared in benchmarks/load-profile.json (1 → 10 → 100
# → 1000 by default; AAP §0.5.3), running one discarded warm-up pass
# followed by one measurement pass per rung via `npx --no-install
# autocannon -c N -d D -j URL`, (e) writes per-rung autocannon JSON reports
# to results/<timestamp>/autocannon-<N>.json, (f) emits a run-manifest.json
# describing the run, and (g) cleanly SIGINTs the server in both happy-path
# and error-path exits via a trap.
#
# AAP Reference
# -------------
# AAP §0.6.2 — `benchmarks/run-baseline.sh` (this file).
# AAP §0.5.3 — methodology: concurrency ladder, 30 s sustained, 10 s warm-up
#              discarded, 2 s inter-rung quiesce, GET / request mix.
#
# Make executable with: `chmod +x run-baseline.sh`
#
# Constraints Honored
# -------------------
#   C-001 — Source files immutable: ../server.js is launched as-is. No edits
#           to [server.js:L1-L14], the root package.json, root
#           package-lock.json, or root README.md are performed.
#   C-002 — Zero application deps: autocannon resolves EXCLUSIVELY from
#           $BENCH_DIR/node_modules/.bin/ via `npx --no-install`. The
#           application's root node_modules/ is never created or modified.
#   C-003 — Single-purpose server: load is driven only against GET / at the
#           single endpoint defined in [server.js:L6-L10]; no routing,
#           middleware, or alternate response paths are introduced.
#   C-004 — Hardcoded host/port: HOST=127.0.0.1 and PORT=3000 are bash
#           literals matching [server.js:L3] and [server.js:L4]; no
#           environment-variable overrides for HOST or PORT are accepted.
#
# Exit Codes
# ----------
#   0 — success (every scenario produced an autocannon-<N>.json file)
#   2 — pre-flight failure (missing node, server.js, load-profile.json,
#       autocannon, or curl)
#   3 — port 3000 already bound (Assumption A-002, AAP §0.7)
#   4 — server failed to become ready within the readiness timeout
#
# Outputs (written to $RESULTS_DIR == benchmarks/results/<timestamp>/)
# --------------------------------------------------------------------
#   autocannon-<N>.json        per-rung machine-readable load-generator report
#                              (one file per concurrency rung in the ladder)
#   run-manifest.json          run metadata (timestamp, node version, platform,
#                              host, port, url, server script, results dir,
#                              load profile, ulimit_n, autocannon_version,
#                              scenarios that ran, produced filenames). The
#                              ulimit_n and autocannon_version fields are
#                              canonical environmental metadata per
#                              docs/performance/05-latency-and-throughput.md
#                              ("Data Sources").
#   server.stdout.log          captured stdout of the server (the single
#                              startup log line per [server.js:L13])
#   server.stderr.log          captured stderr of the server (empty unless
#                              the server emitted diagnostics)

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
#
# The script is intentionally invokable from any working directory; SCRIPT_DIR
# is resolved via BASH_SOURCE so that relative paths (../server.js,
# ./load-profile.json) always anchor to the script's own directory.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$SCRIPT_DIR"
SERVER_SCRIPT="$BENCH_DIR/../server.js"

# HOST and PORT are bash literals matching [server.js:L3] and [server.js:L4]
# per Constraint C-004 — they are NOT sourced from environment variables.
HOST="127.0.0.1"
PORT=3000
URL="http://${HOST}:${PORT}/"

LOAD_PROFILE="$BENCH_DIR/load-profile.json"
TIMESTAMP=$(date +%s)
RESULTS_DIR="$BENCH_DIR/results/$TIMESTAMP"

# Readiness poll budget — 10 s at 0.2 s intervals = 50 attempts.
READINESS_TIMEOUT_S=10

# Inter-rung quiesce window (seconds). Allows the server and the load
# generator to settle (socket TIME_WAIT drain, GC) between rungs. Matches
# load-profile.json:meta.inter_rung_quiesce_seconds.
INTER_RUNG_QUIESCE_S=2

# Mutable PID slot — guarded in the cleanup trap (initialized empty so an
# early-failure trap firing under `set -u` does not hit an unbound variable).
SERVER_PID=""

# ---------------------------------------------------------------------------
# Pre-flight checks (Phase 3)
#
# Each check exits early with a clear operator-facing message and a stable
# exit code (see "Exit Codes" header). Checks are ordered cheapest-first so
# missing binaries are surfaced before the more expensive port probe.
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: 'node' is not on PATH. Install Node.js (>=20.0.0) and retry." >&2
  exit 2
fi

if [ ! -f "$SERVER_SCRIPT" ]; then
  echo "ERROR: Cannot locate server.js at $SERVER_SCRIPT" >&2
  exit 2
fi

if [ ! -f "$LOAD_PROFILE" ]; then
  echo "ERROR: Cannot locate load profile at $LOAD_PROFILE" >&2
  exit 2
fi

AUTOCANNON_BIN="$BENCH_DIR/node_modules/.bin/autocannon"
if [ ! -x "$AUTOCANNON_BIN" ]; then
  echo "ERROR: autocannon is not installed. Run 'npm install' inside the benchmarks/ directory first." >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: 'curl' is not on PATH. curl is required for readiness checks." >&2
  exit 2
fi

# Port-availability check.
# Strategy (in preference order):
#   1. lsof -nP -iTCP:$PORT -sTCP:LISTEN  (most informative, most common)
#   2. ss -ltn 'sport = :$PORT'           (Linux iproute2 fallback)
#   3. node -e TCP connect probe          (final fallback; uses Node built-in net)
# A successful match by any strategy means something is already listening on
# $PORT and we must abort with exit code 3 per Assumption A-002.
port_in_use=0
if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    port_in_use=1
  fi
elif command -v ss >/dev/null 2>&1; then
  if ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
    port_in_use=1
  fi
else
  # Final fallback — attempt a TCP connect; success means something is listening.
  if node -e "const s=require('net').connect({host:'${HOST}',port:${PORT}}); s.on('connect',()=>{s.destroy();process.exit(0)}); s.on('error',()=>process.exit(1));" >/dev/null 2>&1; then
    port_in_use=1
  fi
fi

if [ "$port_in_use" -eq 1 ]; then
  echo "ERROR: Port $PORT is already in use. Stop the existing process before running this script." >&2
  echo "       Assumption A-002 (AAP §0.7) — a second instance fails with EADDRINUSE." >&2
  exit 3
fi

# ulimit -n soft warning. The c=1000 rung opens 1000 simultaneous outbound
# sockets plus the listening accept queue; if the soft FD limit is below
# 65535 the kernel may refuse new sockets and the rung's measurements will
# be skewed by EMFILE/EAGAIN, NOT by the server's actual capacity. The
# 65535 threshold matches the canonical FD-pressure recommendation
# documented as R2 in docs/performance/00-executive-summary.md and
# docs/performance/09-optimization-recommendations.md ("Raise the process
# file-descriptor limit before measurement"). We warn but do not exit —
# the operator may legitimately want to run a degraded c=1000 rung to
# characterize FD-saturation behavior, or may be running only the
# lower-concurrency rungs where the soft limit is non-binding.
ULIMIT_NOFILE=$(ulimit -n 2>/dev/null || echo 0)
if [ "$ULIMIT_NOFILE" != "unlimited" ] && [ "$ULIMIT_NOFILE" -lt 65535 ] 2>/dev/null; then
  echo "WARNING: ulimit -n is $ULIMIT_NOFILE (< 65535). The 1000-connection rung may" >&2
  echo "         saturate file descriptors. Consider raising with: ulimit -n 65535" >&2
fi

# ---------------------------------------------------------------------------
# Results directory (Phase 4)
# ---------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"
echo "Results directory: $RESULTS_DIR"

# ---------------------------------------------------------------------------
# Cleanup trap (registered as part of Phase 5)
#
# Registered BEFORE the server is launched so an early-failure trap still
# reaps any in-flight child process. SIGINT (NOT SIGKILL) is used so that
# any pending V8 exit hooks run to completion — this is consistent with the
# profiling scripts even though run-baseline.sh does not itself enable any
# --*-prof flag (a future operator may swap the launch line; consistency
# keeps the lifecycle invariant). The original $? is preserved through the
# cleanup body so the final exit reflects the underlying script failure
# rather than the success of the cleanup itself.
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  set +e
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -INT "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Launch server (Phase 5)
# ---------------------------------------------------------------------------
echo "Launching server: node $SERVER_SCRIPT"
node "$SERVER_SCRIPT" \
  > "$RESULTS_DIR/server.stdout.log" 2> "$RESULTS_DIR/server.stderr.log" &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# ---------------------------------------------------------------------------
# Await readiness (Phase 6)
#
# HTTP polling is the canonical readiness signal because the server only
# logs its startup line AFTER server.listen() completes its callback
# ([server.js:L12-L14]); a curl that succeeds is a stronger guarantee that
# the listening socket has been bound and is accepting connections than
# tailing stdout would be.
# ---------------------------------------------------------------------------
echo "Waiting for server readiness at $URL (timeout ${READINESS_TIMEOUT_S}s)..."
ready=0
for _ in $(seq 1 50); do
  if curl --silent --output /dev/null --max-time 1 "$URL"; then
    ready=1
    break
  fi
  # If the server has already died, surface its stderr immediately rather
  # than waiting out the full readiness window.
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "ERROR: Server process $SERVER_PID exited before becoming ready." >&2
    echo "----- server.stderr.log -----" >&2
    cat "$RESULTS_DIR/server.stderr.log" >&2 || true
    echo "-----------------------------" >&2
    exit 4
  fi
  sleep 0.2
done

if [ "$ready" -ne 1 ]; then
  echo "ERROR: Server did not become ready within ${READINESS_TIMEOUT_S}s." >&2
  echo "       See $RESULTS_DIR/server.stderr.log for diagnostics." >&2
  exit 4
fi
echo "Server ready at $URL (PID $SERVER_PID)."

# ---------------------------------------------------------------------------
# Concurrency ladder execution (Phase 7)
#
# Read the scenarios array from load-profile.json. jq is preferred when
# available because it yields a clean whitespace-separated triple per
# scenario; node -e is used as a fallback so the harness does not gain a
# hard dependency on jq (which is not in the Node.js ecosystem and may not
# be installed in every environment per AAP §0.8 "Tool choice is bounded").
#
# Both strategies emit one line per scenario in the form:
#   <connections> <duration> <warmup>
# which is consumed by the `read` loop below.
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  SCENARIO_LINES=$(jq -r '.scenarios[] | "\(.connections) \(.duration) \(.warmup)"' "$LOAD_PROFILE")
else
  SCENARIO_LINES=$(node -e "
    const fs = require('fs');
    const profile = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    if (!profile || !Array.isArray(profile.scenarios)) {
      process.stderr.write('ERROR: load-profile.json missing scenarios array\n');
      process.exit(1);
    }
    profile.scenarios.forEach((s) => {
      console.log(s.connections, s.duration, s.warmup);
    });
  " "$LOAD_PROFILE")
fi

if [ -z "$SCENARIO_LINES" ]; then
  echo "ERROR: No scenarios were read from $LOAD_PROFILE" >&2
  exit 2
fi

# Track scenarios that ran for the manifest at the end.
SCENARIOS_RUN=()
RESULT_FILES=()

# Iterate the ladder. `read` with a here-string (<<<) preserves the
# strict-mode contract: the loop body runs in the current shell so
# SCENARIOS_RUN / RESULT_FILES mutations are observed after the loop.
while read -r conn duration warmup; do
  # Guard against accidental blank lines from the parser.
  [ -z "$conn" ] && continue

  echo ""
  echo "=== Concurrency: ${conn}, Warmup: ${warmup}s, Duration: ${duration}s ==="

  # Warm-up pass — discard the output. `|| true` so an early-warmup
  # autocannon failure does not abort the whole script under `set -e`;
  # the measurement pass below is the authoritative attempt.
  echo "  warm-up (${warmup}s, output discarded)..."
  ( cd "$BENCH_DIR" && npx --no-install autocannon \
      -c "$conn" \
      -d "$warmup" \
      "$URL" ) >/dev/null 2>&1 || true

  # Quiesce — let TIME_WAIT sockets drain and the JIT settle.
  sleep "$INTER_RUNG_QUIESCE_S"

  # Measurement pass — capture machine-readable JSON.
  RESULT_FILE="$RESULTS_DIR/autocannon-${conn}.json"
  echo "  measurement (${duration}s, capturing JSON)..."
  ( cd "$BENCH_DIR" && npx --no-install autocannon \
      -c "$conn" \
      -d "$duration" \
      -j \
      "$URL" ) > "$RESULT_FILE"

  # One-line summary parsed from the JSON. autocannon's report uses
  # `requests.average` for RPS, `latency.p99` for the 99th-percentile
  # latency in milliseconds, and `non2xx` for the failed-response count.
  # Field-presence guards keep the summary printable even if autocannon's
  # report schema shifts between versions.
  node -e "
    const fs = require('fs');
    const path = process.argv[1];
    try {
      const r = JSON.parse(fs.readFileSync(path, 'utf8'));
      const rps = (r.requests && (r.requests.average != null ? r.requests.average : r.requests.mean));
      const p99 = (r.latency && r.latency.p99);
      const p50 = (r.latency && r.latency.p50);
      const non2xx = r.non2xx;
      const fmt = (v) => v == null ? 'n/a' : (typeof v === 'number' ? v.toFixed(2) : v);
      console.log('  Summary: RPS=' + fmt(rps) +
                  ', p50_latency_ms=' + fmt(p50) +
                  ', p99_latency_ms=' + fmt(p99) +
                  ', non2xx=' + (non2xx != null ? non2xx : 'n/a'));
    } catch (e) {
      console.log('  Summary: <unable to parse ' + path + ': ' + e.message + '>');
    }
  " "$RESULT_FILE"

  SCENARIOS_RUN+=("${conn}:${duration}:${warmup}")
  RESULT_FILES+=("autocannon-${conn}.json")

  # Inter-rung quiesce — same purpose as the post-warmup quiesce above.
  sleep "$INTER_RUNG_QUIESCE_S"
done <<< "$SCENARIO_LINES"

# ---------------------------------------------------------------------------
# Final server shutdown (Phase 8)
#
# Explicitly SIGINT the server now rather than relying on the EXIT trap.
# This means the manifest below is written AFTER the server has stopped,
# so the manifest reflects a complete, clean run. Clearing SERVER_PID
# afterwards prevents the EXIT trap from re-killing an already-reaped PID.
# ---------------------------------------------------------------------------
echo ""
echo "Stopping server..."
if kill -0 "$SERVER_PID" 2>/dev/null; then
  kill -INT "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
fi
SERVER_PID=""  # mark as reaped so the EXIT trap skips it

# ---------------------------------------------------------------------------
# Manifest (Phase 8 cont.)
#
# Records what actually ran. Field names mirror the snake_case convention
# already established in cpu-profile-manifest.json / heap-profile-manifest.json
# so docs/performance/ consumers can read all manifests with a single schema.
# ---------------------------------------------------------------------------
NODE_VERSION="$(node --version)"
PLATFORM_INFO="$(uname -srm)"
MANIFEST_FILE="$RESULTS_DIR/run-manifest.json"

# Resolve the installed autocannon version from its package metadata. This
# is a non-mutating read of the harness's own node_modules/ (the package
# is guaranteed to be present at this point in the script: the pre-flight
# check at L120-L123 above verified $AUTOCANNON_BIN is executable, and
# `npm install` is the only way to populate it). Reading the version from
# package.json — rather than parsing `autocannon --version` stdout —
# avoids spawning an extra process and is deterministic across autocannon
# major versions whose --version output format might change. The fallback
# string "unknown" is emitted only if the package.json is unexpectedly
# missing or unparseable, which would itself indicate a broken install.
# Recorded in the manifest as the load-bearing reproducibility field per
# docs/performance/05-latency-and-throughput.md ("Data Sources").
AUTOCANNON_VERSION="$(node -e 'try { process.stdout.write(require(process.argv[1]).version); } catch (e) { process.stdout.write("unknown"); }' "$BENCH_DIR/node_modules/autocannon/package.json" 2>/dev/null || echo unknown)"

# Build space-separated lists of scenarios that ran and produced filenames.
# Bash array expansion under `set -u` requires the ${arr[@]:-} guard when
# the array may be empty, though here we've already exited if no scenarios
# were enumerated.
SCENARIOS_STR="${SCENARIOS_RUN[*]}"
RESULT_FILES_STR="${RESULT_FILES[*]}"

node -e '
  const { writeFileSync } = require("fs");
  const [
    ,
    manifestFile,
    timestamp,
    nodeVersion,
    platform,
    host,
    port,
    url,
    serverScript,
    resultsDir,
    loadProfilePath,
    scenariosStr,
    resultFilesStr,
    ulimitN,
    autocannonVersion,
  ] = process.argv;
  const scenarios = scenariosStr
    .split(/\s+/)
    .filter(Boolean)
    .map((triple) => {
      const [connections, duration, warmup] = triple.split(":").map(Number);
      return { connections, duration, warmup };
    });
  const resultFiles = resultFilesStr.split(/\s+/).filter(Boolean);
  // ulimit_n is preserved as-is to retain the string "unlimited" when the
  // shell reports an unbounded soft FD limit; numeric values are coerced
  // via Number() and only emitted as numbers when the coercion is finite.
  // This keeps the canonical environmental record honest about what the
  // shell reported, per docs/performance/05-latency-and-throughput.md
  // ("Data Sources").
  let ulimitNField;
  if (ulimitN === "unlimited") {
    ulimitNField = "unlimited";
  } else {
    const n = Number(ulimitN);
    ulimitNField = Number.isFinite(n) && n >= 0 ? n : ulimitN;
  }
  const manifest = {
    timestamp,
    node_version: nodeVersion,
    platform,
    host,
    port: Number(port),
    url,
    server_script: serverScript,
    results_dir: resultsDir,
    load_profile: loadProfilePath,
    ulimit_n: ulimitNField,
    autocannon_version: autocannonVersion,
    scenarios,
    result_files: resultFiles,
    notes: "Latency/throughput baseline produced by benchmarks/run-baseline.sh. Per-rung autocannon JSON reports are consumed by docs/performance/05-latency-and-throughput.md. The application server was launched unprofiled (no --cpu-prof / --heap-prof / --inspect flags) so these numbers represent the canonical baseline; the profiling scripts produce interpretive numbers, not baseline numbers.",
  };
  writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + "\n");
' \
  "$MANIFEST_FILE" \
  "$TIMESTAMP" \
  "$NODE_VERSION" \
  "$PLATFORM_INFO" \
  "$HOST" \
  "$PORT" \
  "$URL" \
  "$SERVER_SCRIPT" \
  "$RESULTS_DIR" \
  "$LOAD_PROFILE" \
  "$SCENARIOS_STR" \
  "$RESULT_FILES_STR" \
  "$ULIMIT_NOFILE" \
  "$AUTOCANNON_VERSION"

echo "Manifest: $MANIFEST_FILE"
echo ""
echo "Baseline complete. Results: $RESULTS_DIR/"

# Phase 9 — implicit `exit 0`. The EXIT trap will fire and see SERVER_PID
# is empty, so no further kill is attempted.
