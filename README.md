# Claude Memory Database

**Status: Live** | Postgres 16 | Docker | Bash

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
| Hook scripts | Bash (`session-memory.sh`, `memory-recap.sh`) |
| DB access | `docker exec psql` — no middleware required |
| Backup | `pg_dump` via Docker exec, daily at 3PM ET (Windows Task Scheduler) |

---

## Architecture

### Session Start Flow

```
Claude Code launches
  → SessionStart hook fires session-memory.sh
  → Script runs docker exec psql against claude-memory-postgres
  → Queries conversations table (last 10, ordered by date DESC)
  → Formats results as markdown
  → Output echoed to stdout
  → Claude receives context before the first user message
```

### Mid-Session

No live DB queries during a session. The snapshot from session start is what Claude works from.

### End of Session (Recap)

```
User requests a recap
  → Claude generates: persona, topics[], summary, key_decisions
  → Claude runs memory-recap.sh with those values
  → Script runs docker exec psql INSERT into conversations table
  → Next session will include this recap in injected context
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

## Scripts

Both scripts live in `scripts/` in this repo. Copy them to `~/.claude/hooks/` to use them.

### `session-memory.sh`

Runs at session start. Queries the last 10 session recaps and outputs them as markdown for Claude to read.

### `memory-recap.sh`

Called by Claude at the end of a session to save a recap.

```bash
bash memory-recap.sh <persona> '<topics_json_array>' "<summary>" "<key_decisions>"
```

Example:

```bash
bash /c/Users/chris/.claude/hooks/memory-recap.sh \
  general \
  '["docker","memory","postgres"]' \
  "Rewrote memory system to use direct docker exec psql instead of n8n webhooks." \
  "Use docker exec not n8n for all DB operations"
```

---

## Setup

### Prerequisites

- Docker Desktop running (WSL2 backend)

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

```bash
docker exec -it claude-memory-postgres psql -U claude_admin -d claude_memory
```

Then run:

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

### 4. Install the hook scripts

```bash
cp scripts/session-memory.sh ~/.claude/hooks/
cp scripts/memory-recap.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/session-memory.sh
chmod +x ~/.claude/hooks/memory-recap.sh
```

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

---

## Backup & Recovery

### Backup location

```
C:/Users/chris/claude-memory-backups/
```

Files follow the pattern: `claude-memory-YYYY-MM-DD.sql`

The last 7 daily backups are kept. Older files are deleted automatically.

### Backup process

A Windows Task Scheduler task runs daily at 3PM ET via WSL and executes:

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

## Docker Safety

- `claude_memory_pgdata` volume is **never** touched by `docker compose down -v`
- Container uses `restart: unless-stopped` — survives Docker Desktop restarts
- Port bound to `127.0.0.1:5433` only
- Always verify a recent backup exists before any Docker maintenance on this stack
- To reset only the memory DB volume:
  ```bash
  docker compose stop claude-memory-postgres
  docker volume rm claude_memory_pgdata
  docker compose up -d
  ```
