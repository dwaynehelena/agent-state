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
    [[ -z "$pid" || "$pid" == "0" ]] && return 1
    kill -0 "$pid" 2>/dev/null
}

# Map watchdog agent name → PM2 process name. Empty echo = not PM2-managed.
pm2_name_for_agent() {
    case "$1" in
        evolution) echo "openclaw-evolution" ;;
        sentinel)  echo "sentinel" ;;
        *)         echo "" ;;
    esac
}

# Cache pm2 jlist for the duration of one watchdog run (avoid N invocations).
_PM2_JLIST_CACHE=""
_pm2_jlist_cached() {
    if [[ -z "$_PM2_JLIST_CACHE" ]]; then
        _PM2_JLIST_CACHE="$(pm2 jlist 2>/dev/null || echo '[]')"
    fi
    printf '%s' "$_PM2_JLIST_CACHE"
}

# Live PID of a PM2 process by name. Echoes "" if not found, not online, or no PID.
get_pm2_pid() {
    local name="$1"
    [[ -z "$name" ]] && return
    _pm2_jlist_cached | python3 -c "
import json, sys
try:
    procs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in procs:
    if p.get('name') == '$name':
        env = p.get('pm2_env') or {}
        if env.get('status') == 'online':
            pid = env.get('pid') or p.get('pid') or 0
            if pid:
                print(pid)
        break
" 2>/dev/null
}

# Sync the JSON state file's pid field to the live value (best-effort, non-fatal).
sync_pid_in_state() {
    local agent_file="$1"
    local new_pid="$2"
    [[ -z "$new_pid" ]] && return
    python3 -c "
import json
p = '$agent_file'
with open(p) as f:
    d = json.load(f)
d['pid'] = int('$new_pid')
pm2 = d.get('pm2_processes') or {}
for k in pm2:
    if isinstance(pm2[k], dict):
        pm2[k]['pid'] = int('$new_pid')
with open(p, 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null || log "WARN: Failed to sync pid for $agent_file"
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

        # For PM2-managed agents, the source of truth for PID is `pm2 jlist`,
        # not the JSON file (which gets stale across PM2 restarts and was the
        # cause of repeated false-alarm restart loops). Prefer the live PID
        # and write it back to the JSON so external readers stay consistent.
        local pm2_name pm2_pid
        pm2_name="$(pm2_name_for_agent "$agent_name")"
        if [[ -n "$pm2_name" ]]; then
            pm2_pid="$(get_pm2_pid "$pm2_name")"
            if [[ -n "$pm2_pid" && "$pm2_pid" != "$pid" ]]; then
                log "  PM2 reports $pm2_name PID=$pm2_pid (state file had $pid) — syncing"
                if ! $DRY_RUN; then
                    sync_pid_in_state "$agent_file" "$pm2_pid"
                fi
                pid="$pm2_pid"
            fi
        fi

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