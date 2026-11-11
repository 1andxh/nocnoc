#!/bin/sh
# nocnoc-hook.sh <agent> [wait-seconds] — forward an agent hook event to nocnoc.app.
#
#   nocnoc-hook.sh claude          notify only; returns at once
#   nocnoc-hook.sh claude 300      for PermissionRequest: nocnoc may hold this
#                                  call up to ~300s waiting for your Allow/Deny
#
# Set the agent's own hook timeout ABOVE wait-seconds (e.g. 320 for 300), so
# the order of giving up is always: nocnoc app -> curl -> agent.
#
# Contract with the agent:
#   stdin  = the hook event JSON the agent sends
#   stdout = ONLY what nocnoc replies: empty ("no decision") or a decision JSON
#   exit   = always 0
# If the app isn't running, or anything at all goes wrong, this prints nothing
# and the agent carries on exactly as if nocnoc didn't exist.

AGENT="${1:-claude}"
WAIT="${2:-0}"
case "$WAIT" in ''|*[!0-9]*) WAIT=0 ;; esac
SOCK="${NOCNOC_SOCKET:-$HOME/Library/Application Support/nocnoc/nocnoc.sock}"

# Always drain stdin first, even if we bail out below.
INPUT="$(cat)"

[ -S "$SOCK" ] || exit 0

# --fail: on an HTTP error, print nothing.  --max-time: the app answers within
# WAIT (minus its margin); +5s covers the round trip.  'Expect:' stops curl
# pausing ~1s on bigger bodies.  Captured into a variable so a half-finished
# reply is never printed.
REPLY="$(printf '%s' "$INPUT" | curl --silent --fail --max-time "$((WAIT + 5))" \
  --unix-socket "$SOCK" \
  -H 'Content-Type: application/json' -H 'Expect:' \
  -H "X-Nocnoc-Wait: $WAIT" \
  -H "X-Nocnoc-Project-Dir: ${CLAUDE_PROJECT_DIR:-}" \
  --data-binary @- "http://nocnoc/v1/hooks/$AGENT" 2>/dev/null)" || exit 0

[ -n "$REPLY" ] && printf '%s\n' "$REPLY"
exit 0
