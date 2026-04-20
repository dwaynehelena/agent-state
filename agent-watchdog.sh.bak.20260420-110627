#!/usr/bin/env bash
# agent-watchdog.sh — Monitors agent state files and restarts dead/hung agents
# Runs every 60s via launchd or cron
# Usage: ./agent-watchdog.sh [--dry-run]

set -euo pipefail

STATE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="${STATE_DIR}/agents"
LOG_FILE="${STATE_DIR}/agent-watchdog.log"
STALE_THRESHOLD_SEC=300  # 5 minutes
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log() {
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "[${ts}] $*" | tee -a "$LOG_FILE"
}

# Check if a PID is alive
pid_alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# Get current git SHA
get_git_sha() {
    cd "$STATE_DIR"
    git rev-parse --short HEAD 2>/dev/null || echo "nogit"
}

# Restart a PM2 process by name
restart_pm2() {
    local name="$1"
    if $DRY_RUN; then
        log "DRY-RUN: Would restart PM2 process: $name"
    else
        log "RESTART: Restarting PM2 process: $name"
        pm2 restart "$name" 2>&1 | tee -a "$LOG_FILE" || true
    fi
}

# Restart openclaw-gateway
restart_gateway() {
    if $DRY_RUN; then
        log "DRY-RUN: Would restart openclaw-gateway"
    else
        log "RESTART: Restarting openclaw-gateway"
        pm2 restart openclaw-gateway 2>&1 | tee -a "$LOG_FILE" || true
    fi
}

# Update heartbeat in state file
update_heartbeat() {
    local agent_file="$1"
    local now
    now="$(date +"%Y-%m-%dT%H:%M:%S%z")"
    # Use python for JSON manipulation (available on macOS)
    python3 -c "
import json, sys
with open('$agent_file', 'r') as f:
    data = json.load(f)
data['last_heartbeat'] = '$now'
with open('$agent_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || log "WARN: Failed to update heartbeat for $agent_file"
}

# Main watchdog loop
main() {
    log "=== Watchdog start (dry-run: $DRY_RUN) ==="

    local git_sha
    git_sha="$(get_git_sha)"
    log "Current git SHA: $git_sha"

    local issues_found=0

    for agent_file in "${AGENTS_DIR}"/*.json; do
        [[ -f "$agent_file" ]] || continue

        local agent_name
        agent_name="$(basename "$agent_file" .json)"
        local agent_status pid started_at last_heartbeat

        # Read state file
        agent_status="$(python3 -c "import json; d=json.load(open('$agent_file')); print(d.get('status','unknown'))" 2>/dev/null || echo "error")"
        pid="$(python3 -c "import json; d=json.load(open('$agent_file')); print(d.get('pid',0))" 2>/dev/null || echo "0")"
        last_heartbeat="$(python3 -c "import json; d=json.load(open('$agent_file')); print(d.get('last_heartbeat',''))" 2>/dev/null || echo "")"

        log "Checking agent: $agent_name (PID=$pid, status=$agent_status)"

        # Skip stopped agents
        if [[ "$agent_status" == "stopped" ]]; then
            log "  Agent $agent_name is intentionally stopped, skipping"
            continue
        fi

        # Check 1: Is the PID alive?
        if ! pid_alive "$pid"; then
            log "ALERT: Agent $agent_name PID $pid is DEAD (status=$agent_status)"
            issues_found=$((issues_found + 1))

            # Determine restart strategy based on agent
            case "$agent_name" in
                pro)
                    restart_gateway
                    ;;
                pro-2)
                    log "WARN: pro-2 is remote — cannot restart from pro. Flag for cross-host watchdog."
                    ;;
                sentinel)
                    restart_pm2 "sentinel"
                    ;;
                evolution)
                    restart_pm2 "openclaw-evolution"
                    ;;
                *)
                    log "WARN: No restart strategy for agent $agent_name"
                    ;;
            esac
            continue
        fi

        # Check 2: Is the heartbeat stale?
        if [[ -n "$last_heartbeat" ]]; then
            local now_epoch hb_epoch stale_diff
            now_epoch="$(date +%s)"
            # Parse ISO timestamp to epoch (macOS compatible)
            hb_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$last_heartbeat" "+%s" 2>/dev/null || echo "$now_epoch")"
            stale_diff=$(( now_epoch - hb_epoch ))

            if [[ "$stale_diff" -gt "$STALE_THRESHOLD_SEC" ]]; then
                log "ALERT: Agent $agent_name heartbeat is STALE (${stale_diff}s > ${STALE_THRESHOLD_SEC}s threshold)"
                issues_found=$((issues_found + 1))

                # Kill and restart hung agent
                case "$agent_name" in
                    pro)
                        if ! $DRY_RUN; then
                            log "KILL: Killing hung gateway PID $pid"
                            kill -9 "$pid" 2>/dev/null || true
                            sleep 2
                        else
                            log "DRY-RUN: Would kill hung gateway PID $pid"
                        fi
                        restart_gateway
                        ;;
                    sentinel)
                        if ! $DRY_RUN; then
                            log "KILL: Killing hung sentinel PID $pid"
                            kill -9 "$pid" 2>/dev/null || true
                            sleep 2
                        else
                            log "DRY-RUN: Would kill hung sentinel PID $pid"
                        fi
                        restart_pm2 "sentinel"
                        ;;
                    evolution)
                        if ! $DRY_RUN; then
                            log "KILL: Killing hung evolution PID $pid"
                            kill -9 "$pid" 2>/dev/null || true
                            sleep 2
                        else
                            log "DRY-RUN: Would kill hung evolution PID $pid"
                        fi
                        restart_pm2 "openclaw-evolution"
                        ;;
                    *)
                        log "WARN: Stale heartbeat but no restart strategy for $agent_name"
                        ;;
                esac
                continue
            fi
        fi

        # Agent is healthy — update heartbeat
        if ! $DRY_RUN; then
            update_heartbeat "$agent_file"
        fi
        log "  Agent $agent_name: OK"
    done

    # Git sync after watchdog cycle
    if ! $DRY_RUN; then
        cd "$STATE_DIR"
        git add -A 2>/dev/null || true
        git diff --cached --quiet 2>/dev/null || git commit -m "watchdog: $(date -u +"%Y-%m-%dT%H:%M:%SZ") issues=$issues_found" 2>/dev/null || true
        git push 2>/dev/null || log "WARN: git push failed"
    else
        log "DRY-RUN: Would git commit and push"
    fi

    log "=== Watchdog complete (issues=$issues_found) ==="
}

main "$@"