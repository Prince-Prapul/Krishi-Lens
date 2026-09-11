#!/usr/bin/env bash
# SessionStart hook. Closes the gap a crashed/force-quit prior session
# leaves behind: if SessionEnd never fired, no flush-daemon was ever
# spawned for its leftover backlog. Does one immediate sweep, then spawns
# the continuous flush daemon if anything is still pending.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTXHUB_DIR="$HOME/.claude/ctxhub"
DB="$CTXHUB_DIR/local.db"
SCHEMA="$HOOK_DIR/schema.sql"
PID_FILE="$CTXHUB_DIR/flush.pid"

command -v sqlite3 >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

mkdir -p "$CTXHUB_DIR"
# shellcheck source=lib.sh
. "$HOOK_DIR/lib.sh"

CTXHUB_INGEST_URL="${CTXHUB_INGEST_URL:-https://api.witness.membranelabs.org}"
CTXHUB_API_KEY="${CTXHUB_API_KEY:-bXmf2rOzqFL7XYtSQfzt8S8HzBk1gNqAfRbuf5G3xrc}"

sql "$DB" < "$SCHEMA" 2>/dev/null

ctxhub_configured || exit 0

flush_all_pending "$DB"
spawn_flush_daemon "$DB" "$HOOK_DIR" "$PID_FILE"

exit 0
