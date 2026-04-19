#!/usr/bin/env bash
# github-sync.sh — Initialize and sync agent-state with GitHub
# Usage: ./github-sync.sh init   (first-time setup)
#        ./github-sync.sh sync   (push current state)
#        ./github-sync.sh pull   (pull remote state)

set -euo pipefail

STATE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="https://github.com/dwaynehelena/agent-state.git"
BRANCH="agent-state/pro"

init() {
    echo "=== Initializing agent-state git repo ==="

    cd "$STATE_DIR"

    # Check if already a git repo
    if [[ -d ".git" ]]; then
        echo "Already a git repo. Adding remote if missing."
        git remote get-url origin &>/dev/null || git remote add origin "$REPO_URL"
    else
        git init
        git remote add origin "$REPO_URL"
    fi

    # Create .gitignore
    cat > .gitignore <<'EOF'
*.log
*.tmp
.DS_Store
agent-watchdog.log
EOF

    # Create README
    cat > README.md <<'EOF'
# Agent State

Multi-agent state persistence system. Each agent writes its state as JSON.
The state file IS the contract between agents.

## Structure
- `agents/{name}.json` — Per-agent state files
- `agent-watchdog.sh` — Watchdog (runs every 60s)
- `state-write.sh` — Helper to write state
- `github-sync.sh` — This sync script

## Schema
See `agents/pro.json` for the canonical schema.

## Branches
- `main` — merged stable state
- `agent-state/pro` — pro host state
- `agent-state/pro-2` — pro-2 host state
EOF

    # Initial commit
    git add -A
    git commit -m "init: agent-state directory structure" || echo "Nothing to commit"

    # Create branch for this host
    git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"

    # Try to push (repo may not exist yet)
    echo ""
    echo "If the GitHub repo doesn't exist yet, create it at:"
    echo "  $REPO_URL"
    echo ""
    echo "Then run: ./github-sync.sh push"
}

sync() {
    echo "=== Syncing agent-state to GitHub ==="
    cd "$STATE_DIR"

    # Ensure we're on the right branch
    git checkout "$BRANCH" 2>/dev/null || true

    # Add and commit all changes
    git add -A
    git diff --cached --quiet 2>/dev/null && echo "No changes to sync" && return 0

    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    git commit -m "sync: ${ts}"

    # Push (local wins on conflict)
    git push origin "$BRANCH" 2>/dev/null || {
        echo "Push failed, attempting rebase..."
        git pull origin "$BRANCH" --rebase 2>/dev/null || {
            echo "Rebase failed, forcing local state..."
            git push origin "$BRANCH" --force 2>/dev/null || {
                echo "ERROR: Could not push to GitHub" >&2
                exit 1
            }
        }
    }
    echo "Sync complete."
}

pull() {
    echo "=== Pulling agent-state from GitHub ==="
    cd "$STATE_DIR"

    git fetch origin "$BRANCH" 2>/dev/null || {
        echo "WARN: Could not fetch from GitHub (may not exist yet)"
        return 0
    }

    # Merge remote changes, local wins on conflict
    git pull origin "$BRANCH" --no-rebase 2>/dev/null || {
        echo "Merge conflict — resolving with local state..."
        git checkout --ours .
        git add -A
        git commit -m "merge: resolved conflicts with local state" 2>/dev/null || true
    }
    echo "Pull complete."
}

case "${1:-sync}" in
    init)  init  ;;
    sync)  sync  ;;
    push)  sync  ;;
    pull)  pull  ;;
    *)     echo "Usage: $0 {init|sync|push|pull}" ;;
esac