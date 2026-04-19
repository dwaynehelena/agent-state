#!/usr/bin/env bash
# state-write.sh — Helper to write agent state to JSON files
# Usage: ./state-write.sh <agent-name> <key> <value>
#   ./state-write.sh pro current_task "processing health data"
#   ./state-write.sh pro cron_context.pergolux-realm.status ok
#   ./state-write.sh pro pid 589
#   ./state-write.sh pro heartbeat  (updates last_heartbeat to now)
#   ./state-write.sh pro issue_add "new-bug-found"
#   ./state-write.sh pro issue_remove "old-bug"
#   ./state-write.sh pro status running

set -euo pipefail

STATE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="${STATE_DIR}/agents"

AGENT="${1:?Usage: state-write.sh <agent-name> <key> <value>}"
KEY="${2:?}"
VALUE="${3:-}"

AGENT_FILE="${AGENTS_DIR}/${AGENT}.json"

if [[ ! -f "$AGENT_FILE" ]]; then
    echo "ERROR: Agent state file not found: $AGENT_FILE" >&2
    exit 1
fi

# Write state using python3 for JSON manipulation
# Pass args via environment to avoid shell escaping issues
export _SW_AGENT_FILE="$AGENT_FILE"
export _SW_KEY="$KEY"
export _SW_VALUE="$VALUE"

python3 << 'PYEOF'
import json, os

agent_file = os.environ['_SW_AGENT_FILE']
key = os.environ['_SW_KEY']
value = os.environ['_SW_VALUE']

with open(agent_file, 'r') as f:
    data = json.load(f)

# Handle dot-notation for nested keys (e.g., cron_context.pergolux-realm.status)
if key == 'heartbeat':
    from datetime import datetime, timezone, timedelta
    aest = timezone(timedelta(hours=10))
    data['last_heartbeat'] = datetime.now(aest).strftime('%Y-%m-%dT%H:%M:%S+10:00')
elif key == 'issue_add':
    if value not in data.get('known_issues', []):
        data.setdefault('known_issues', []).append(value)
elif key == 'issue_remove':
    data.setdefault('known_issues', [])
    data['known_issues'] = [i for i in data['known_issues'] if i != value]
elif key == 'issue_clear':
    data['known_issues'] = []
else:
    keys = key.split('.')
    # Try numeric conversion for value
    try:
        value_typed = int(value)
    except ValueError:
        try:
            value_typed = float(value)
        except ValueError:
            value_typed = value

    # Navigate to nested key
    target = data
    for k in keys[:-1]:
        if k not in target:
            target[k] = {}
        target = target[k]
    target[keys[-1]] = value_typed

with open(agent_file, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print(f'OK: {key} updated')
PYEOF

# Git sync
cd "$STATE_DIR"
git add "$AGENT_FILE" 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "state: ${AGENT}.${KEY}" 2>/dev/null || true
git push 2>/dev/null || echo "WARN: git push failed (non-fatal)" >&2