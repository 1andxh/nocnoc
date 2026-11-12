#!/bin/sh
# Show a demo card on the running nocnoc, for screenshots.
#
#   scripts/demo-cards.sh permission    # a Bash permission request
#   scripts/demo-cards.sh question      # an AskUserQuestion with options
#
# The payloads are fake (project "acme-web", a made-up command) but have the
# same shape Claude Code sends, so the card is the real UI. Nothing runs when
# you click Allow: the answer comes back to this script's curl and is printed,
# because there's no agent waiting on the other end.
#
# Needs Away on. The card stays up to 15 minutes; Esc dismisses it.
set -eu

SOCK="${NOCNOC_SOCKET:-$HOME/Library/Application Support/nocnoc/nocnoc.sock}"
KIND="${1:-permission}"

HEALTH="$(curl -s --fail --unix-socket "$SOCK" http://nocnoc/v1/health)" \
  || { echo "demo-cards.sh: nocnoc isn't running" >&2; exit 1; }
case "$HEALTH" in
  *'"away":true'*) ;;
  *) echo "demo-cards.sh: turn Away on first (cards only show while Away)" >&2; exit 1 ;;
esac

case "$KIND" in
  permission)
    BODY='{
      "hook_event_name": "PermissionRequest",
      "session_id": "demo-session",
      "cwd": "/Users/demo/acme-web",
      "tool_name": "Bash",
      "tool_input": {
        "command": "npm run db:migrate -- --env staging",
        "description": "Apply the pending users-table migration to the staging database"
      }
    }' ;;
  question)
    BODY='{
      "hook_event_name": "PermissionRequest",
      "session_id": "demo-session",
      "cwd": "/Users/demo/acme-web",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [{
          "header": "Sessions",
          "question": "Where should the login flow keep sessions?",
          "multiSelect": false,
          "options": [
            {"label": "Redis", "description": "Fast, shared across servers; one more service to run"},
            {"label": "Postgres table", "description": "No new infrastructure; slightly slower lookups"},
            {"label": "Signed cookie", "description": "Stateless, but sessions cannot be revoked early"}
          ]
        }]
      }
    }' ;;
  *) echo "usage: $0 permission|question" >&2; exit 1 ;;
esac

printf '%s' "$BODY" | curl -s --unix-socket "$SOCK" \
  -H 'Content-Type: application/json' -H 'Expect:' \
  -H 'X-Nocnoc-Wait: 900' -H 'X-Nocnoc-Project-Dir: /Users/demo/acme-web' \
  --data-binary @- http://nocnoc/v1/hooks/claude
echo
