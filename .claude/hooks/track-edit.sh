#!/usr/bin/env bash
# PostToolUse hook (Edit|MultiEdit|Write). Must stay fast: everything here
# is local I/O — SQLite writes plus reading the transcript's own
# append-only growth — no blocking network call. Delivery/retry happens
# opportunistically in the background here and, authoritatively, in
# ship-session.sh.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTXHUB_DIR="$HOME/.claude/ctxhub"
DB="$CTXHUB_DIR/local.db"
SCHEMA="$HOOK_DIR/schema.sql"
CHUNK_DIR="$CTXHUB_DIR/chunks"

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
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
tool_use_id="$(printf '%s' "$payload" | jq -r '.tool_use_id // empty')"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"

# Nothing to link without these — skip silently rather than error the hook.
[ -z "$session_id" ] && exit 0
[ -z "$tool_use_id" ] && exit 0
[ -z "$file_path" ] && exit 0

branch="$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null)"
repo="$(git -C "$cwd" remote get-url origin 2>/dev/null)"
commit_hash="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# tool_input.file_path is always absolute (Claude Code's Edit/Write
# contract) -- but PR resolution matches against GitHub's diff filenames,
# which are repo-relative. Normalize here so the two ever agree, on any
# developer's machine.
repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$repo_root" ] && [ "${file_path#"$repo_root"/}" != "$file_path" ]; then
  file_path="${file_path#"$repo_root"/}"
fi

sql "$DB" < "$SCHEMA" 2>/dev/null

sql "$DB" >/dev/null 2>&1 <<SQL
INSERT INTO sessions (session_id, transcript_path, first_seen_at, last_seen_at)
VALUES ('$(esc "$session_id")', '$(esc "$transcript_path")', '$(esc "$now")', '$(esc "$now")')
ON CONFLICT(session_id) DO UPDATE SET last_seen_at = excluded.last_seen_at;

INSERT OR IGNORE INTO edits (session_id, tool_use_id, file_path, branch, repo, ts, synced)
VALUES ('$(esc "$session_id")', '$(esc "$tool_use_id")', '$(esc "$file_path")', '$(esc "$branch")', '$(esc "$repo")', '$(esc "$now")', 0);
SQL

# Local, synchronous, no network: capture whatever the transcript has
# grown by since the last edit. This is what makes reasoning survive a
# session that never cleanly ends (crash, force-quit, or a PR opened
# while the session is still running) — it's on disk after every edit,
# not only once at SessionEnd.
capture_transcript_delta "$DB" "$session_id" "$transcript_path" "$now" "$CHUNK_DIR"

# Best-effort fire-and-forget delivery of this edit and this session's
# pending chunks. Fully detached so the hook never waits on the network;
# ship-session.sh is the authoritative retry sweep across all sessions.
if ctxhub_configured; then
  (
    body="$(jq -n --arg sid "$session_id" --arg tuid "$tool_use_id" --arg fpath "$file_path" \
                  --arg branch "$branch" --arg repo "$repo" --arg ts "$now" --arg commit_hash "$commit_hash" \
                  '{session_id:$sid, tool_use_id:$tuid, file_path:$fpath, branch:$branch, repo:$repo, ts:$ts, commit_hash:$commit_hash}')"
    if curl -fsS -m 3 -X POST "$CTXHUB_INGEST_URL/edits" \
         -H "Authorization: Bearer $CTXHUB_API_KEY" \
         -H "Content-Type: application/json" \
         -d "$body" >/dev/null 2>&1; then
      synced_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      sql "$DB" "UPDATE edits SET synced = 1, synced_at = '$(esc "$synced_at")' WHERE tool_use_id = '$(esc "$tool_use_id")';" >/dev/null 2>&1
    fi

    # Claude Code doesn't flush this tool call's own transcript entry to
    # disk on any wall-clock schedule -- confirmed empirically (10 checks,
    # 2s apart, over a real 22s window: file size never changed once) that
    # the write is gated on the *next* turn the agent takes, not time
    # passing. So no sleep duration here, however long, can guarantee this
    # specific entry has landed; a longer poll loop was tried and removed
    # for the same reason -- it just burns 20s of background CPU for zero
    # improvement over one attempt. This second pass is still worth doing
    # (already backgrounded, doesn't block the interactive hook, catches
    # whatever normal delivery lag happened to clear in the meantime) --
    # but the specific edit that triggered *this* hook call is expected to
    # remain uncaptured until a *later* edit's hook or SessionEnd runs,
    # by which point the agent's next turn has certainly flushed it.
    sleep 2
    capture_transcript_delta "$DB" "$session_id" "$transcript_path" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CHUNK_DIR"

    sql -separator '|' "$DB" "SELECT session_id, byte_start, byte_end, chunk_path FROM transcript_chunks WHERE session_id = '$(esc "$session_id")' AND synced = 0 ORDER BY byte_start;" 2>/dev/null | \
    while IFS='|' read -r csid cbs cbe cpath; do
      deliver_chunk "$DB" "$csid" "$cbs" "$cbe" "$cpath"
    done
  ) &
  disown
fi

exit 0
