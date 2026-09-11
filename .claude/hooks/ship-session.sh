#!/usr/bin/env bash
# SessionEnd hook. Fires once — but capture no longer depends on this
# firing: track-edit.sh already captures transcript growth locally after
# every edit, so a crash or a PR opened mid-session doesn't lose
# reasoning. This does one final local catch-up capture (for whatever
# happened after the last edit), marks the session ended, sweeps ALL
# unsynced edits/chunks across ALL sessions (not just this one) once, and
# spawns the continuous flush daemon if anything's still pending after
# that. Failures here stay silent — the session exits cleanly either way.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTXHUB_DIR="$HOME/.claude/ctxhub"
DB="$CTXHUB_DIR/local.db"
SCHEMA="$HOOK_DIR/schema.sql"
CHUNK_DIR="$CTXHUB_DIR/chunks"
PID_FILE="$CTXHUB_DIR/flush.pid"

command -v sqlite3 >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

mkdir -p "$CTXHUB_DIR"
# shellcheck source=lib.sh
. "$HOOK_DIR/lib.sh"

# Substituted by the GitHub App bootstrap commit for this repo (one shared
# key per repo, not per developer) — literal placeholders below mean "not
# configured yet" and delivery is skipped. Env vars still take precedence,
# for local testing without needing a real committed key.
CTXHUB_INGEST_URL="${CTXHUB_INGEST_URL:-https://api.witness.membranelabs.org}"
CTXHUB_API_KEY="${CTXHUB_API_KEY:-bXmf2rOzqFL7XYtSQfzt8S8HzBk1gNqAfRbuf5G3xrc}"

payload="$(cat)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
transcript_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"

[ -z "$session_id" ] && exit 0

sql "$DB" < "$SCHEMA" 2>/dev/null

# No sidecar rows for this session -> no edits happened, nothing to ship.
has_edits="$(sql "$DB" "SELECT COUNT(*) FROM edits WHERE session_id = '$(esc "$session_id")';" 2>/dev/null)"
[ "${has_edits:-0}" = "0" ] && exit 0

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Final local catch-up: reasoning that happened after the last edit.
capture_transcript_delta "$DB" "$session_id" "$transcript_path" "$now" "$CHUNK_DIR"

sql "$DB" "UPDATE sessions SET ended = 1, ended_at = '$(esc "$now")' WHERE session_id = '$(esc "$session_id")';" >/dev/null 2>&1

# Nothing to deliver to without server config — local copy is already safe;
# leave rows unsynced for the next hook fire to retry.
ctxhub_configured || exit 0

# One-shot sweep of ALL unsynced edits/chunks across ALL sessions.
flush_all_pending "$DB"

# Anything still pending after that (network was down, server rejected a
# request, whatever) gets a continuous retry worker — self-terminating,
# not a persistent daemon; see flush-daemon.sh.
spawn_flush_daemon "$DB" "$HOOK_DIR" "$PID_FILE"

exit 0
