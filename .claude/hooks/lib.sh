# Shared helpers for the CtxHub sidecar hooks. Sourced by track-edit.sh and
# ship-session.sh — not meant to be executed directly.

# SQLite string-literal escaping (single-quote doubling) — required
# anywhere untrusted input (file paths, branch names) is interpolated
# into SQL text.
esc() { printf '%s' "$1" | sed "s/'/''/g"; }

# busy_timeout must be set per-connection (unlike journal_mode, it isn't
# persisted in the DB file) so concurrent hook invocations from other
# sessions/repos queue for the write lock instead of failing immediately.
# Uses the ".timeout" CLI meta-command rather than "PRAGMA busy_timeout=…":
# the PRAGMA form echoes its new value to stdout as a side effect, which
# silently corrupts any caller that captures query output into a variable
# (e.g. "5000\n16" instead of "16") — .timeout sets the same thing without
# printing anything.
sql() { sqlite3 -cmd ".timeout 5000" "$@"; }

# Structural check, not a string-equality comparison against the literal
# placeholder — a bootstrap commit does a blind find/replace of the
# placeholder tokens, which would corrupt an equality check that repeats
# the same literal text. "__..__" is not a shape either value legitimately
# takes once substituted.
ctxhub_configured() {
  case "$CTXHUB_INGEST_URL" in __*__) return 1 ;; esac
  case "$CTXHUB_API_KEY" in __*__) return 1 ;; esac
  [ -n "$CTXHUB_INGEST_URL" ] && [ -n "$CTXHUB_API_KEY" ]
}

# Local, synchronous, no network: write whatever the transcript has grown
# by since the last capture straight to its own chunk file (tail -c on the
# append-only transcript, so this is always a clean byte-range suffix),
# then index it in SQLite. Safe to call from both PostToolUse (per edit)
# and SessionEnd (final catch-up) — that's what makes crash/long-session
# survival work: reasoning is durable on disk after every edit, not only
# at the end of a session that might never cleanly end.
#
# Content deliberately never passes through a bash variable — tail writes
# file-to-file directly. A bash $(...) capture strips trailing newlines,
# which would desync the stored content's length from byte_end.
capture_transcript_delta() {
  local db="$1" session_id="$2" transcript_path="$3" now="$4" chunk_dir="$5"
  local prev_bytes curr_bytes chunk_path settle_attempts next_bytes

  [ -n "$transcript_path" ] && [ -f "$transcript_path" ] || return 1

  prev_bytes="$(sql "$db" "SELECT COALESCE(transcript_bytes_captured,0) FROM sessions WHERE session_id = '$(esc "$session_id")';" 2>/dev/null)"
  case "$prev_bytes" in ''|*[!0-9]*) prev_bytes=0 ;; esac

  curr_bytes="$(wc -c < "$transcript_path" 2>/dev/null | tr -d ' ')"
  case "$curr_bytes" in ''|*[!0-9]*) return 1 ;; esac

  # Guard against reading mid-write: Claude Code appends this very tool
  # call's own tool_use/tool_result entry to the transcript file around
  # the same time it invokes this hook, and the two aren't guaranteed
  # ordered -- reading immediately can catch the file mid-append and
  # silently exclude the entry this edit is *about* from its own chunk.
  # Settle on two consecutive stable reads (bounded, ~30ms apart) so the
  # delta captured here reliably includes it.
  settle_attempts=0
  while [ "$settle_attempts" -lt 5 ]; do
    sleep 0.03
    next_bytes="$(wc -c < "$transcript_path" 2>/dev/null | tr -d ' ')"
    case "$next_bytes" in ''|*[!0-9]*) break ;; esac
    [ "$next_bytes" = "$curr_bytes" ] && break
    curr_bytes="$next_bytes"
    settle_attempts=$((settle_attempts + 1))
  done

  [ "$curr_bytes" -gt "$prev_bytes" ] || return 1

  mkdir -p "$chunk_dir"
  chunk_path="$chunk_dir/${session_id}_${prev_bytes}_${curr_bytes}.jsonl"
  tail -c "+$((prev_bytes + 1))" "$transcript_path" > "$chunk_path" 2>/dev/null || return 1

  sql "$db" >/dev/null 2>&1 <<CTXHUB_SQL_EOF
INSERT OR IGNORE INTO transcript_chunks (session_id, byte_start, byte_end, chunk_path, captured_at, synced)
VALUES ('$(esc "$session_id")', $prev_bytes, $curr_bytes, '$(esc "$chunk_path")', '$(esc "$now")', 0);

UPDATE sessions SET transcript_bytes_captured = $curr_bytes WHERE session_id = '$(esc "$session_id")';
CTXHUB_SQL_EOF
}

# Best-effort delivery of one unsynced chunk, streamed straight from its
# file on disk via multipart upload — avoids ever needing to JSON-escape
# or shell-quote arbitrary transcript content. Deletes the local file only
# after the server confirms receipt; the synced=1 row is what remains as
# the permanent record that it was captured and sent.
deliver_chunk() {
  local db="$1" session_id="$2" byte_start="$3" byte_end="$4" chunk_path="$5"
  local synced_at

  [ -f "$chunk_path" ] || return 1

  if curl -fsS -m 10 -X POST "$CTXHUB_INGEST_URL/transcript-chunks" \
       -H "Authorization: Bearer $CTXHUB_API_KEY" \
       -F "session_id=$session_id" \
       -F "byte_start=$byte_start" \
       -F "byte_end=$byte_end" \
       -F "content=@$chunk_path" >/dev/null 2>&1; then
    synced_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sql "$db" "UPDATE transcript_chunks SET synced = 1, synced_at = '$(esc "$synced_at")' WHERE session_id = '$(esc "$session_id")' AND byte_start = $byte_start;" >/dev/null 2>&1
    rm -f "$chunk_path"
    return 0
  fi
  return 1
}

# Sweep and attempt delivery of every unsynced edit and transcript chunk
# across ALL sessions, not just one — the shared "drain the backlog"
# routine used by ship-session.sh's one-shot sweep, session-start.sh's
# one-shot sweep, and flush-daemon.sh's repeated polling. Assumes
# ctxhub_configured has already been checked by the caller.
flush_all_pending() {
  local db="$1" now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sql -separator '|' "$db" "SELECT tool_use_id, session_id, file_path, branch, repo, ts FROM edits WHERE synced = 0;" 2>/dev/null | \
  while IFS='|' read -r tuid sid fpath branch repo ts; do
    body="$(jq -n --arg sid "$sid" --arg tuid "$tuid" --arg fpath "$fpath" \
                  --arg branch "$branch" --arg repo "$repo" --arg ts "$ts" \
                  '{session_id:$sid, tool_use_id:$tuid, file_path:$fpath, branch:$branch, repo:$repo, ts:$ts}')"
    if curl -fsS -m 5 -X POST "$CTXHUB_INGEST_URL/edits" \
         -H "Authorization: Bearer $CTXHUB_API_KEY" \
         -H "Content-Type: application/json" \
         -d "$body" >/dev/null 2>&1; then
      sql "$db" "UPDATE edits SET synced = 1, synced_at = '$(esc "$now")' WHERE tool_use_id = '$(esc "$tuid")';" >/dev/null 2>&1
    fi
  done

  sql -separator '|' "$db" "SELECT session_id, byte_start, byte_end, chunk_path FROM transcript_chunks WHERE synced = 0 ORDER BY session_id, byte_start;" 2>/dev/null | \
  while IFS='|' read -r csid cbs cbe cpath; do
    deliver_chunk "$db" "$csid" "$cbs" "$cbe" "$cpath"
  done
}

# True (exit 0) if anything is still waiting to be delivered.
has_pending() {
  local db="$1" n
  n="$(sql "$db" "SELECT (SELECT COUNT(*) FROM edits WHERE synced=0) + (SELECT COUNT(*) FROM transcript_chunks WHERE synced=0);" 2>/dev/null)"
  case "$n" in ''|0) return 1 ;; *) return 0 ;; esac
}

# Spawn the continuous flush daemon (flush-daemon.sh) if backlog remains
# after a one-shot sweep, unless one is already running. Guards against
# duplicate spawns (every SessionStart/SessionEnd would otherwise launch
# a fresh one) via a PID lock file — verified two ways, not just
# "process with this PID exists": a crashed daemon's PID could be reused
# by an unrelated process after reboot, so the full command line is also
# checked to contain this script's name before trusting the lock.
#
# Known limitation, deliberately not fixed: this check-then-spawn isn't
# atomic. Two hook invocations firing within the same sub-second window,
# before either daemon has written its PID file, could both pass the
# guard and both spawn. Consequence is bounded and self-correcting (both
# instances redundantly flush the same backlog, both self-terminate once
# caught up — SQLite's busy_timeout already makes concurrent access
# safe) rather than anything unsafe, so this doesn't use a proper atomic
# lock (e.g. mkdir as a mutex) — that's real complexity for a benign,
# rare race.
spawn_flush_daemon() {
  local db="$1" hook_dir="$2" pid_file="$3"
  local old_pid

  has_pending "$db" || return 0

  if [ -f "$pid_file" ]; then
    old_pid="$(cat "$pid_file" 2>/dev/null)"
    case "$old_pid" in
      ''|*[!0-9]*) : ;;
      *)
        if kill -0 "$old_pid" 2>/dev/null && ps -p "$old_pid" -o command= 2>/dev/null | grep -q "flush-daemon.sh"; then
          return 0
        fi
        ;;
    esac
  fi

  nohup "$hook_dir/flush-daemon.sh" "$db" >/dev/null 2>&1 &
  disown
}
