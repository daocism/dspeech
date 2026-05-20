#!/bin/bash
# workday-pilot-v2.sh — full-day Dspeech MVP pilot
#
# Phases:
#   P1 critical-path (sequential):   W4b-round4 → W7-verifier → W8-design → W9-docs
#   P2 hardening    (parallel x4):   W10 threading || W11 errors || W12 cold-start || W13 privacy
#   P3 reviewer pass (parallel x4):  W6 review on each hardening branch
#   P4 polish       (sequential):    W14 liquid-glass → W15 accessibility → W16 gemini
#   P5 finalisation (sequential):    W17 merge + docs + Notion + push
#
# Discipline:
#   * one claude -p per wave-slot
#   * progress gate: each wave must push ≥1 commit on its own branch, else fail
#   * rate-limit-aware: parse `resets HH:MM(am|pm)` → sleep until reset+90s
#   * codex fallback if ALLOW_CODEX_FALLBACK=1 AND `codex` on PATH (not installed
#     on mac24 at time of writing — left in place for future)
#   * NEEDS-HUMAN.md is the single termination signal
#   * always logs to docs/AUTOPILOT-JOURNAL.md (append-only, audit trail)
set -uo pipefail

REPO="${REPO:-$HOME/projects/dspeech-ios}"
MAIN_BRANCH="feat/mvp-completion-2026-05-19"
PROMPTS_DIR="$REPO/.agent-prompts"
LOGS_DIR="$REPO/.agent-logs"
STATE_DIR="$REPO/.agent-state"
JOURNAL="$REPO/docs/AUTOPILOT-JOURNAL.md"
NEEDS_HUMAN="$REPO/docs/NEEDS-HUMAN.md"
QUOTA_STATE="/tmp/dspeech-quota-state"
ALLOW_CODEX_FALLBACK="${ALLOW_CODEX_FALLBACK:-1}"

mkdir -p "$LOGS_DIR" "$STATE_DIR"

log() {
  local stamp; stamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[pilot-v2 $stamp] $*" | tee -a "$JOURNAL" >&2
}

cd "$REPO"

# ---------- helpers ----------

git_head() { (cd "$REPO" && git rev-parse --short HEAD); }

git_branch_head() { (cd "$REPO" && git rev-parse --short "$1" 2>/dev/null || echo NOBRANCH); }

parse_reset_epoch() {
  local logfile="$1"
  local match
  match="$(grep -oE 'resets [0-9]{1,2}:[0-9]{2}(am|pm)' "$logfile" 2>/dev/null | tail -1)"
  [[ -z "$match" ]] && { echo 0; return; }
  local hhmm ampm hh mm h24 now_epoch tgt_epoch today_ymd
  hhmm="$(echo "$match" | awk '{print $2}' | sed 's/am$//;s/pm$//')"
  ampm="$(echo "$match" | grep -oE '(am|pm)$')"
  hh="${hhmm%:*}"; mm="${hhmm#*:}"
  if [[ "$ampm" == "pm" && "$hh" -lt 12 ]]; then h24=$((hh + 12))
  elif [[ "$ampm" == "am" && "$hh" -eq 12 ]]; then h24=0
  else h24="$hh"; fi
  now_epoch=$(date +%s); today_ymd=$(date '+%Y-%m-%d')
  tgt_epoch=$(date -j -f "%Y-%m-%d %H:%M:00" "$today_ymd $(printf '%02d' $h24):$mm:00" +%s 2>/dev/null || echo 0)
  [[ "$tgt_epoch" -lt "$now_epoch" ]] && tgt_epoch=$((tgt_epoch + 86400))
  echo "$tgt_epoch"
}

needs_human() {
  local why="$1"; local extra="${2:-}"
  {
    echo "## $(date) — pilot escalation"
    echo "$why"
    [[ -n "$extra" ]] && echo "$extra"
    echo ""
  } >> "$NEEDS_HUMAN"
  log "ESCALATED → docs/NEEDS-HUMAN.md: $why"
}

# Run one wave with rate-limit + progress gate.
# Args: $1=slug $2=prompt-file $3=base-branch $4=branch-to-track (where commits should land)
#       $5=max-rl-retries (default 2)
run_wave() {
  local slug="$1" prompt="$2" base_branch="$3" track_branch="$4"
  local max_rl="${5:-2}"
  local rl_count=0
  log "wave $slug start — base=$base_branch — track=$track_branch — prompt=$(basename "$prompt")"

  # capture pre-wave head of track branch (or NOBRANCH if it doesn't exist yet)
  local pre_sha; pre_sha=$(git_branch_head "$track_branch")
  log "wave $slug pre_sha($track_branch)=$pre_sha"

  while :; do
    local stamp; stamp="$(date '+%Y%m%d-%H%M%S')"
    local logf="$LOGS_DIR/${slug}-${stamp}.log"

    log "wave $slug invoking claude -p (rl_count=$rl_count)"
    (cd "$REPO" && claude -p --dangerously-skip-permissions --output-format text < "$prompt") \
      > "$logf" 2>&1
    local rc=$?
    log "wave $slug claude rc=$rc, log=$logf"

    if grep -qE "(You've hit your limit|usage limit|rate.?limit|resets [0-9]{1,2}:[0-9]{2}(am|pm))" "$logf"; then
      rl_count=$((rl_count + 1))
      local reset_epoch; reset_epoch=$(parse_reset_epoch "$logf")
      local now_epoch; now_epoch=$(date +%s)
      log "wave $slug RATE-LIMIT (count=$rl_count/$max_rl), reset=$reset_epoch"
      echo "$reset_epoch" > "$QUOTA_STATE"

      if [[ "$ALLOW_CODEX_FALLBACK" == "1" ]] && command -v codex >/dev/null 2>&1; then
        log "wave $slug attempting codex fallback"
        local codex_log="$LOGS_DIR/${slug}-codex-${stamp}.log"
        (cd "$REPO" && codex exec --approval-policy never --sandbox danger-full-access --model gpt-5.4 "$(cat "$prompt")") \
          > "$codex_log" 2>&1
        local crc=$?
        log "wave $slug codex rc=$crc, log=$codex_log"
        local post_codex_sha; post_codex_sha=$(git_branch_head "$track_branch")
        if [[ "$post_codex_sha" != "$pre_sha" && "$post_codex_sha" != "NOBRANCH" ]]; then
          log "wave $slug codex green ($pre_sha → $post_codex_sha)"
          return 0
        fi
      fi

      if [[ "$rl_count" -ge "$max_rl" ]]; then
        needs_human "wave $slug exceeded $max_rl rate-limit retries" "log=$logf"
        return 90
      fi

      if [[ "$reset_epoch" -gt "$now_epoch" ]]; then
        local sleep_s=$((reset_epoch - now_epoch + 90))
        log "wave $slug sleeping ${sleep_s}s until reset+90s"
        sleep "$sleep_s"
      else
        log "wave $slug reset unparsed, fallback 600s sleep"
        sleep 600
      fi
      continue
    fi

    # Progress gate — branch advanced?
    local post_sha; post_sha=$(git_branch_head "$track_branch")
    if [[ "$post_sha" != "$pre_sha" && "$post_sha" != "NOBRANCH" ]]; then
      log "wave $slug GREEN ($pre_sha → $post_sha)"
      return 0
    fi

    log "wave $slug zero new commits on $track_branch"
    needs_human "wave $slug produced no commits" "log=$logf rc=$rc"
    return 91
  done
}

# Spawn one wave in background (for parallel phases). Writes PID to state file.
spawn_wave_bg() {
  local slug="$1" prompt="$2" base="$3" track="$4"
  ( run_wave "$slug" "$prompt" "$base" "$track"; echo $? > "$STATE_DIR/$slug.rc" ) \
    > "$LOGS_DIR/${slug}-driver.log" 2>&1 &
  echo $! > "$STATE_DIR/$slug.pid"
  log "spawned $slug as PID $(cat "$STATE_DIR/$slug.pid")"
}

wait_wave_bg() {
  local slug="$1"
  local pid; pid=$(cat "$STATE_DIR/$slug.pid" 2>/dev/null)
  if [[ -z "$pid" ]]; then log "wait $slug: no PID file"; return 99; fi
  log "waiting on $slug PID $pid"
  wait "$pid" 2>/dev/null
  local rc; rc=$(cat "$STATE_DIR/$slug.rc" 2>/dev/null || echo 99)
  log "wave $slug bg exit rc=$rc"
  return "$rc"
}

# ---------- boot ----------

log "==== workday-pilot-v2 starting ===="
log "REPO=$REPO MAIN=$MAIN_BRANCH"
log "claude: $(command -v claude || echo NOT_FOUND)"
log "codex:  $(command -v codex || echo NOT_FOUND)"
log "HEAD: $(git_head)"

if ! git diff --quiet || ! git diff --cached --quiet; then
  needs_human "pre-flight: working tree dirty" "$(git status -s)"
  exit 1
fi

if ! git rev-parse --verify "$MAIN_BRANCH" >/dev/null 2>&1; then
  needs_human "pre-flight: $MAIN_BRANCH does not exist locally"
  exit 1
fi

git checkout "$MAIN_BRANCH"
git pull --ff-only origin "$MAIN_BRANCH" 2>&1 | tee -a "$JOURNAL" || true

# ---------- P1 critical path (sequential) ----------

log "==== P1 critical path ===="
for w in W4b-round4 W7-verifier W8-design W9-docs; do
  [[ ! -f "$PROMPTS_DIR/$w.md" ]] && { needs_human "P1: prompt missing $w.md"; exit 2; }
done

run_wave "W4b-round4" "$PROMPTS_DIR/W4b-round4.md" "$MAIN_BRANCH" "$MAIN_BRANCH" 2 || { log "P1 W4b failed"; exit 11; }
run_wave "W7-verifier" "$PROMPTS_DIR/W7-verifier.md" "$MAIN_BRANCH" "$MAIN_BRANCH" 2 || { log "P1 W7 failed"; exit 12; }
run_wave "W8-design" "$PROMPTS_DIR/W8-design-review.md" "$MAIN_BRANCH" "$MAIN_BRANCH" 2 || { log "P1 W8 failed"; exit 13; }
run_wave "W9-docs" "$PROMPTS_DIR/W9-docs.md" "$MAIN_BRANCH" "$MAIN_BRANCH" 2 || { log "P1 W9 failed"; exit 14; }

log "P1 done — pushing"
git push origin "$MAIN_BRANCH" 2>&1 | tee -a "$JOURNAL" || true

# ---------- P2 hardening (parallel x4) ----------

log "==== P2 hardening (parallel) ===="
for w in W10-hardening-threading W11-hardening-error-taxonomy W12-hardening-cold-start W13-hardening-privacy-manifest; do
  [[ ! -f "$PROMPTS_DIR/$w.md" ]] && { needs_human "P2: prompt missing $w.md"; exit 21; }
done

spawn_wave_bg "W10-hardening-threading"       "$PROMPTS_DIR/W10-hardening-threading.md"       "$MAIN_BRANCH" "hardening/threading-2026-05-20"
spawn_wave_bg "W11-hardening-error-taxonomy"  "$PROMPTS_DIR/W11-hardening-error-taxonomy.md"  "$MAIN_BRANCH" "hardening/error-taxonomy-2026-05-20"
spawn_wave_bg "W12-hardening-cold-start"      "$PROMPTS_DIR/W12-hardening-cold-start.md"      "$MAIN_BRANCH" "hardening/cold-start-2026-05-20"
spawn_wave_bg "W13-hardening-privacy-manifest" "$PROMPTS_DIR/W13-hardening-privacy-manifest.md" "$MAIN_BRANCH" "hardening/privacy-manifest-2026-05-20"

p2_fail=0
for slug in W10-hardening-threading W11-hardening-error-taxonomy W12-hardening-cold-start W13-hardening-privacy-manifest; do
  if ! wait_wave_bg "$slug"; then
    log "P2 $slug failed"; p2_fail=$((p2_fail + 1))
  fi
done

if [[ "$p2_fail" -gt 0 ]]; then
  log "P2 had $p2_fail failures — proceeding to polish anyway with what's green"
fi

# ---------- P4 polish (sequential, builds on P2 merged tip if W17 ran; else off main) ----------
# We DEFER merge into main until W17 to keep main clean during the day.
# polish branches are cut from MAIN_BRANCH for safety; W17 will rebase/merge later.

log "==== P4 polish (sequential) ===="
for w in W14-polish-liquid-glass W15-polish-accessibility W16-gemini-iteration; do
  [[ ! -f "$PROMPTS_DIR/$w.md" ]] && { needs_human "P4: prompt missing $w.md"; exit 41; }
done

run_wave "W14-polish-liquid-glass" "$PROMPTS_DIR/W14-polish-liquid-glass.md" "$MAIN_BRANCH" "polish/liquid-glass-2026-05-20" 2 || log "P4 W14 failed"
run_wave "W15-polish-accessibility" "$PROMPTS_DIR/W15-polish-accessibility.md" "polish/liquid-glass-2026-05-20" "polish/accessibility-2026-05-20" 2 || log "P4 W15 failed"
run_wave "W16-gemini-iteration" "$PROMPTS_DIR/W16-gemini-iteration.md" "polish/accessibility-2026-05-20" "polish/accessibility-2026-05-20" 2 || log "P4 W16 failed"

# ---------- P5 finalisation ----------

log "==== P5 finalisation ===="
[[ ! -f "$PROMPTS_DIR/W17-final-merge-docs.md" ]] && { needs_human "P5: prompt missing W17"; exit 51; }
run_wave "W17-final" "$PROMPTS_DIR/W17-final-merge-docs.md" "$MAIN_BRANCH" "$MAIN_BRANCH" 2 || { log "P5 W17 failed"; exit 52; }

log "all phases done — pushing final"
git push origin "$MAIN_BRANCH" 2>&1 | tee -a "$JOURNAL" || true
git push --all 2>&1 | tee -a "$JOURNAL" || true

log "==== workday-pilot-v2 DONE — see docs/MISSION_REPORT-2026-05-20.md ===="
exit 0
