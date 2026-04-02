#!/bin/bash
OUTPUT=$(docker exec claude-memory-postgres psql \
  -U claude_admin -d claude_memory \
  -t -A \
  -c "SELECT '**' || TO_CHAR(session_date AT TIME ZONE 'America/New_York', 'Mon FMDD, YYYY') || ' — ' || COALESCE(persona, 'general') || '**' || chr(10) || summary || CASE WHEN key_decisions IS NOT NULL AND key_decisions <> '' THEN chr(10) || 'Decisions: ' || key_decisions ELSE '' END || chr(10) FROM conversations ORDER BY session_date DESC LIMIT 10;" \
  2>/dev/null)

if [ -n "$OUTPUT" ]; then
  echo "## Recent Sessions"
  echo ""
  echo "$OUTPUT"
else
  echo "[Memory DB unavailable — conversation history not loaded. Ensure claude-memory-postgres container is running.]"
fi
