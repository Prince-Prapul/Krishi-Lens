#!/usr/bin/env bash
# Continuous flush worker. NOT a Claude Code hook itself — never register
# this under settings.json's hooks block. It's spawned by ship-session.sh
# and session-start.sh when backlog remains after their one-shot sweep,
# detached (nohup + disown) so it survives the spawning hook process (and
# its parent Claude Code process) exiting.
#
# Self-terminates once caught up, or after a max runtime if delivery keeps
# failing — this deliberately does NOT run forever. Nothing supervises or
# restarts it: if it dies (crash, machine sleep, whatever), the next
# SessionStart/SessionEnd that still finds backlog just spawns a fresh one.
# That's the tradeoff for not registering with launchd/systemd — simpler,
# no OS-level install step, at the cost of "continuous" really meaning
# "for a while, opportunistically," not "guaranteed always running."
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${1:?db path required}"
CTXHUB_DIR="$HOME/.claude/ctxhub"
PID_FILE="$CTXHUB_DIR/flush.pid"
POLL_SECONDS="${CTXHUB_FLUSH_POLL_SECONDS:-60}"
MAX_RUNTIME_SECONDS="${CTXHUB_FLUSH_MAX_RUNTIME_SECONDS:-1800}"
EMPTY_PASSES_TO_EXIT="${CTXHUB_FLUSH_EMPTY_PASSES:-3}"

command -v sqlite3 >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=lib.sh
. "$HOOK_DIR/lib.sh"

CTXHUB_INGEST_URL="${CTXHUB_INGEST_URL:-https://api.witness.membranelabs.org}"
CTXHUB_API_KEY="${CTXHUB_API_KEY:-bXmf2rOzqFL7XYtSQfzt8S8HzBk1gNqAfRbuf5G3xrc}"
ctxhub_configured || exit 0

mkdir -p "$CTXHUB_DIR"
echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

start_ts=$(date +%s)
empty_passes=0

while :; do
  flush_all_pending "$DB"

  if has_pending "$DB"; then
    empty_passes=0
  else
    empty_passes=$((empty_passes + 1))
    [ "$empty_passes" -ge "$EMPTY_PASSES_TO_EXIT" ] && exit 0
  fi

  now_ts=$(date +%s)
  [ $((now_ts - start_ts)) -ge "$MAX_RUNTIME_SECONDS" ] && exit 0

  sleep "$POLL_SECONDS"
done
