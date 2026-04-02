#!/bin/bash
# Saves a session recap directly to Postgres.
# Usage: bash memory-recap.sh <persona> '<topics_json_array>' "<summary>" "<key_decisions>"
# Example: bash /c/Users/chris/.claude/hooks/memory-recap.sh general '["workflow","memory"]' "Built the recap script" "Use docker exec not n8n"

PERSONA="${1}"
TOPICS_JSON="${2:-[]}"
SUMMARY="${3}"
KEY_DECISIONS="${4}"

if [ -z "$PERSONA" ] || [ -z "$SUMMARY" ]; then
  echo "ERROR: persona and summary are required."
  exit 1
fi

RESULT=$(docker exec -i claude-memory-postgres psql -U claude_admin -d claude_memory 2>&1 << ENDSQL
INSERT INTO conversations (persona, topics, summary, key_decisions)
VALUES (
  \$mem\$${PERSONA}\$mem\$,
  ARRAY(SELECT json_array_elements_text(\$mem\$${TOPICS_JSON}\$mem\$::json)),
  \$mem\$${SUMMARY}\$mem\$,
  \$mem\$${KEY_DECISIONS}\$mem\$
);
ENDSQL
)

if echo "$RESULT" | grep -q "INSERT 0 1"; then
  echo "[Recap saved successfully]"
else
  echo "[ERROR saving recap: $RESULT]"
fi
