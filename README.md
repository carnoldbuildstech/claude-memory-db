# Claude Memory Database

**Status: Live** | Postgres 16 | Docker | n8n | Bash

A persistent memory system for Claude Code. Stores memories and conversation recaps in a dedicated Postgres database and automatically injects context at the start of every session.

---

## What It Is

Claude's built-in memory uses flat markdown files. They work, but they have no queryability, no conversation history, and no way to detect staleness. This project replaces that with a centralized Postgres database that Claude reads from automatically at session start.

**What it provides:**
- Persistent memories across sessions (user profile, project state, feedback, references)
- Episodic conversation history — session recaps written at the end of each session
- Automatic context injection via a Claude Code `SessionStart` hook
- Safe, backed up, impossible to accidentally destroy

---

## Tech Stack

| Component | Detail |
|-----------|--------|
| Database | Postgres 16 (Docker container) |
| Orchestration | Docker Compose |
| Workflows | n8n (self-hosted, local Docker) |
| Hook script | Bash (`session-memory.sh`) |
| Backup | `pg_dump` via Docker exec, daily at 3AM ET |

---

## Architecture

### Session Start Flow

```
Claude Code launches
  → SessionStart hook fires session-memory.sh
  → Script calls GET http://localhost:5678/webhook/session-context
  → n8n queries memories table (active only, limit 50)
  → n8n queries conversations table (last 7, ordered by date DESC)
  → n8n formats both into a markdown text block
  → Response written to MEMORY.md + echoed to stdout
  → Claude receives context before the first user message
```

### Mid-Session

No live DB queries during a session. The snapshot from session start is what Claude works from.

### End of Session (Recap)

```
User requests a recap
  → Claude generates: persona, topics[], summary, key_decisions
  → Claude calls POST http://localhost:5678/webhook/conversation-recap
  → n8n inserts a row into conversations table
  → Next session will include this recap in injected context
```

### Writing / Updating a Memory

```
Claude calls POST http://localhost:5678/webhook/memory-write
  → Body: { type, name, description, content }
  → n8n performs UPSERT (INSERT ... ON CONFLICT (type, name) DO UPDATE)
  → Memory is live for the next session
```

---

## Database Schema

### `memories` table

Replaces individual markdown memory files.

| Column | Type | Notes |
|--------|------|-------|
| id | SERIAL | Primary key |
| type | VARCHAR(50) NOT NULL | One of: `user`, `feedback`, `project`, `reference` |
| name | VARCHAR(255) NOT NULL | Short identifier (e.g., `user_role`, `feedback_testing`) |
| description | TEXT | One-line description for relevance matching |
| content | TEXT NOT NULL | The memory content |
| created_at | TIMESTAMPTZ | DEFAULT NOW() |
| updated_at | TIMESTAMPTZ | DEFAULT NOW() |
| is_active | BOOLEAN | DEFAULT TRUE — soft delete, never hard delete |

**Constraints:**
- `CHECK (type IN ('user', 'feedback', 'project', 'reference'))`
- `UNIQUE (type, name)` — enables UPSERT with `ON CONFLICT`

### `conversations` table

Stores session recaps for episodic memory.

| Column | Type | Notes |
|--------|------|-------|
| id | SERIAL | Primary key |
| session_date | TIMESTAMPTZ | DEFAULT NOW() |
| persona | VARCHAR(100) | Primary persona used (e.g., `professor`, `general`) |
| topics | TEXT[] | Array of topics covered |
| summary | TEXT NOT NULL | 3-5 sentence session recap |
| key_decisions | TEXT | Decisions made during the session |
| created_at | TIMESTAMPTZ | DEFAULT NOW() |

---

## n8n Workflows

All six workflows are active. JSON files are in the [`workflows/`](workflows/) directory — import directly into n8n.

| Workflow | File | Method | Webhook Path | Purpose |
|----------|--------|-------------|---------|
| Claude Memory - Write | `claude-memory-write.json` | POST | `/webhook/memory-write` | UPSERT a memory row |
| Claude Memory - Read | `claude-memory-read.json` | POST | `/webhook/memory-read` | Query memories with filters |
| Claude Memory - Archive | `claude-memory-archive.json` | POST | `/webhook/memory-archive` | Soft-delete a memory (sets `is_active = false`) |
| Claude Memory - Recap | `claude-memory-recap.json` | POST | `/webhook/conversation-recap` | Save end-of-session recap |
| Claude Memory - Session Context | `claude-memory-session-context.json` | GET | `/webhook/session-context` | Pull formatted context for injection |
| Claude Memory - Backup | `claude-memory-backup.json` | — | Scheduled (3AM ET daily) | `pg_dump` to backup directory |

---

## Setup

### Prerequisites

- Docker Desktop running (WSL2 backend)
- n8n running in Docker on port 5678
- n8n connected to the `n8n_default` Docker network

### 1. Configure environment

Create a `.env` file in this directory:

```
POSTGRES_DB=claude_memory
POSTGRES_USER=claude_admin
POSTGRES_PASSWORD=your_strong_password_here
```

### 2. Start the container

```bash
docker compose up -d
```

The container binds to `127.0.0.1:5433` only — not exposed to the network.

### 3. Create the tables

Connect to the DB and run:

```sql
CREATE TABLE memories (
  id SERIAL PRIMARY KEY,
  type VARCHAR(50) NOT NULL CHECK (type IN ('user', 'feedback', 'project', 'reference')),
  name VARCHAR(255) NOT NULL,
  description TEXT,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  is_active BOOLEAN DEFAULT TRUE,
  UNIQUE (type, name)
);

CREATE TABLE conversations (
  id SERIAL PRIMARY KEY,
  session_date TIMESTAMPTZ DEFAULT NOW(),
  persona VARCHAR(100),
  topics TEXT[],
  summary TEXT NOT NULL,
  key_decisions TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 4. Configure n8n

- Add a Postgres credential named **"Claude Memory DB"** pointing to `localhost:5433` (or `claude-memory-postgres:5432` from within Docker)
- Import and activate all six workflows

### 5. Wire the session hook

Add to `~/.claude/settings.json`:

```json
"hooks": {
  "SessionStart": [
    {
      "matcher": "startup|resume",
      "hooks": [
        {
          "type": "command",
          "command": "/c/Users/chris/.claude/hooks/session-memory.sh",
          "timeout": 30,
          "statusMessage": "Loading memory context..."
        }
      ]
    }
  ]
}
```

Hook script at `~/.claude/hooks/session-memory.sh`:

```bash
#!/bin/bash
RESPONSE=$(curl -sf "http://localhost:5678/webhook/session-context" 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$RESPONSE" ]; then
  echo "$RESPONSE"
  echo "$RESPONSE" > "/c/Users/chris/.claude/projects/c--Users-chris--claude-hooks/memory/MEMORY.md"
else
  echo "[Memory DB unavailable — starting without persistent context. Start n8n if this persists.]"
fi
```

---

## Backup & Recovery

### Backup location

```
C:/Users/chris/claude-memory-backups/
```

Files follow the pattern: `claude-memory-YYYY-MM-DD.sql`

The last 7 daily backups are kept. Older files are deleted automatically.

### Backup process

The scheduled n8n workflow runs daily at 3AM ET and executes:

```bash
pg_dump -h claude-memory-postgres -U claude_admin -d claude_memory \
  -f /backup/claude-memory-$(date +%Y-%m-%d).sql
```

The backup directory is mounted into the container at `/backup`.

### Restore from backup

```bash
# Stop the container
docker compose stop claude-memory-postgres

# Reset the volume (targeted — only the memory volume)
docker volume rm claude_memory_pgdata

# Restart
docker compose up -d

# Restore
docker exec -i claude-memory-postgres psql -U claude_admin -d claude_memory \
  < C:/Users/chris/claude-memory-backups/claude-memory-YYYY-MM-DD.sql
```

---

## Implementation Notes

### Deviations from original design

**1. session-memory.sh writes to MEMORY.md in addition to stdout.**
The original design relied on stdout injection only. The implemented script also writes the response to `MEMORY.md` so Claude's built-in file-based memory system picks it up as a secondary path. Both mechanisms are active.

**2. Post-launch bug found and fixed (2026-03-29).**
The Session Context workflow had an n8n item multiplication bug. `Get Memories` returned N items → `Get Conversations` ran N times → output contained N×M duplicate sessions instead of the correct number. Fixed by setting `executeOnce: true` on the `Get Conversations` and `Code in JavaScript` nodes via the n8n API.

**3. File-based memory system still runs in parallel (Phase 5 in progress).**
The flat markdown files (`MEMORY.md` + individual `.md` files) still exist alongside the DB as a fallback. The DB is the primary source of truth. The file system will be retired once the DB is proven stable across multiple sessions.

---

## Docker Safety

- `claude_memory_pgdata` volume is **never** touched by `docker compose down -v`
- Container uses `restart: unless-stopped` — survives Docker Desktop restarts
- Port bound to `127.0.0.1:5433` only
- Always verify a recent backup exists before any Docker maintenance on this stack
- To reset only the memory DB volume (never the n8n volume):
  ```bash
  docker compose stop claude-memory-postgres
  docker volume rm claude_memory_pgdata
  docker compose up -d
  ```
