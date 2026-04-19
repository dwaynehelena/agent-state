# Agent State

Multi-agent state persistence system. Each agent writes its state as JSON.
The state file IS the contract between agents.

## Structure
- `agents/{name}.json` — Per-agent state files
- `agent-watchdog.sh` — Watchdog (runs every 60s, checks PIDs and heartbeats)
- `state-write.sh` — Helper to write state (handles nested keys, heartbeats, issues)
- `github-sync.sh` — Git sync with GitHub (init/sync/pull)

## Schema
See `agents/pro.json` for the canonical schema. All agents MUST use the same schema.

## Branches
- `main` — merged stable state
- `agent-state/pro` — pro host state
- `agent-state/pro-2` — pro-2 host state

## Usage
```bash
# Write state
./state-write.sh pro current_task "processing health data"
./state-write.sh pro heartbeat
./state-write.sh pro issue_add "new-bug-found"
./state-write.sh pro cron_context.pergolux-realm.status ok

# Run watchdog (dry-run first)
./agent-watchdog.sh --dry-run
./agent-watchdog.sh

# Git sync
./github-sync.sh init
./github-sync.sh sync
./github-sync.sh pull
```