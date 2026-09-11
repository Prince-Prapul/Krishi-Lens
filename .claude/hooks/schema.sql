PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS sessions (
  session_id                TEXT PRIMARY KEY,
  transcript_path           TEXT,
  transcript_bytes_captured INTEGER DEFAULT 0,
  first_seen_at             TEXT,
  last_seen_at              TEXT,
  ended                     INTEGER DEFAULT 0,
  ended_at                  TEXT
);

CREATE TABLE IF NOT EXISTS edits (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id  TEXT NOT NULL REFERENCES sessions(session_id),
  tool_use_id TEXT UNIQUE NOT NULL,
  file_path   TEXT NOT NULL,
  branch      TEXT,
  repo        TEXT,
  ts          TEXT NOT NULL,
  synced      INTEGER DEFAULT 0,
  synced_at   TEXT
);

CREATE INDEX IF NOT EXISTS idx_edits_unsynced ON edits(synced) WHERE synced = 0;
CREATE INDEX IF NOT EXISTS idx_edits_repo_branch ON edits(repo, branch);

-- Transcript growth since the last capture, per session, stored as a flat
-- file on disk (chunk_path) with only metadata here. Content deliberately
-- never passes through a SQL TEXT column: it's arbitrary multi-line JSONL
-- and going through a bash variable or SQL string literal risks silently
-- stripped trailing newlines and corrupted byte accounting. Reconstructing
-- a session's full transcript server-side is: concatenate chunk contents
-- ordered by byte_start.
CREATE TABLE IF NOT EXISTS transcript_chunks (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id  TEXT NOT NULL REFERENCES sessions(session_id),
  byte_start  INTEGER NOT NULL,
  byte_end    INTEGER NOT NULL,
  chunk_path  TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  synced      INTEGER DEFAULT 0,
  synced_at   TEXT,
  UNIQUE(session_id, byte_start)
);

CREATE INDEX IF NOT EXISTS idx_chunks_unsynced ON transcript_chunks(synced) WHERE synced = 0;
