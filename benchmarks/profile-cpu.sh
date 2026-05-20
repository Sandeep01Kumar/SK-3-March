#!/usr/bin/env bash
# benchmarks/profile-cpu.sh
#
# Purpose
# -------
# Capture V8 CPU profile of ../server.js under sustained load. The script
# launches `node --cpu-prof --cpu-prof-dir=$RESULTS_DIR ../server.js` (which
# writes a CPU.<pid>.<id>.<seq>.<thread>.cpuprofile to $RESULTS_DIR when the
# process exits cleanly), drives sustained load via autocannon for a fixed
# duration, then SIGINTs the server to trigger profile emission. The emitted
# .cpuprofile is collected into the timestamped results directory.
#
# AAP Reference
# -------------
# AAP §0.6.2 — `benchmarks/profile-cpu.sh`.
#
# Symmetry with profile-heap.sh
# -----------------------------
# This script is the structural twin of profile-heap.sh. The only differences
# are the diagnostic flag (--cpu-prof vs --heap-prof), the directory variable
# name (CPU_PROF_DIR vs HEAP_PROF_DIR), the profile filename glob
# (CPU.*.cpuprofile vs Heap.*.heapprofile), the autocannon output filename,
# the manifest filename, and the echo strings. Any other divergence between
# the two files is a defect.
#
# Constraints Honored
# -------------------
#   C-001 — Source files immutable: ../server.js is launched as-is with the
#           diagnostic CLI flag applied to the `node` process, never to the
#           source file. No edits to [server.js:L1-L14] are made.
#   C-002 — Zero application deps: autocannon resolves EXCLUSIVELY from
#           $BENCH_DIR/node_modules/.bin/ via `npx --no-install`. The
#           application's root node_modules/, package.json, and
#           package-lock.json are untouched.
#   C-003 — Single-purpose server: the script drives only GET / against the
#           single endpoint at [server.js:L6-L10]; no routing, middleware, or
#           alternate response paths are introduced.
#   C-004 — Hardcoded host/port: HOST=127.0.0.1 and PORT=3000 are bash literals
#           matching [server.js:L3] and [server.js:L4]; no environment-variable
#           overrides are accepted.
#
# Exit Codes
# ----------
#   0 — success
#   2 — pre-flight failure (missing node, server.js, autocannon, or curl)
#   3 — port 3000 already bound (Assumption A-002, AAP §0.7)
#   4 — server failed to become ready within the readiness timeout
#
# Outputs (written to $RESULTS_DIR == benchmarks/results/<timestamp>/)
# --------------------------------------------------------------------
#   CPU.<pid>.<id>.<seq>.<thread>.cpuprofile     V8 CPU profile artifact(s)
#   autocannon-during-cpuprof.json               load generator's machine-readable report
#   cpu-profile-manifest.json                    run metadata (timestamp, node version, params)
#   server.stdout.log                            captured stdout of the server
#   server.stderr.log                            captured stderr of the server

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
TIMESTAMP=$(date +%s)
RESULTS_DIR="$BENCH_DIR/results/$TIMESTAMP"

# --cpu-prof writes the .cpuprofile into CPU_PROF_DIR. Point it directly at
# RESULTS_DIR so no post-hoc move is required.
CPU_PROF_DIR="$RESULTS_DIR"

# Load-generation parameters. 30 s sustained at 100 concurrent connections
# matches the c100 rung in benchmarks/load-profile.json and is long enough to
# populate the V8 CPU profile sample buffer (1 ms default sampling interval)
# with representative on-CPU symbols while keeping wall-clock time bounded.
LOAD_DURATION=30
LOAD_CONNECTIONS=100

# Readiness poll budget — 10 s at 0.2 s intervals = 50 attempts.
READINESS_TIMEOUT_S=10

# Mutable PID slot — guarded in the cleanup trap (initialized empty so an
# early-failure trap firing under `set -u` does not hit an unbound variable).
SERVER_PID=""

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
  echo "       Run 'npm install' inside the benchmarks/ directory first." >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: 'curl' is not on PATH. curl is required for readiness checks." >&2
  exit 2
fi

# Port-availability check (mirror run-baseline.sh strategy):
# Try lsof first, then ss, then fall back to a node TCP connect probe.
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

# ---------------------------------------------------------------------------
# Results directory
# ---------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"
echo "Results directory: $RESULTS_DIR"

# ---------------------------------------------------------------------------
# Cleanup trap — registered BEFORE the server is launched so an early failure
# still reaps the child process. SIGINT is used (NOT SIGKILL) because the
# --cpu-prof flag only writes the profile on graceful exit; SIGKILL would
# bypass V8's exit hooks and the profile would be lost.
# ---------------------------------------------------------------------------
cleanup() {
  # Capture and preserve the original exit code so each step below cannot
  # abort cleanup partway through under set -e.
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
# Launch server with V8 CPU profiling enabled
# ---------------------------------------------------------------------------
echo "Launching server: node --cpu-prof --cpu-prof-dir=$CPU_PROF_DIR $SERVER_SCRIPT"
node --cpu-prof --cpu-prof-dir="$CPU_PROF_DIR" "$SERVER_SCRIPT" \
  > "$RESULTS_DIR/server.stdout.log" 2> "$RESULTS_DIR/server.stderr.log" &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# ---------------------------------------------------------------------------
# Await readiness — poll $URL with curl until the server responds, with a
# hard deadline of $READINESS_TIMEOUT_S seconds.
# ---------------------------------------------------------------------------
echo "Waiting for server readiness at $URL (timeout ${READINESS_TIMEOUT_S}s)..."
ready=0
for _ in $(seq 1 50); do
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
  sleep 0.2
done

if [ "$ready" -ne 1 ]; then
  echo "ERROR: Server did not become ready within ${READINESS_TIMEOUT_S}s." >&2
  exit 4
fi
echo "Server ready at $URL (PID $SERVER_PID)."

# ---------------------------------------------------------------------------
# Apply sustained load with autocannon. Run from $BENCH_DIR so
# `npx --no-install` resolves autocannon from $BENCH_DIR/node_modules/.bin/
# without consulting the registry (Constraint C-002).
# ---------------------------------------------------------------------------
echo "Applying ${LOAD_CONNECTIONS} concurrent connections for ${LOAD_DURATION}s..."
( cd "$BENCH_DIR" && npx --no-install autocannon \
    -c "$LOAD_CONNECTIONS" \
    -d "$LOAD_DURATION" \
    -j "$URL" ) > "$RESULTS_DIR/autocannon-during-cpuprof.json"
echo "Load complete."

# ---------------------------------------------------------------------------
# Stop the server with SIGINT to trigger CPU profile emission. SIGKILL would
# discard the profile because V8 only writes the .cpuprofile via its exit
# hooks. The explicit kill-and-wait here, followed by clearing SERVER_PID,
# ensures the EXIT trap skips a redundant second SIGINT on the same PID.
# ---------------------------------------------------------------------------
echo "Stopping server to emit CPU profile..."
if kill -0 "$SERVER_PID" 2>/dev/null; then
  kill -INT "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
fi
SERVER_PID=""  # mark as reaped so the EXIT trap skips it

echo "Emitted CPU profiles:"
ls -1 "$CPU_PROF_DIR"/CPU.*.cpuprofile 2>/dev/null || echo "  (none — see $RESULTS_DIR/server.stderr.log)"

# ---------------------------------------------------------------------------
# Manifest — record run metadata and the list of emitted .cpuprofile files.
# Uses fs.readdirSync to enumerate emitted profiles and fs.writeFileSync to
# atomically persist the manifest JSON.
# ---------------------------------------------------------------------------
NODE_VERSION="$(node --version)"
MANIFEST_FILE="$RESULTS_DIR/cpu-profile-manifest.json"
node -e '
  const { readdirSync, writeFileSync } = require("fs");
  const [
    ,
    manifestFile,
    cpuProfDir,
    timestamp,
    nodeVersion,
    host,
    port,
    url,
    loadConnections,
    loadDurationS,
    autocannonReport,
    serverScript,
    resultsDir,
  ] = process.argv;
  let profileFiles = [];
  try {
    profileFiles = readdirSync(cpuProfDir)
      .filter((name) => name.startsWith("CPU.") && name.endsWith(".cpuprofile"))
      .sort();
  } catch (_e) {
    profileFiles = [];
  }
  const manifest = {
    timestamp,
    node_version: nodeVersion,
    host,
    port: Number(port),
    url,
    load_connections: Number(loadConnections),
    load_duration_s: Number(loadDurationS),
    autocannon_report: autocannonReport,
    server_script: serverScript,
    results_dir: resultsDir,
    cpu_profile_dir: cpuProfDir,
    profile_files: profileFiles,
    notes: "CPU profile emitted by node --cpu-prof on graceful (SIGINT) shutdown. Inspect with Chrome DevTools (Performance tab \u2192 Load profile) or speedscope. An empty profile_files array indicates the server did not run V8 exit hooks before terminating (see server.stderr.log).",
  };
  writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + "\n");
' \
  "$MANIFEST_FILE" \
  "$CPU_PROF_DIR" \
  "$TIMESTAMP" \
  "$NODE_VERSION" \
  "$HOST" \
  "$PORT" \
  "$URL" \
  "$LOAD_CONNECTIONS" \
  "$LOAD_DURATION" \
  "$RESULTS_DIR/autocannon-during-cpuprof.json" \
  "$SERVER_SCRIPT" \
  "$RESULTS_DIR"

echo "Manifest: $MANIFEST_FILE"
echo "CPU profile capture complete. Open with Chrome DevTools (Performance tab → Load profile) or Speedscope."
