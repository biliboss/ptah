#!/usr/bin/env bash
# ensure-tts.sh — idempotent guarantee that agent-tts can speak:
#   1. libpiper.dylib exists at the vendor path the binary expects
#   2. faber pt voice is installed
#   3. daemon socket is live
#
# Safe to invoke from launchd RunAtLoad, login hooks, or manually.
# Exits 0 if everything is healthy after the run, non-zero otherwise.

set -euo pipefail

REPO="$HOME/.obsidian/99-development/agent-tts"
VENDOR_LIB="$REPO/vendor/piper1-gpl/libpiper/dist/lib"
DYLIB="$VENDOR_LIB/libpiper.dylib"
SOCK="$HOME/.cache/agent-tts/sock"
VOICE_DIR="$HOME/.cache/agent-tts/voices"
FABER_ONNX="$VOICE_DIR/pt_BR-faber-medium.onnx"
LOG_DIR="$HOME/.cache/agent-tts"
LOG_FILE="$LOG_DIR/ensure.log"

mkdir -p "$LOG_DIR"
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE" >&2; }

log "ensure-tts.sh start (pid=$$)"

# ---------------------------------------------------------------------------
# 1. libpiper.dylib
# ---------------------------------------------------------------------------

if [[ ! -f "$DYLIB" ]]; then
  log "libpiper.dylib missing at $DYLIB — building"
  bash "$REPO/scripts/build-libpiper.sh" >>"$LOG_FILE" 2>&1 || true

  # The install step of build-libpiper.sh tries /usr/local which needs sudo
  # and fails non-fatally. The artifact still lands in the build tree.
  SRC=$(find /tmp -maxdepth 6 -name libpiper.dylib -path '*/libpiper/build/*' 2>/dev/null | head -1)
  if [[ -z "${SRC:-}" || ! -f "$SRC" ]]; then
    log "ERROR: build finished but no libpiper.dylib found under /tmp"
    exit 1
  fi
  mkdir -p "$VENDOR_LIB"
  cp "$SRC" "$DYLIB"
  log "copied $SRC -> $DYLIB"
else
  log "libpiper.dylib present"
fi

# Sanity: can the agent-tts binary load it?
if ! /opt/homebrew/bin/agent-tts --version >/dev/null 2>&1; then
  log "ERROR: agent-tts binary still cannot link libpiper.dylib"
  /opt/homebrew/bin/agent-tts --version 2>>"$LOG_FILE" || true
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Faber pt voice
# ---------------------------------------------------------------------------

if [[ ! -f "$FABER_ONNX" ]]; then
  log "faber voice missing at $FABER_ONNX — fetching"
  bash "$REPO/scripts/fetch-voice.sh" >>"$LOG_FILE" 2>&1 || {
    log "WARN: fetch-voice.sh exited non-zero; daemon may still start but synth will fail"
  }
fi

# ---------------------------------------------------------------------------
# 3. Daemon
# ---------------------------------------------------------------------------
#
# Two modes:
#   ./ensure-tts.sh           — bootstrap then spawn daemon backgrounded, exit 0
#                                (good for terminal usage, scripts, etc.)
#   ./ensure-tts.sh --exec    — bootstrap then `exec` the daemon, replacing this
#                                shell. The daemon becomes the caller's direct
#                                child so launchd KeepAlive sees crashes.

if [[ "${1:-}" == "--exec" ]]; then
  log "exec'ing daemon (launchd mode)"
  rm -f "$SOCK"
  exec /opt/homebrew/bin/agent-tts daemon
fi

if [[ -S "$SOCK" ]] && /opt/homebrew/bin/agent-tts queue >/dev/null 2>&1; then
  log "daemon already responding on $SOCK"
  exit 0
fi

log "daemon not responsive — starting (background mode)"
rm -f "$SOCK"

nohup /opt/homebrew/bin/agent-tts daemon \
  >>"$LOG_DIR/daemon.out.log" 2>>"$LOG_DIR/daemon.err.log" &
DAEMON_PID=$!
log "spawned daemon pid=$DAEMON_PID"

for i in {1..20}; do
  if [[ -S "$SOCK" ]] && /opt/homebrew/bin/agent-tts queue >/dev/null 2>&1; then
    log "daemon up after ${i}x0.5s"
    exit 0
  fi
  sleep 0.5
done

log "ERROR: daemon did not come up within 10s; check $LOG_DIR/daemon.err.log"
exit 1
