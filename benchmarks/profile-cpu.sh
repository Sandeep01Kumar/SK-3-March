#!/usr/bin/env bash
# benchmarks/profile-cpu.sh
#
# Purpose
# -------
# Capture V8 CPU profile of ../server.js under sustained load. The script
# launches `node --inspect=127.0.0.1:9229 ../server.js` (which exposes the
# V8 Inspector socket on the loopback interface), starts the
# inspector-driver helper which speaks the Chrome DevTools Protocol (CDP)
# over a WebSocket connection to that inspector socket. The driver
# programmatically enables and starts the V8 CPU profiler via
# Profiler.start, sleeps for a fixed window that brackets the autocannon
# load period, then reads back the profile data via Profiler.stop and
# writes it to a .cpuprofile file in $RESULTS_DIR. Finally the driver
# asks the inspected process to exit cleanly via Runtime.evaluate
# (`process.exit(0)`), which lets the harness reap the server PID
# without any signal-handling races.
#
# AAP Reference
# -------------
# AAP §0.6.2 — `benchmarks/profile-cpu.sh`.
#
# Why CDP-driven Profile Capture (root cause of QA Issue #1)
# ----------------------------------------------------------
# An earlier revision of this script launched the server with the V8
# `--cpu-prof` runtime flag and used SIGINT for shutdown. That mechanism
# requires the inspected process to exit *gracefully* — either by event
# loop drain or by an explicit process.exit() call — so that V8's
# `before-exit` / `exit` hooks run and flush the .cpuprofile file. When
# SIGINT is delivered to a Node.js process that has installed no custom
# signal handler (which is exactly the state of [server.js:L1-L14] under
# Constraint C-001), the process terminates via the default signal action
# and the V8 exit hooks do NOT run, so no .cpuprofile is written. QA
# verified this by direct experiment (Test A in the QA report).
#
# The fix is to use the V8 Inspector Protocol for *both* profile capture
# and shutdown. Profile data is retrieved synchronously over the WebSocket
# via Profiler.stop, which returns the same JSON shape that --cpu-prof
# would have written, but it requires no graceful-exit timing. Once the
# profile is safely on disk, the driver issues Runtime.evaluate(
# `process.exit(0)`) so the server exits cleanly and the harness can
# reap it with a normal `wait`. This approach is QA-recommended
# Option C ("READY — no constraint relaxation needed") per the QA report.
#
# Symmetry with profile-heap.sh
# -----------------------------
# This script is the structural twin of profile-heap.sh. The only
# differences are the inspector-driver --mode flag (cpu vs heap), the
# profile filename glob (CPU.*.cpuprofile vs Heap.*.heapprofile), the
# autocannon output filename, the manifest filename, and the echo strings.
# Any other divergence between the two files is a defect.
#
# Constraints Honored
# -------------------
#   C-001 — Source files immutable: ../server.js is launched as-is with the
#           runtime --inspect flag applied to the `node` process, never to
#           the source file. No edits to [server.js:L1-L14] are made.
#   C-002 — Zero application deps: autocannon resolves EXCLUSIVELY from
#           $BENCH_DIR/node_modules/.bin/ via `npx --no-install`. The
#           inspector-driver helper uses ONLY Node.js built-in modules
#           (node:net, node:crypto, node:http, node:fs). The application's
#           root node_modules/, package.json, and package-lock.json are
#           untouched.
#   C-003 — Single-purpose server: the script drives only GET / against the
#           single endpoint at [server.js:L6-L10]; the inspector connection
#           is for measurement only — it makes exactly one Runtime.evaluate
#           call (the terminal process.exit(0)) and consumes no application
#           routes, middleware, or alternate response paths.
#   C-004 — Hardcoded host/port: HOST=127.0.0.1 and PORT=3000 are bash literals
#           matching [server.js:L3] and [server.js:L4]; no environment-variable
#           overrides are accepted. The inspector port (9229) is also a bash
#           literal and the standard Node.js inspector default.
#
# Exit Codes
# ----------
#   0 — success (profile captured and persisted)
#   2 — pre-flight failure (missing node, server.js, autocannon, or curl)
#   3 — port 3000 already bound (Assumption A-002, AAP §0.7)
#   4 — server failed to become ready within the readiness timeout
#   5 — profile capture failed (driver did not produce a non-empty .cpuprofile)
# 130 — interrupted by SIGINT (cleanup ran)
# 143 — interrupted by SIGTERM (cleanup ran)
#
# Outputs (written to $RESULTS_DIR == benchmarks/results/<timestamp>/)
# --------------------------------------------------------------------
#   CPU.<YYYYMMDD>.<HHMMSS>.<server_pid>.0.001.cpuprofile
#                                                V8 CPU profile artifact
#                                                (same JSON shape as the
#                                                V8 --cpu-prof flag would
#                                                emit; consumable by Chrome
#                                                DevTools Performance tab
#                                                and by Speedscope).
#   autocannon-during-cpuprof.json               load generator's machine-readable report
#   cpu-profile-manifest.json                    run metadata (timestamp, node version, params)
#   inspector-driver.log                         stdout/stderr of the inspector-driver helper
#   server.stdout.log                            captured stdout of the server (includes startup log line)
#   server.stderr.log                            captured stderr of the server (includes inspector listen line)

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$SCRIPT_DIR"
SERVER_SCRIPT="$BENCH_DIR/../server.js"
INSPECTOR_DRIVER="$BENCH_DIR/inspector-driver.mjs"
HOST="127.0.0.1"
PORT=3000
URL="http://${HOST}:${PORT}/"
INSPECTOR_PORT=9229
TIMESTAMP=$(date +%s)
RESULTS_DIR="$BENCH_DIR/results/$TIMESTAMP"

# Load-generation parameters. 30 s sustained at 100 concurrent connections
# matches the c100 rung in benchmarks/load-profile.json and is long enough to
# populate the V8 CPU profile sample buffer (default 1 ms sampling interval,
# overridden to 100 µs in inspector-driver.mjs for higher resolution) with
# representative on-CPU symbols while keeping wall-clock time bounded.
LOAD_DURATION=30
LOAD_CONNECTIONS=100

# Profile duration brackets the load period with a small guard window so the
# profile fully covers the autocannon run even with ramp-up jitter. The
# driver starts the profile a moment before autocannon begins firing requests
# (the bash script sleeps DRIVER_WARMUP_S after launching the driver to give
# it time to connect to the inspector socket and start sampling) and stops
# the profile a moment after autocannon completes.
DRIVER_WARMUP_S=1
PROFILE_TAIL_S=2
PROFILE_DURATION_MS=$(( (LOAD_DURATION + PROFILE_TAIL_S) * 1000 ))

# Readiness poll budget — 10 s at 0.2 s intervals = 50 attempts.
READINESS_TIMEOUT_S=10

# Mutable PID slots — guarded in the cleanup trap (initialized empty so an
# early-failure trap firing under `set -u` does not hit an unbound variable).
SERVER_PID=""
DRIVER_PID=""

# Idempotency flag for the cleanup function — see "Cleanup trap" below for
# the rationale.
CLEANUP_DONE=0

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

if [ ! -f "$INSPECTOR_DRIVER" ]; then
  echo "ERROR: Inspector driver helper not found at $INSPECTOR_DRIVER" >&2
  echo "       The helper is part of the harness repository; re-clone if missing." >&2
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

# Compute the .cpuprofile output filename in the same `CPU.<date>.<time>.<pid>.<id>.<seq>.cpuprofile`
# pattern that V8's `--cpu-prof` flag would have used. Using the same naming
# convention means Chrome DevTools, Speedscope, and any downstream tooling
# that globs for `CPU.*.cpuprofile` files keep working without changes.
DATE_TAG="$(date -u +%Y%m%d.%H%M%S)"
# The PID placeholder is filled after the server is launched; the filename
# is locked in just before invoking the driver.
PROFILE_FILE=""

# ---------------------------------------------------------------------------
# Cleanup trap
#
# Issue #3 fix: the previous version used `trap cleanup EXIT INT TERM` with
# the cleanup function ending in `exit "$rc"`. That captures the exit code
# of whatever command ran immediately before the trap fired, NOT the signal-
# induced exit code. The result was that a script interrupted via SIGINT
# still exited 0, which silently misleads CI / automation that distinguishes
# clean completion from operator interruption.
#
# The fix below splits the trap into three handlers — EXIT for normal exit
# (preserves the underlying script's exit code), INT for SIGINT (exits 130
# = 128+2), TERM for SIGTERM (exits 143 = 128+15). The cleanup body itself
# is idempotent via the CLEANUP_DONE guard so the EXIT trap firing after an
# INT/TERM trap does not double-reap an already-dead child.
# ---------------------------------------------------------------------------
cleanup() {
  if [ "${CLEANUP_DONE:-0}" -eq 1 ]; then return; fi
  CLEANUP_DONE=1
  set +e
  if [ -n "${DRIVER_PID:-}" ] && kill -0 "$DRIVER_PID" 2>/dev/null; then
    kill -INT "$DRIVER_PID" 2>/dev/null || true
    wait "$DRIVER_PID" 2>/dev/null || true
  fi
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -INT "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# Launch server with V8 Inspector enabled (no --cpu-prof flag — the profile
# is captured by the inspector-driver helper via the CDP Profiler domain).
# Binding the inspector to 127.0.0.1 keeps the debug surface on the loopback
# interface (matches [server.js:L3] hostname); the inspector port 9229 is
# the Node.js default.
# ---------------------------------------------------------------------------
echo "Launching server: node --inspect=${HOST}:${INSPECTOR_PORT} $SERVER_SCRIPT"
node "--inspect=${HOST}:${INSPECTOR_PORT}" "$SERVER_SCRIPT" \
  > "$RESULTS_DIR/server.stdout.log" 2> "$RESULTS_DIR/server.stderr.log" &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Now that we have the server PID, lock in the profile filename.
PROFILE_FILE="$RESULTS_DIR/CPU.${DATE_TAG}.${SERVER_PID}.0.001.cpuprofile"

# ---------------------------------------------------------------------------
# Await readiness — poll $URL with curl until the server responds, with a
# hard deadline of $READINESS_TIMEOUT_S seconds. The inspector-driver helper
# has its own retry loop for the inspector socket (the inspector binds a
# moment after the HTTP listener accepts connections), so we only need to
# confirm HTTP readiness here.
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
# Launch the inspector-driver helper. It connects to the V8 inspector at
# $HOST:$INSPECTOR_PORT, starts the V8 CPU profiler, sleeps for
# $PROFILE_DURATION_MS (which is LOAD_DURATION + PROFILE_TAIL_S seconds),
# stops the profiler, writes the .cpuprofile JSON to $PROFILE_FILE, then
# asks the inspected process to exit cleanly via Runtime.evaluate.
#
# The driver runs in the background so we can drive autocannon in parallel.
# After autocannon completes, we `wait` on the driver: it will already have
# stopped the profile (or will do so shortly thanks to PROFILE_TAIL_S) and
# will then signal the server to exit.
# ---------------------------------------------------------------------------
echo "Launching inspector-driver: profile=${PROFILE_FILE}, duration_ms=${PROFILE_DURATION_MS}"
node "$INSPECTOR_DRIVER" \
  "--mode=cpu" \
  "--duration-ms=${PROFILE_DURATION_MS}" \
  "--output=${PROFILE_FILE}" \
  "--inspector-host=${HOST}" \
  "--inspector-port=${INSPECTOR_PORT}" \
  > "$RESULTS_DIR/inspector-driver.log" 2>&1 &
DRIVER_PID=$!
echo "Driver PID: $DRIVER_PID"

# Brief delay to let the driver connect and start the profile before
# autocannon begins firing requests. Without this, the autocannon ramp-up
# window would land before the profiler is active and the early millisecond
# of samples would be missed.
sleep "$DRIVER_WARMUP_S"

# Confirm the driver is still alive after the warm-up.
if ! kill -0 "$DRIVER_PID" 2>/dev/null; then
  echo "ERROR: inspector-driver exited prematurely. Profile cannot be captured." >&2
  echo "----- inspector-driver.log -----" >&2
  cat "$RESULTS_DIR/inspector-driver.log" >&2 || true
  echo "--------------------------------" >&2
  exit 5
fi

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
# Wait for the inspector-driver to finish capturing and saving the profile.
# It is configured to run for LOAD_DURATION + PROFILE_TAIL_S seconds total,
# which is approximately PROFILE_TAIL_S seconds longer than autocannon, so
# this `wait` typically returns within 1-2 seconds of autocannon completing.
# Once the driver returns, it has already signalled the inspected server to
# exit via Runtime.evaluate(process.exit(0)).
# ---------------------------------------------------------------------------
echo "Waiting for inspector-driver to finalize profile..."
set +e
wait "$DRIVER_PID"
DRIVER_RC=$?
set -e
DRIVER_PID=""  # mark as reaped so the EXIT trap skips it
echo "Driver exit code: $DRIVER_RC"

# ---------------------------------------------------------------------------
# Wait for the server to exit. The driver already asked it to via process.exit(0)
# so it should exit cleanly within a beat. If it is still alive after a short
# grace window, fall back to SIGINT.
# ---------------------------------------------------------------------------
SERVER_DEADLINE=$(( $(date +%s) + 5 ))
while [ "$(date +%s)" -lt "$SERVER_DEADLINE" ]; do
  if [ -z "${SERVER_PID:-}" ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "WARNING: server still alive after Runtime.evaluate(process.exit); falling back to SIGINT."
  kill -INT "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
fi
SERVER_PID=""  # mark as reaped so the EXIT trap skips it

# ---------------------------------------------------------------------------
# Option A safety net (per QA report): if the driver failed or did not
# produce a non-empty .cpuprofile, surface the failure to the operator and
# exit non-zero so CI / follow-up scripts do not falsely conclude success.
# This is the read-the-mailbox check — even if every other step appears to
# have completed, the canonical artifact must exist for the analysis chapter
# to consume.
# ---------------------------------------------------------------------------
if [ "$DRIVER_RC" -ne 0 ]; then
  echo "ERROR: inspector-driver exited non-zero (rc=$DRIVER_RC)." >&2
  echo "       See $RESULTS_DIR/inspector-driver.log for diagnostics." >&2
fi

if [ ! -s "$PROFILE_FILE" ]; then
  echo "ERROR: No CPU profile was produced at $PROFILE_FILE" >&2
  echo "       inspector-driver log: $RESULTS_DIR/inspector-driver.log" >&2
  echo "       server stderr:        $RESULTS_DIR/server.stderr.log" >&2
  exit 5
fi

PROFILE_SIZE_BYTES=$(wc -c < "$PROFILE_FILE")
echo "Emitted CPU profile: $PROFILE_FILE (${PROFILE_SIZE_BYTES} bytes)"

# If the driver failed non-zero but the profile file exists and is non-empty,
# we still treat this as a defect — surface the driver exit code as the
# script's exit code.
if [ "$DRIVER_RC" -ne 0 ]; then
  exit 5
fi

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
    inspectorHost,
    inspectorPort,
    loadConnections,
    loadDurationS,
    profileDurationMs,
    autocannonReport,
    inspectorDriverLog,
    inspectorDriverScript,
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
    inspector_host: inspectorHost,
    inspector_port: Number(inspectorPort),
    load_connections: Number(loadConnections),
    load_duration_s: Number(loadDurationS),
    profile_duration_ms: Number(profileDurationMs),
    autocannon_report: autocannonReport,
    inspector_driver_log: inspectorDriverLog,
    inspector_driver_script: inspectorDriverScript,
    server_script: serverScript,
    results_dir: resultsDir,
    cpu_profile_dir: cpuProfDir,
    profile_files: profileFiles,
    capture_mechanism: "v8-inspector-protocol",
    notes: "CPU profile captured via V8 Chrome DevTools Protocol (Profiler.enable \u2192 Profiler.start \u2192 Profiler.stop) driven by benchmarks/inspector-driver.mjs. The .cpuprofile JSON is the same shape that the --cpu-prof runtime flag would have emitted. Inspect with Chrome DevTools (Performance tab \u2192 Load profile) or speedscope. An empty profile_files array indicates the driver failed; check inspector_driver_log for diagnostics.",
  };
  writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + "\n");
' \
  "$MANIFEST_FILE" \
  "$RESULTS_DIR" \
  "$TIMESTAMP" \
  "$NODE_VERSION" \
  "$HOST" \
  "$PORT" \
  "$URL" \
  "$HOST" \
  "$INSPECTOR_PORT" \
  "$LOAD_CONNECTIONS" \
  "$LOAD_DURATION" \
  "$PROFILE_DURATION_MS" \
  "$RESULTS_DIR/autocannon-during-cpuprof.json" \
  "$RESULTS_DIR/inspector-driver.log" \
  "$INSPECTOR_DRIVER" \
  "$SERVER_SCRIPT" \
  "$RESULTS_DIR"

echo "Manifest: $MANIFEST_FILE"
echo "CPU profile capture complete. Open with Chrome DevTools (Performance tab → Load profile) or Speedscope."
