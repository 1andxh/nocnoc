#!/bin/sh
# spy.sh <EventName> — Phase 0 spike. Records the JSON an agent sends to a hook.
# Never decides anything: prints nothing on stdout and always exits 0, which
# both Claude Code and Codex treat as "no opinion, carry on as normal".
#
# Optional blocking test: put a number in spike/sleep-seconds and
# PermissionRequest hooks will wait that long after logging, so you can watch
# whether the normal Allow/Deny prompt is visible while a hook is still running.

EVENT="${1:-unknown}"

# Log next to the repo root, found from this script's own location
# (.claude/hooks/spy.sh -> repo root), so it works for any agent, not just
# Claude (which is the only one that sets $CLAUDE_PROJECT_DIR).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="$ROOT/spike"
LOG_FILE="$LOG_DIR/hooks.log"
mkdir -p "$LOG_DIR"

{
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') $EVENT (pid $$, parent $PPID) ==="
  cat            # stdin -> log. Never let this reach stdout: stdout is the reply channel.
  echo
} >> "$LOG_FILE" 2>/dev/null || echo "spy.sh: could not write $LOG_FILE" >&2

if [ "$EVENT" = "PermissionRequest" ] && [ -f "$LOG_DIR/sleep-seconds" ]; then
  SECS="$(tr -dc '0-9' < "$LOG_DIR/sleep-seconds")"
  echo "--- $(date '+%H:%M:%S') sleeping ${SECS:-0}s" >> "$LOG_FILE"
  sleep "${SECS:-0}"
  echo "--- $(date '+%H:%M:%S') woke, returning no decision" >> "$LOG_FILE"
fi

exit 0
