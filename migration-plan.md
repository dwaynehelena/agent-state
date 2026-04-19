# Migration Plan — Agent State Persistence

## Overview

Migrate OpenClaw cron jobs to state-file tracked execution, one at a time. Each migration disables the OpenClaw cron, adds state-file tracking, and verifies before proceeding.

## Order of Migration

### Phase 1: State Infrastructure (DONE)
- [x] Create `agent-state/` directory structure
- [x] Create `agents/pro.json` with current state
- [x] Create `agents/pro-2.json` with current state
- [x] Create `agents/sentinel.json` with current state
- [x] Create `agents/evolution.json` with current state
- [x] Create `agent-watchdog.sh`
- [x] Create `state-write.sh`
- [x] Create `github-sync.sh`
- [x] Create `migration-plan.md`
- [ ] Initialize git repo and push to GitHub
- [ ] Set up launchd plist for watchdog (every 60s)

### Phase 2: Cron Migration (one at a time, verify each)

#### Migration 1: pergolux-realm (most frequent, most flaky — start here)
- **Cron ID:** `dee51077-9f79-4c7b-93db-8b01c03c28d9`
- **Schedule:** every 15m
- **Model:** glm-5.1:cloud
- **Steps:**
  1. Add `pergolux-realm` to `pro.json` cron_context (DONE)
  2. Write state on each cron execution: `./state-write.sh pro cron_context.pergolux-realm.last_run "2026-04-19T15:14:00+10:00"`
  3. Verify state persists across 3 cron cycles
  4. Confirm watchdog sees agent as healthy during cron runs
  5. ✅ Mark pergolux-realm as fully tracked

#### Migration 2: daily-update-status
- **Cron ID:** `cb8820d2-ea50-435b-941b-3f60ce2cdf84`
- **Schedule:** 30 2 * * * (daily at 2:30am AEST)
- **Model:** glm-5.1:cloud
- **Steps:**
  1. Add state tracking to cron execution
  2. Verify for 2 consecutive days
  3. ✅ Mark as tracked

#### Migration 3: stock-tracker
- **Cron ID:** `8fe23436-63d6-4671-9979-319e4756217f`
- **Schedule:** 0 18 * * * (6pm AEST daily)
- **Steps:**
  1. Add state tracking
  2. Verify for 2 consecutive runs
  3. ✅ Mark as tracked

#### Migration 4: daily-stock-tracker
- **Cron ID:** `bf7e6c61-fb6d-4c87-8846-263371e6dd12`
- **Schedule:** 0 18 * * 1-5 (6pm AEST weekdays)
- **Steps:**
  1. Add state tracking
  2. Verify for 2 consecutive weekday runs
  3. ✅ Mark as tracked

#### Migration 5: weekly-health-processor
- **Cron ID:** `8913ee15-e92c-470e-bcf5-acee10818e80`
- **Schedule:** 0 3 * * 1 (3am Monday AEST)
- **Steps:**
  1. Add state tracking
  2. Verify for 1 weekly run
  3. ✅ Mark as tracked

#### Migration 6: weekly-security-audit
- **Cron ID:** `c25f08ea-7e18-4c31-bfec-da74056069b1`
- **Schedule:** 0 2 * * 0 (2am Sunday AEST)
- **Steps:**
  1. Add state tracking
  2. Verify for 1 weekly run
  3. ✅ Mark as tracked

### Phase 3: Cross-Host Watchdog
- [ ] Deploy watchdog on pro-2 (192.168.68.56 / 100.95.185.57)
- [ ] pro watches pro-2 agents, pro-2 watches pro agents
- [ ] GitHub state sync for cross-host visibility
- [ ] Test: kill gateway on pro-2, verify pro detects and alerts

### Phase 4: Agent-Managed Scheduling
- [ ] Replace OpenClaw crons with agent-managed scheduling
- [ ] Agent reads cron_context from state file on startup
- [ ] Agent manages its own schedule (no external cron dependency)
- [ ] Watchdog ensures agent stays alive to maintain schedule

## Rollback Plan

If any migration fails:
1. Re-enable the OpenClaw cron immediately: `openclaw cron enable <cron_id>`
2. Remove state tracking for that cron from agent file
3. Investigate, fix, re-attempt

## State File Schema Contract

All agents MUST use this exact schema:
```json
{
  "agent": "string",
  "host": "string",
  "hostname": "string",
  "pid": "number",
  "started_at": "ISO8601",
  "last_heartbeat": "ISO8601",
  "current_task": "string",
  "status": "running|stopped|error",
  "pm2_processes": {},
  "cron_context": {},
  "startup_prompt": "string",
  "known_issues": ["string"],
  "git_sha": "string"
}
```

No custom fields. No extensions. The state file IS the contract.