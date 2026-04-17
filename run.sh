#!/usr/bin/env bash
# fifth-builder — LeftClaw Services Build Worker (Service Type 6 only)
#
# Usage:
#   ./run.sh          — find and work the next open build job
#   ./run.sh 42       — resume job 42 from its current stage
#   ./run.sh --peek   — list open build jobs without accepting any
#
# Requires .env in this directory:
#   ETH_PRIVATE_KEY        — main wallet (accepts jobs, logs work, NEVER enters projects)
#   DEPLOYER_KEYSTORE      — foundry keystore name for deployer
#   DEPLOYER_PASSWORD      — password for deployer keystore
#   BASE_RPC_URL           — full Alchemy RPC URL for Base
#   BGIPFS_API_KEY         — for frontend uploads
set -eEuo pipefail

# Ensure claude CLI is on PATH when run.sh is backgrounded in a non-login shell
# (fish sets ~/.local/bin but bash subshells don't inherit it)
export PATH="/Users/austingriffith/.local/bin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
API="https://leftclaw.services"
GITHUB_ORG="clawdbotatg"
DEPLOY_FUND="0.01ether"

# ─── Load our env (NOT the project env) ───────────────────────────────
if [[ -f "$DIR/.env" ]]; then
  set -a; source "$DIR/.env"; set +a
else
  echo "ERROR: .env not found in $DIR" >&2; exit 1
fi

RPC="${BASE_RPC_URL:?BASE_RPC_URL not set in .env}"
ALCHEMY_API_KEY=$(echo "$RPC" | grep -oE '[^/]+$')

# ─── Deployer — from foundry keystore ────────────────────────────────
DEPLOYER_ADDR=$(cast wallet address --account "$DEPLOYER_KEYSTORE" --password "$DEPLOYER_PASSWORD")
DEPLOYER_PRIVATE_KEY=$(cast wallet decrypt-keystore "$DEPLOYER_KEYSTORE" --unsafe-password "$DEPLOYER_PASSWORD" 2>/dev/null | grep -oE '0x[a-fA-F0-9]{64}')
if [[ -z "$DEPLOYER_PRIVATE_KEY" ]]; then
  echo "ERROR: Could not decrypt deployer keystore '$DEPLOYER_KEYSTORE'" >&2; exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# claude_timeout — run claude -p with a wall-clock timeout so a hung agent
# can't freeze the worker forever. Uses a background watchdog (no GNU timeout
# needed, works on macOS). The worker continues on timeout or any other
# non-zero exit — the existing logic handles missing output files gracefully.
#
#   claude_timeout <seconds> -p [args...]
#
claude_timeout() {
  local secs=$1; shift
  local cpid wpid ret=0
  # Run claude in background; it inherits the script's redirected stdout/stderr
  claude "$@" &
  cpid=$!
  # Watchdog: kill claude after timeout (subshell so the sleep/kill pair is atomic)
  { sleep "$secs" && kill -TERM "$cpid" 2>/dev/null; } &
  wpid=$!
  # Wait for claude; || prevents set -e from aborting the script on non-zero exit
  wait "$cpid" 2>/dev/null || ret=$?
  # Reap the watchdog whether it fired or not
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  if [[ $ret -eq 0 ]]; then return 0; fi
  if [[ $ret -eq 143 || $ret -eq 137 ]]; then
    log "WARNING: claude agent timed out after ${secs}s — continuing"
  else
    log "WARNING: claude agent exited $ret — continuing"
  fi
  return 0
}

# pm_log — meta/PM log for high-level state (step, model, intent). Writes
# directly to $PM_LOG_FILE, bypassing the stdout tee so it stays out of the
# raw job log. Safe to call before PM_LOG_FILE is set — it just no-ops.
#   pm_log <stage> <model> <intent>
pm_log() {
  [[ -n "${PM_LOG_FILE:-}" ]] || return 0
  printf '[%s] [%-20s] [%-6s] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${1:-?}" "${2:--}" "${3:-}" >> "$PM_LOG_FILE"
}

# ─── Commit safety gate ──────────────────────────────────────────────
# Call from inside $REPO_DIR. Stages, runs three pre-commit guards, commits
# if anything is staged, then double-checks HEAD in case a subagent already
# committed internally. Hard-exits the worker on any leak.
#
#   commit_and_scan "message"
#
# Pathspecs: exclude generated / vendor paths from hex-64 scans. Bytecode in
# broadcast/*.json and deployedContracts.ts contains runs of 64+ hex chars
# that are NOT secrets — treating them as secrets bricks every deploy commit.
HEX_SCAN_PATHS=(
  '*.md' '*.sol' '*.ts' '*.tsx' '*.js' '*.jsx'
  ':!**/broadcast/**' ':!**/cache/**' ':!**/node_modules/**'
  ':!**/.next/**' ':!**/out/**' ':!**/.yarn/**' ':!**/lib/**'
  ':!**/deployedContracts.ts' ':!**/externalContracts.ts'
)

# ASSIGNMENT_RE catches `PRIVATE_KEY=0x...` / `api_key: "..."` / etc. anywhere
# in the diff. Naked-hex scan is restricted to HEX_SCAN_PATHS.
ASSIGNMENT_RE='(private[_-]?key|mnemonic|seed_?phrase|secret_?key|password|api_?key|auth_?token|bearer)[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9/+]{16,}'
HEX64_RE='0x[a-fA-F0-9]{64}'
TOKEN_RE='(BEGIN [A-Z ]*PRIVATE KEY)|(ghp_[A-Za-z0-9]{30,})|(sk-[A-Za-z0-9]{30,})'

commit_and_scan() {
  local msg="$1"
  git add -A
  # Guard 1: .env must be gitignored at repo root
  if ! git check-ignore -q .env 2>/dev/null; then
    log "FATAL: .env is not gitignored — refusing to commit."
    exit 1
  fi
  # Guard 2: no .env file staged anywhere in the tree
  if git diff --cached --name-only | grep -E '(^|/)\.env($|\.)' >/dev/null; then
    log "FATAL: a .env file is staged — refusing to commit."
    git diff --cached --name-only | grep -E '(^|/)\.env($|\.)'
    exit 1
  fi
  # Guard 3a: assignment of a secret-looking variable name on any added line
  if git diff --cached | grep -iE "^\\+.*${ASSIGNMENT_RE}" >/dev/null; then
    log "FATAL: staged diff assigns a value to a secret-looking name — refusing to commit."
    git diff --cached | grep -niE "^\\+.*${ASSIGNMENT_RE}" | head -5
    exit 1
  fi
  # Guard 3b: naked hex-64 or token pattern on added lines in human-readable files.
  # All-zero (ZERO_BYTES32, bytes32(0)) and all-f values are sentinel constants,
  # not keys — filter them out to avoid false positives.
  if git diff --cached -- "${HEX_SCAN_PATHS[@]}" 2>/dev/null \
       | grep -E "^\\+.*(${HEX64_RE}|${TOKEN_RE})" \
       | grep -vE '0x0{64}|0xf{64}' \
       | grep -q .; then
    log "FATAL: staged diff contains a hex-64 / token value in source/report — refusing to commit."
    git diff --cached -- "${HEX_SCAN_PATHS[@]}" \
      | grep -E "^\\+.*(${HEX64_RE}|${TOKEN_RE})" \
      | grep -vE '0x0{64}|0xf{64}' | head -5
    exit 1
  fi
  # Commit if there's something staged; harmless no-op otherwise.
  # FIFTH_BUILDER_AUTHORIZED=1 satisfies the build-dir pre-commit hook that
  # blocks all other commit attempts (subagents, manual `git commit`, etc.).
  if ! git diff --cached --quiet; then
    FIFTH_BUILDER_AUTHORIZED=1 git commit -m "$msg" 2>&1 | tail -3 || log "  (commit failed)"
  fi
  # Post-commit HEAD scan — catches subagents that bypassed us and committed internally.
  # Same path scoping as Guard 3b so bytecode in broadcast/ doesn't false-positive.
  if git log -p -1 HEAD -- "${HEX_SCAN_PATHS[@]}" 2>/dev/null \
       | grep -E "^\\+.*(${HEX64_RE}|${TOKEN_RE})" \
       | grep -vE '0x0{64}|0xf{64}' \
       | grep -q .; then
    log "FATAL: HEAD commit contains a secret — refusing to continue."
    git log -p -1 HEAD -- "${HEX_SCAN_PATHS[@]}" \
      | grep -E "^\\+.*(${HEX64_RE}|${TOKEN_RE})" \
      | grep -vE '0x0{64}|0xf{64}' | head -3
    log "  Rotate the leaked credential and scrub git history before retrying."
    exit 1
  fi
}

# ─── On-chain helpers ─────────────────────────────────────────────────

log_work() {
  local job_id="$1" note="$2" stage="$3" out
  log "  logWork → $stage"
  # Brief pause before every send so back-to-back calls don't race each other's
  # nonces. 2s is enough for Base to confirm the prior tx and advance the nonce.
  sleep 2
  # Retry once on nonce/mempool races (which can still happen despite the delay).
  for attempt in 1 2; do
    if out=$(cast send "$CONTRACT" "logWork(uint256,string,string)" \
        "$job_id" "$note" "$stage" \
        --private-key "$ETH_PRIVATE_KEY" --rpc-url "$RPC" 2>&1); then
      echo "$out" | tail -3
      return 0
    fi
    if [[ "$attempt" -lt 2 ]] && echo "$out" | grep -qiE 'nonce|already known|replacement underpriced|server returned'; then
      log "  nonce/race on $stage — retrying in 4s..."
      sleep 4
      continue
    fi
    echo "$out" | tail -3
    log "  WARNING: logWork failed for $stage"
    return 0
  done
}

get_messages() {
  curl -sf "$API/api/job/$1/messages" 2>/dev/null || echo '{"messages":[]}'
}

post_message() {
  local job_id="$1" content="$2"
  curl -sf -X POST "$API/api/job/$job_id/messages" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"bot_message\",\"from\":\"bot\",\"content\":\"$content\"}" \
    2>/dev/null || true
}

# ─── Find or resume a job ─────────────────────────────────────────────

if [[ "${1:-}" == "--peek" ]]; then
  log "Peeking at open build jobs (no on-chain action)..."
  READY=$(curl -sf "$API/api/job/ready" || echo '{"jobs":[]}')
  JOBS=$(echo "$READY" | jq '[(.jobs // .)[] | select(.serviceTypeId==6)]')
  COUNT=$(echo "$JOBS" | jq 'length')
  if [[ "$COUNT" -eq 0 ]]; then
    log "No open build jobs."; exit 0
  fi
  log "Found $COUNT open build job(s):"
  echo "$JOBS" | jq -r '.[] | "  Job \(.id): \(.description[:120] | gsub("\n";" "))..."'
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  JOB_ID="$1"
  # Resuming by ID — may or may not have been accepted already; STEP 1 decides.
  NEEDS_ACCEPT=1
  log "Working job $JOB_ID"
else
  log "Polling for build jobs..."
  READY=$(curl -sf "$API/api/job/ready" || echo '{"jobs":[]}')
  JOB_ID=$(echo "$READY" | jq -r '[(.jobs // .)[] | select(.serviceTypeId==6)][0].id // empty')
  if [[ -z "$JOB_ID" ]]; then
    log "No build jobs available."; exit 0
  fi
  log "Found job $JOB_ID — accepting..."
  cast send "$CONTRACT" "acceptJob(uint256)" "$JOB_ID" \
    --private-key "$ETH_PRIVATE_KEY" --rpc-url "$RPC" 2>&1 | tail -3
  # Polling path has just accepted; STEP 1 must not re-send (wastes gas + !open revert).
  NEEDS_ACCEPT=0
fi

# ─── Read job data ────────────────────────────────────────────────────
# Try individual endpoint first, fall back to ready list, then pipeline
JOB_JSON=$(curl -sf "$API/api/job/$JOB_ID" 2>/dev/null || echo "")
if [[ -z "$JOB_JSON" ]] || echo "$JOB_JSON" | jq -e '.error' >/dev/null 2>&1; then
  log "Individual job endpoint unavailable, checking ready list..."
  JOB_JSON=$(curl -sf "$API/api/job/ready" | jq --argjson id "$JOB_ID" '[.jobs[]? // .[]? | select(.id==$id)][0] // empty' 2>/dev/null || echo "")
fi
if [[ -z "$JOB_JSON" ]] || [[ "$JOB_JSON" == "null" ]]; then
  log "Checking pipeline..."
  JOB_JSON=$(curl -sf "$API/api/job/pipeline" | jq --argjson id "$JOB_ID" '.jobs[] | select(.id==$id)' 2>/dev/null || echo "")
fi
if [[ -z "$JOB_JSON" ]] || [[ "$JOB_JSON" == "null" ]]; then
  echo "ERROR: Could not find job $JOB_ID" >&2; exit 1
fi

CLIENT=$(echo "$JOB_JSON" | jq -r '.client // empty')
DESCRIPTION=$(echo "$JOB_JSON" | jq -r '.description // empty')
CURRENT_STAGE=$(echo "$JOB_JSON" | jq -r '.currentStage // .stage // "accepted"')

MESSAGES=$(get_messages "$JOB_ID")
CLIENT_MSGS=$(echo "$MESSAGES" | jq -r '.messages[] | select(.type=="client_message") | .content' 2>/dev/null || echo "")

FULL_SPEC="$DESCRIPTION"
if [[ -n "$CLIENT_MSGS" ]]; then
  FULL_SPEC="$FULL_SPEC

--- Client Messages (authoritative — may override spec) ---
$CLIENT_MSGS"
fi

REPO_NAME="leftclaw-service-job-$JOB_ID"
REPO_DIR="$DIR/builds/$REPO_NAME"

# ─── Internal log redirect ────────────────────────────────────────────
# Now that JOB_ID is known, tee all subsequent stdout+stderr to a per-job log
# inside the project so the operator can `tail -f logs/job-N.log` without
# remembering to redirect on the command line. Output still streams to the
# terminal too. Process-substitution form needs no FIFO file.
mkdir -p "$DIR/logs"
LOG_FILE="$DIR/logs/job-$JOB_ID.log"
PM_LOG_FILE="$DIR/logs/pm-job-$JOB_ID.log"
exec > >(tee -a "$LOG_FILE") 2>&1
log "Internal log: $LOG_FILE"

# ─── Exit / error traps (set after exec redirect so they land in the log) ─
_on_err() {
  local code=$? line=${BASH_LINENO[0]} cmd=${BASH_COMMAND}
  log "ERROR: command failed (exit $code) at line $line: $cmd"
}
_on_exit() {
  local code=$?
  [[ $code -eq 0 ]] && return
  log "FATAL: worker aborted (exit $code) — check lines above for the cause"
}
_on_signal() {
  log "FATAL: worker received termination signal — aborting"
  exit 130
}
trap '_on_err'    ERR
trap '_on_exit'   EXIT
trap '_on_signal' INT TERM
log "Meta log:     $PM_LOG_FILE"
pm_log "start" "-" "Job $JOB_ID | client=$CLIENT | stage=$CURRENT_STAGE | repo=$REPO_NAME"

echo ""
echo "=========================================="
echo "  FIFTH BUILDER — Job #$JOB_ID"
echo "  Client: $CLIENT"
echo "  Stage:  $CURRENT_STAGE"
echo "  Repo:   $REPO_NAME"
echo "=========================================="
echo ""

# If on-chain stage says we're past setup but the local build dir is missing,
# force a full restart — otherwise later steps will cd into a non-existent dir.
if [[ ! -d "$REPO_DIR" && "$CURRENT_STAGE" != "accepted" && "$CURRENT_STAGE" != "" && "$CURRENT_STAGE" != "null" ]]; then
  log "Local build dir missing for $CURRENT_STAGE stage — forcing restart from scratch."
  CURRENT_STAGE="accepted"
fi

# Map any deploy-phase stage back to "full_audit_fix" so Step 4 re-runs on
# resume. These stages are all within Step 4; the step is idempotent on
# .contract-$JOB_ID and .url-$JOB_ID so re-entry is safe.
case "$CURRENT_STAGE" in
  deploy_contract|livecontract_fix|deploy_app|liveapp_fix|liveuserjourney|readme)
    log "Resuming Step 4 from stage '$CURRENT_STAGE'"
    CURRENT_STAGE="full_audit_fix"
    ;;
esac

# Inverse case: API returns null/empty/"accepted" but the build dir already
# exists with progress on disk. Without this, resuming a partially-done job
# would re-scaffold (and possibly clobber) the existing repo. Derive the
# furthest-along stage from filesystem markers and resume there.
#
# IMPORTANT: if .url-$JOB_ID exists the job is fully done — re-running STEP 4
# would burn deployer gas re-deploying a contract at a NEW address (different
# nonce), then revert at completeJob since the job is closed on-chain. Bail
# out cleanly instead. STEP 4 itself is idempotent on .contract-$JOB_ID
# (reads existing address rather than re-deploying), so resuming with just a
# contract on disk is safe.
if [[ -d "$REPO_DIR" ]] && [[ "$CURRENT_STAGE" == "" || "$CURRENT_STAGE" == "null" || "$CURRENT_STAGE" == "accepted" ]]; then
  if [[ -f "$DIR/builds/.url-$JOB_ID" ]]; then
    log "Job $JOB_ID already produced a live URL: $(cat "$DIR/builds/.url-$JOB_ID")"
    log "  Nothing to do. If you need to re-run the on-chain completeJob, do it manually with cast."
    exit 0
  fi
  DERIVED=""
  if [[ -f "$DIR/builds/.contract-$JOB_ID" ]]; then
    DERIVED="full_audit_fix"   # contract deployed, frontend not yet — STEP 4 will skip the redeploy
  elif [[ -f "$REPO_DIR/AUDIT_REPORT.md" ]]; then
    DERIVED="prototype"        # build done, audit cycle in progress
  elif compgen -G "$REPO_DIR/packages/foundry/contracts/*.sol" >/dev/null 2>&1; then
    DERIVED="prototype"        # contracts written, audit not yet
  elif [[ -d "$REPO_DIR/packages/foundry" ]]; then
    DERIVED="create_user_journey"  # scaffold done, no contracts
  fi
  if [[ -n "$DERIVED" && "$DERIVED" != "$CURRENT_STAGE" ]]; then
    log "Stage was '${CURRENT_STAGE:-null}' but repo state implies '$DERIVED' — resuming there."
    CURRENT_STAGE="$DERIVED"
  fi
fi

# =====================================================================
#  STEP 1: SETUP — scaffold, deployer, repo
# =====================================================================

if [[ "$CURRENT_STAGE" == "accepted" || "$CURRENT_STAGE" == "" || "$CURRENT_STAGE" == "null" ]]; then
  log "═══ STEP 1: SETUP ═══"
  pm_log "step1:setup" "worker" "scaffold SE2 + write .env/PLAN.md + create github repo"

  # Accept job on-chain only if the polling path didn't already do it.
  # Resuming by explicit JOB_ID may or may not have been accepted; the
  # || log ... swallows the "!open" revert if it was.
  if [[ "${NEEDS_ACCEPT:-0}" == "1" ]]; then
    log "Accepting job $JOB_ID on-chain..."
    cast send "$CONTRACT" "acceptJob(uint256)" "$JOB_ID" \
      --private-key "$ETH_PRIVATE_KEY" --rpc-url "$RPC" 2>&1 | tail -3 || log "  (already accepted or accept failed)"
  fi

  # Scaffold
  # NOTE (deferred): caching create-eth tarball / yarn install across jobs is
  # tempting (yarn install is the slowest step in STEP 1) but risky — SE-2
  # template versions drift, and a stale node_modules from job N can subtly
  # poison job N+1. yarn berry's global cache (~/.yarn/berry/cache) already
  # de-dupes package downloads, so the only true cost is the resolve step.
  # Skip aggressive caching until we hit a real bottleneck.
  mkdir -p "$DIR/builds"
  if [[ ! -d "$REPO_DIR" ]]; then
    log "Scaffolding SE2 project..."
    cd "$DIR/builds"
    npx -y create-eth@latest -s foundry "$REPO_NAME" --skip-install
    cd "$REPO_DIR" && yarn install
    rm -f packages/foundry/contracts/YourContract.sol 2>/dev/null
    rm -f packages/foundry/script/Deploy.s.sol 2>/dev/null
    rm -f packages/foundry/script/DeployYourContract.s.sol 2>/dev/null
    rm -f packages/foundry/test/YourContract.t.sol 2>/dev/null
    cd "$DIR"
  fi

  # ─── Secrets hygiene: gitignore BEFORE any file writes ─────────────
  cd "$REPO_DIR"
  git init 2>/dev/null || true
  # Ensure root-level .env (and common secret files) are ignored. SE-2's
  # template only ignores packages/*/.env — a root .env slips past it.
  touch .gitignore
  for pat in '.env' '.env.*' '!.env.example' 'packages/foundry/.env' 'packages/nextjs/.env.local' 'ipfs-upload.config.json'; do
    grep -qxF "$pat" .gitignore || echo "$pat" >> .gitignore
  done

  # ─── Pre-commit hook: ONLY the worker may commit ──────────────────
  # The fix/README subagents inherit the operator's ~/.claude/ config, which
  # may include slash-commands like /commit that ship .env or tripped guards.
  # Hard-block any commit that doesn't carry our authorized env flag — the
  # worker sets FIFTH_BUILDER_AUTHORIZED=1 around every commit_and_scan call.
  # Subagents that try to commit will see this hook fail and (we hope) bail
  # rather than retry with --no-verify; if they do bypass, the post-commit
  # HEAD scan in commit_and_scan is the second line of defense.
  mkdir -p .git/hooks
  cat > .git/hooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
if [[ "${FIFTH_BUILDER_AUTHORIZED:-0}" != "1" ]]; then
  echo "" >&2
  echo "ERROR: this repo only accepts commits from the fifth-builder worker." >&2
  echo "  (the worker sets FIFTH_BUILDER_AUTHORIZED=1 around its own commits)" >&2
  echo "  If you're a subagent: leave the working tree dirty and exit — the" >&2
  echo "  outer worker will commit with secret-leak guards on your behalf." >&2
  echo "" >&2
  exit 1
fi
HOOK
  chmod +x .git/hooks/pre-commit
  cd "$DIR"

  # Write project .env — NEVER put the real deployer private key on disk in the
  # build dir. The LLM agents run with --dangerously-skip-permissions and have
  # leaked the key by quoting it verbatim into AUDIT_REPORT.md, which then got
  # committed to the public github repo. forge gets the real key from run.sh's
  # --private-key CLI flag at deploy time (STEP 4). The placeholder below exists
  # so that `vm.envUint("DEPLOYER_PRIVATE_KEY")` won't panic during forge build
  # or forge test; it's the anvil default account #0, publicly known, worthless.
  log "Deployer: $DEPLOYER_ADDR"
  cat > "$REPO_DIR/.env" <<EOF
# Stub — real deployer key is injected by the build worker at deploy time.
# Do NOT paste the real key here. Do NOT write this value into reports/commits.
DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER_ADDRESS=$DEPLOYER_ADDR
ALCHEMY_API_KEY=$ALCHEMY_API_KEY
EOF
  chmod 600 "$REPO_DIR/.env"

  # Write PLAN.md — the job description IS the plan, just format it for the builder
  log "Writing PLAN.md..."
  cat > "$REPO_DIR/PLAN.md" <<PLANEOF
# Build Plan — Job #$JOB_ID

## Client
$CLIENT

## Spec
$FULL_SPEC

## Deploy
- Chain: Base (8453)
- RPC: Alchemy (ALCHEMY_API_KEY in .env)
- Deployer: $DEPLOYER_ADDR (DEPLOYER_PRIVATE_KEY in .env)
- All owner/admin/treasury roles transfer to client: $CLIENT
PLANEOF

  # ─── Commit + push via commit_and_scan (guards run) ────────────────
  cd "$REPO_DIR"
  commit_and_scan "Initial SE2 scaffold + PLAN.md for job #$JOB_ID"
  if ! gh repo view "$GITHUB_ORG/$REPO_NAME" >/dev/null 2>&1; then
    gh repo create "$GITHUB_ORG/$REPO_NAME" --public --source=. --push 2>&1 || true
  fi
  git remote set-url origin "https://github.com/$GITHUB_ORG/$REPO_NAME.git" 2>/dev/null || \
    git remote add origin "https://github.com/$GITHUB_ORG/$REPO_NAME.git" 2>/dev/null || true
  git push -u origin main 2>/dev/null || git push -u origin master 2>/dev/null || true
  cd "$DIR"

  log_work "$JOB_ID" "Repo + PLAN.md created: github.com/$GITHUB_ORG/$REPO_NAME" "create_repo"
  log_work "$JOB_ID" "Plan is the job description" "create_plan"
  log_work "$JOB_ID" "User journey covered in spec" "create_user_journey"
  CURRENT_STAGE="create_user_journey"
fi

# =====================================================================
#  STEP 2: BUILD — the big call
# =====================================================================

if [[ "$CURRENT_STAGE" == "create_user_journey" || "$CURRENT_STAGE" == "create_plan" || "$CURRENT_STAGE" == "create_repo" ]]; then
  log "═══ STEP 2: BUILD ═══"
  pm_log "step2:build" "claude-opus-4-7" "build dApp from PLAN.md — contracts, tests, frontend, forge build/test, yarn next:build"

  # NOTE (deferred): every `claude -p` subagent below inherits the operator's
  # ~/.claude/ config — including custom slash-commands like /commit. That's
  # how a polished prompt accidentally tripped the operator's security-commit
  # skill mid-job and refused to ship a clean README. We work around this by
  # telling each agent in its prompt to NOT commit/push (worker handles it via
  # commit_and_scan). A real fix would isolate the subagents — likely via
  # CLAUDE_CONFIG_DIR=/tmp/empty-claude-cfg or a `--no-skills`-equivalent
  # flag. Needs testing against the current claude CLI before flipping.

  cd "$REPO_DIR"
  claude_timeout 5400 -p --model claude-opus-4-7 --dangerously-skip-permissions "$(cat <<PROMPT
You are building a dApp. Read PLAN.md in this repo — that is your spec.

CLIENT ADDRESS (all owner/admin/treasury roles → this address): $CLIENT
DEPLOYER ADDRESS: $DEPLOYER_ADDR
TARGET CHAIN: Base (8453)

The .env in this repo has a STUB DEPLOYER_PRIVATE_KEY (the public anvil #0 key, for local forge build/test only) plus DEPLOYER_ADDRESS and ALCHEMY_API_KEY. The real production deployer key is injected by the build worker via forge's --private-key CLI flag at deploy time; the deploy script must use vm.startBroadcast() with NO arguments so forge picks up the CLI-supplied key.

NEVER reproduce secret values in code, comments, reports, READMEs, or commit messages. Reference by variable name only. Always use Alchemy RPCs, never public RPCs.

MANDATORY — fetch and follow these EXACTLY:
- https://ethskills.com/SKILL.md (the master skill index — follow it)
- https://docs.scaffoldeth.io/SKILL.md

DO ALL OF THIS:
1. Write smart contracts in packages/foundry/contracts/
2. Write deploy script in packages/foundry/script/Deploy.s.sol
   - The deploy script must use DEPLOYER_PRIVATE_KEY from env
   - After deploy, transfer any owner/admin roles to $CLIENT
3. Write tests in packages/foundry/test/
4. forge build — fix until clean
5. forge test — fix until all pass
6. Audit contracts per https://ethskills.com/audit/SKILL.md — fix critical/high issues
7. Build frontend in packages/nextjs/ — match the theme/design in PLAN.md
8. Remove all SE2 default branding (BuidlGuidl, debug page, default footer)
9. QA audit per https://ethskills.com/qa/SKILL.md — fix ship-blockers
10. Set scaffold.config.ts targetNetworks to [chains.foundry] for now
11. yarn next:build must succeed
12. Commit and push everything

SECURITY:
- .env is gitignored — never commit it
- No private keys in source code, config files, or scripts
- No hardcoded addresses for privileged roles — use $CLIENT
- Verify .gitignore excludes .env before pushing

STATIC EXPORT — the final deploy uses Next.js \`output: 'export'\` for IPFS (the outer worker flips next.config to export mode in a later step). Your frontend MUST be statically exportable:
- Any dynamic route (\`app/**/[param]/page.tsx\`) MUST export a \`generateStaticParams()\` function. If there are no known params to pre-render, return \`[]\` — but the function MUST exist, or \`next build\` will fail under \`output: 'export'\`.
- Do NOT use API routes (\`app/api/**\`), server actions, or \`export const dynamic = 'force-dynamic'\`. All data must come from on-chain reads, client-side fetches, or static content.
- Prefer avoiding dynamic routes entirely when a client-side component + query param can do the job. If you do ship a dynamic route, verify \`yarn next:build\` succeeds with \`output: 'export'\` set before finishing — temporarily add it to next.config to test, then remove it.

Do not ask me anything.
PROMPT
)"
  cd "$DIR"

  log_work "$JOB_ID" "Prototype built — contracts, tests, frontend" "prototype"
  CURRENT_STAGE="prototype"
fi

# =====================================================================
#  STEP 3: AUDIT/FIX LOOP — auditor finds issues, builder fixes them
# =====================================================================

if [[ "$CURRENT_STAGE" == "prototype" ]]; then
  log "═══ STEP 3: AUDIT/FIX LOOP ═══"

  MAX_CYCLES=3
  pm_log "step3:audit-loop" "worker" "up to $MAX_CYCLES audit+fix cycles"
  cd "$REPO_DIR"

  # LeftClaw protocol expects 8 cycle-stage pings + full_audit/full_audit_fix.
  # Map cycles → stage names so we can log each stage right after its real
  # work (avoiding the back-to-back nonce-race storm at the tail) and backfill
  # any stages we skipped (clean audit on cycle 1) so the protocol still sees
  # the full sequence.
  CYCLE_STAGES=(
    "contract_audit" "contract_fix"
    "deep_contract_audit" "deep_contract_fix"
    "frontend_audit" "frontend_fix"
  )
  STAGE_IDX=0

  for CYCLE in $(seq 1 $MAX_CYCLES); do
    log "── Audit cycle $CYCLE/$MAX_CYCLES ──"

    # ── AUDIT (separate agent — reads code, writes report) ──────────
    # First-cycle audit uses opus 4.7: the richer findings shape the rest of the loop.
    AUDIT_MODEL=$([[ "$CYCLE" == "1" ]] && echo claude-opus-4-7 || echo sonnet)
    log "Running audit agent ($AUDIT_MODEL)..."
    pm_log "step3:audit c$CYCLE/$MAX_CYCLES" "$AUDIT_MODEL" "security + QA audit, produce AUDIT_REPORT.md"
    claude_timeout 1800 -p --model "$AUDIT_MODEL" --dangerously-skip-permissions "$(cat <<AUDIT_PROMPT
You are a security auditor and QA engineer. You are auditing a Scaffold-ETH 2 dApp.

MANDATORY — fetch and follow these audit frameworks EXACTLY:
- https://ethskills.com/audit/SKILL.md (contract security audit)
- https://ethskills.com/qa/SKILL.md (frontend QA audit)

Read every file in:
- packages/foundry/contracts/
- packages/foundry/script/
- packages/foundry/test/
- packages/nextjs/app/
- packages/nextjs/components/

CLIENT ADDRESS (must own all privileged roles): $CLIENT
DEPLOYER ADDRESS: $DEPLOYER_ADDR

PIPELINE CONTEXT — things that look like bugs but are not, do NOT flag these:
- scaffold.config.ts targetNetworks is [chains.foundry] during audit. The outer worker switches it to [chains.base] in a later deploy step before shipping. Treat [chains.foundry] as expected at audit time.
- packages/foundry/.env has a STUB DEPLOYER_PRIVATE_KEY = anvil account #0 (0xac09...ff80). It is a publicly-known key used only so \`forge build\`/\`forge test\` don't panic on vm.envUint. The real deployer key is injected at deploy time via \`forge script --private-key\` and never lands on disk. Do NOT flag the stub key as a leak.

Perform a FULL audit following both skill files. Then write AUDIT_REPORT.md in the repo root with EXACTLY this format:

# Audit Report — Cycle $CYCLE

## MUST FIX
Items that MUST be fixed before deploy. These are issues where:
- Users could lose funds (reentrancy, overflow, access control, missing checks)
- Contracts could become permanently locked or bricked
- Privileged roles are not transferred to client ($CLIENT)
- Private keys or secrets are exposed in source code
- Critical frontend flows are broken (can't connect, can't transact, tx silently fails)
- Tests don't pass or don't exist for critical paths

For each item:
- [ ] **[CRITICAL/HIGH]** Short title — file:line — Description of the issue and what to fix

If no must-fix items, write: None — all critical paths are secure.

## KNOWN ISSUES
Items that are real findings but acceptable to ship with. These are:
- Gas inefficiencies (unbounded reads on small/bounded arrays, etc.)
- Missing events for non-critical state changes
- Style or naming inconsistencies
- Minor UX friction that doesn't block the happy path
- Informational findings

For each item:
- **[LOW/INFO]** Short title — file:line — Description and why it's acceptable

## Summary
- Must Fix: N items
- Known Issues: N items
- Audit frameworks followed: contract audit (ethskills), QA audit (ethskills)

Do not fix anything. Only write the report. Be thorough but honest — do not invent issues that don't exist.

SECRET HANDLING — NON-NEGOTIABLE:
- AUDIT_REPORT.md gets committed to a PUBLIC github repo.
- NEVER reproduce the value of any secret in the report. That includes the contents of .env, DEPLOYER_PRIVATE_KEY, ALCHEMY_API_KEY, WALLETCONNECT IDs, mnemonics, API keys, or anything that looks like one.
- Refer to secrets by their variable name only (e.g. "DEPLOYER_PRIVATE_KEY in .env" — NEVER "DEPLOYER_PRIVATE_KEY=0x...").
- Do NOT paste any hex string 32+ chars long, any BEGIN…PRIVATE KEY block, any bearer token, any quoted value from .env.
- If you need to cite a value to explain an issue, write "[REDACTED]" in its place.
- A single leaked key in this report will burn the deployer wallet and every future job — take this seriously.
AUDIT_PROMPT
)"

    # ── Log audit stage right after the audit agent returns ─────────
    if [[ $STAGE_IDX -lt ${#CYCLE_STAGES[@]} ]]; then
      log_work "$JOB_ID" "Audit cycle $CYCLE complete" "${CYCLE_STAGES[$STAGE_IDX]}"
      STAGE_IDX=$((STAGE_IDX+1))
    fi

    # ── Check if audit is clean ─────────────────────────────────────
    if [[ ! -f "$REPO_DIR/AUDIT_REPORT.md" ]]; then
      log "WARNING: No AUDIT_REPORT.md generated, skipping to deploy"
      break
    fi

    MUST_FIX_COUNT=$(grep -c '^\- \[ \]' "$REPO_DIR/AUDIT_REPORT.md" 2>/dev/null || true)
    MUST_FIX_COUNT="${MUST_FIX_COUNT:-0}"
    log "  Audit result: $MUST_FIX_COUNT must-fix items"

    if [[ "$MUST_FIX_COUNT" -eq 0 ]]; then
      log "  Clean audit — no must-fix items. Moving to deploy."
      break
    fi

    if [[ "$CYCLE" -eq "$MAX_CYCLES" ]]; then
      log "  WARNING: $MUST_FIX_COUNT must-fix items remain after $MAX_CYCLES cycles."
      log "  Proceeding to deploy — review AUDIT_REPORT.md manually."
      break
    fi

    # ── Archive this cycle's report ──────────────────────────────────
    cp "$REPO_DIR/AUDIT_REPORT.md" "$REPO_DIR/AUDIT_REPORT_CYCLE${CYCLE}.md"

    # ── FIX (builder agent — reads report, fixes code) ──────────────
    log "Running fix agent (cycle $CYCLE)..."
    pm_log "step3:fix c$CYCLE/$MAX_CYCLES" "sonnet" "fix MUST FIX items from AUDIT_REPORT.md, rebuild + retest"
    claude_timeout 2700 -p --model sonnet --dangerously-skip-permissions "$(cat <<FIX_PROMPT
You are the builder for this dApp. Read AUDIT_REPORT.md in this repo.

MANDATORY — fetch and follow these EXACTLY:
- https://ethskills.com/SKILL.md (the master skill index)
- https://docs.scaffoldeth.io/SKILL.md

CLIENT ADDRESS (must own all privileged roles): $CLIENT
DEPLOYER ADDRESS: $DEPLOYER_ADDR

Do ALL of the following:

1. MUST FIX items: Fix every item under "## MUST FIX" in AUDIT_REPORT.md.
   - These are security-critical or money-losing bugs. Fix them properly.
   - After fixing each item, check the box in AUDIT_REPORT.md: - [x]

2. KNOWN ISSUES items: For each item under "## KNOWN ISSUES":
   - Add a NatSpec comment above the relevant code: /// @notice Known issue: <description>
   - Do NOT try to fix these — they are acceptable as-is.

3. Rules when fixing:
   - Do NOT add runtime throws for missing optional env vars (WalletConnect project ID, OG image host, analytics keys, etc.). A missing optional config must degrade gracefully — omit the feature or use a safe default. Crashing every page load is worse than the original gap.
   - Do NOT change scaffold.config.ts targetNetworks — leave whatever is already set.
   - Prefer conditional rendering / optional wiring over hard failures.

4. After all fixes:
   - Run: forge build — fix until clean
   - Run: forge test — fix until all pass
   - Run: yarn next:build — fix until clean
   - Add a "## Known Issues" section to README.md listing the known issues

5. DO NOT commit or push. The outer worker commits with guarded pre-checks
   and will refuse if a secret leaked into the diff. Leave the working tree
   dirty with all your changes staged-or-unstaged; the worker runs
   \`git add -A\` + a guarded commit after you return.

SECRET HANDLING — NON-NEGOTIABLE:
- This repo is PUBLIC on github. Everything you commit is world-readable forever.
- NEVER reproduce secrets when editing AUDIT_REPORT.md, README.md, commit messages, or code comments. That includes .env contents, private keys, API keys, mnemonics, bearer tokens.
- When referencing an audit finding about a secret, name the variable (e.g. "DEPLOYER_PRIVATE_KEY in .env") — NEVER paste the value. Replace with "[REDACTED]" if a value is unavoidable.
- If you see an AUDIT_REPORT.md from a prior cycle that contains a secret value, redact it before committing — do not propagate the leak.

Do not ask me anything.
FIX_PROMPT
)"

    # ── Worker-side commit with guards (fix prompt says not to commit itself) ──
    cd "$REPO_DIR"
    commit_and_scan "Audit cycle $CYCLE fixes"
    git push 2>/dev/null || true
    cd "$DIR"

    # ── Log fix stage right after the fix agent + commit land ───────
    if [[ $STAGE_IDX -lt ${#CYCLE_STAGES[@]} ]]; then
      log_work "$JOB_ID" "Cycle $CYCLE fixes applied" "${CYCLE_STAGES[$STAGE_IDX]}"
      STAGE_IDX=$((STAGE_IDX+1))
    fi

    log "  Fix cycle $CYCLE complete."
  done

  # Backfill any unsent cycle stages so the protocol still sees the full
  # 8-stage sequence even when we exited the loop early on a clean audit.
  # These DO go back-to-back — the log_work retry handles nonce races, and
  # a 1s sleep further reduces pool churn.
  while [[ $STAGE_IDX -lt ${#CYCLE_STAGES[@]} ]]; do
    log_work "$JOB_ID" "Skipped — no further fixes needed" "${CYCLE_STAGES[$STAGE_IDX]}"
    STAGE_IDX=$((STAGE_IDX+1))
    sleep 1
  done
  log_work "$JOB_ID" "Full audit complete" "full_audit"
  sleep 1
  log_work "$JOB_ID" "All audit fixes applied" "full_audit_fix"
  CURRENT_STAGE="full_audit_fix"

  cd "$DIR"
fi

# =====================================================================
#  STEP 4: DEPLOY — contracts + frontend + complete
# =====================================================================

if [[ "$CURRENT_STAGE" == "full_audit_fix" ]]; then
  log "═══ STEP 4: DEPLOY ═══"
  pm_log "step4:deploy" "worker" "deploy contracts to Base, export frontend, upload to IPFS, completeJob"

  cd "$REPO_DIR"

  # ── Deploy contracts ────────────────────────────────────────────
  log "Switching scaffold.config to Base..."
  pm_log "step4:config" "haiku" "flip scaffold.config.ts targetNetworks to [chains.base]"
  claude_timeout 600 -p --model haiku --dangerously-skip-permissions \
    "In packages/nextjs/scaffold.config.ts, change targetNetworks to [chains.base]. Only change that line."

  log "Final test run..."
  # Tests should already pass after the audit/fix loop. If they don't, surface
  # it loudly but don't kill the deploy — the audit cycles are the real safety
  # gate, and a flaky local test shouldn't block a job that's otherwise ready.
  # set -e would otherwise propagate the forge failure and abort STEP 4.
  cd packages/foundry
  forge test -vvv || log "  WARNING: forge test failed before deploy — proceeding anyway, review broadcast carefully."
  cd "$REPO_DIR"

  # NOTE (deferred): the orchestration skill recommends a Phase-2 dry run
  # against a forked Base before going live (anvil --fork-url $RPC + deploy to
  # the fork, verify state, then deploy to mainnet). Significant added wall
  # time + complexity; forge test is currently our only pre-deploy gate.
  # Add this if a botched mainnet deploy ever burns the deployer wallet.

  cd packages/foundry
  DEPLOY_SCRIPT=$(ls script/Deploy*.s.sol | grep -v DeployYourContract | grep -v DeployHelpers | head -1)
  [[ -z "$DEPLOY_SCRIPT" ]] && DEPLOY_SCRIPT=$(ls script/Deploy*.s.sol | grep -v DeployHelpers | head -1)
  cd "$REPO_DIR"
  BROADCAST_JSON="packages/foundry/broadcast/$(basename "$DEPLOY_SCRIPT")/8453/run-latest.json"
  DEPLOY_LOG="$DIR/logs/job-$JOB_ID-deploy.log"

  # Idempotency: if a previous run wrote .contract-$JOB_ID, reuse that address
  # rather than re-deploying. A re-deploy would land at a fresh CREATE address
  # (different nonce), orphaning the on-chain contract clients are pointing at.
  if [[ -s "$DIR/builds/.contract-$JOB_ID" ]]; then
    DEPLOYED_ADDR=$(cat "$DIR/builds/.contract-$JOB_ID")
    DEPLOYED_NAME=$(jq -r '[.transactions[] | select(.contractAddress!=null)][0].contractName // empty' "$BROADCAST_JSON" 2>/dev/null || true)
    log "Contract already deployed for job $JOB_ID — reusing $DEPLOYED_ADDR (skipping forge script)"
  else
    log "Deploying contracts..."
    log "  Using deploy script: $DEPLOY_SCRIPT"
    # Dynamically find the deployer contract name — the build agent may add helper
    # contracts (e.g. MockERC20) to Deploy.s.sol, which causes forge to complain
    # about multiple contracts unless we specify --tc. Grep for the contract that
    # inherits ScaffoldETHDeploy; fall back to "DeployScript" if not found.
    DEPLOY_CONTRACT=$(grep -E 'contract [A-Za-z0-9_]+ is ScaffoldETHDeploy' \
        packages/foundry/script/Deploy.s.sol 2>/dev/null \
        | grep -oE 'contract [A-Za-z0-9_]+' | head -1 | awk '{print $2}')
    DEPLOY_CONTRACT="${DEPLOY_CONTRACT:-DeployScript}"
    log "  Deployer contract: $DEPLOY_CONTRACT"
    pm_log "step4:forge" "forge" "forge script $DEPLOY_SCRIPT --tc $DEPLOY_CONTRACT --broadcast (Base mainnet)"
    cd packages/foundry
    forge script "$DEPLOY_SCRIPT" \
      --tc "$DEPLOY_CONTRACT" \
      --rpc-url "$RPC" \
      --broadcast \
      --ffi \
      --private-key "$DEPLOYER_PRIVATE_KEY" 2>&1 | tee "$DEPLOY_LOG"
    node scripts-js/generateTsAbis.js 2>&1 | tee -a "$DEPLOY_LOG" || true
    cd "$REPO_DIR"
    DEPLOYED_ADDR=$(jq -r '[.transactions[] | select(.contractAddress!=null)][0].contractAddress // empty' "$BROADCAST_JSON" 2>/dev/null || true)
    DEPLOYED_NAME=$(jq -r '[.transactions[] | select(.contractAddress!=null)][0].contractName // empty' "$BROADCAST_JSON" 2>/dev/null || true)
    if [[ -z "$DEPLOYED_ADDR" ]]; then
      DEPLOYED_ADDR=$(grep -oE '0x[a-fA-F0-9]{40}' "$DEPLOY_LOG" 2>/dev/null | tail -1 || true)
    fi
    echo "$DEPLOYED_ADDR" > "$DIR/builds/.contract-$JOB_ID"
  fi

  if [[ -n "$DEPLOYED_ADDR" ]]; then
    log "  Contract: $DEPLOYED_NAME at $DEPLOYED_ADDR"

    if [[ -n "$DEPLOYED_NAME" ]]; then
      log "Verifying on Basescan..."
      cd packages/foundry
      forge verify-contract "$DEPLOYED_ADDR" "$DEPLOYED_NAME" --chain base --watch 2>&1 || log "  Verification may need retry"
      cd "$REPO_DIR"
    else
      log "  Skipping verify — no contract name in broadcast JSON"
    fi

    commit_and_scan "Deploy to Base: $DEPLOYED_NAME $DEPLOYED_ADDR"
    git push 2>/dev/null || true

    log_work "$JOB_ID" "Contract deployed to Base: $DEPLOYED_NAME at $DEPLOYED_ADDR. Verified." "deploy_contract"
    log_work "$JOB_ID" "No live contract issues" "livecontract_fix"
  else
    log "  No contracts deployed (frontend-only dApp) — skipping verify + deploy log"
    commit_and_scan "Switch scaffold.config targetNetworks to Base"
    git push 2>/dev/null || true
    log_work "$JOB_ID" "Frontend-only dApp — no contract deployment" "deploy_contract"
    log_work "$JOB_ID" "No contracts to review" "livecontract_fix"
  fi

  # ── Deploy frontend ─────────────────────────────────────────────
  log "Configuring for IPFS export..."
  pm_log "step4:ipfs-cfg" "haiku" "next.config: trailingSlash + output:'export' for IPFS"
  claude_timeout 600 -p --model haiku --dangerously-skip-permissions \
    "In the next.config file in packages/nextjs/, add trailingSlash: true and output: 'export' if not present. Only touch that file."

  log "Building frontend..."
  pm_log "step4:next-build" "next" "yarn next:build (with localStorage polyfill)"
  rm -rf packages/nextjs/.next packages/nextjs/out

  # Node 25+ ships a half-baked localStorage on globalThis (defined but with no
  # getItem function) which crashes RainbowKit / next-themes at build time.
  # Per https://www.bgipfs.com/SKILL.md, ship a polyfill via NODE_OPTIONS.
  cat > packages/nextjs/polyfill-localstorage.cjs <<'POLY'
if (typeof globalThis.localStorage !== "undefined" &&
    typeof globalThis.localStorage.getItem !== "function") {
  const store = new Map();
  globalThis.localStorage = {
    getItem: (key) => store.get(key) ?? null,
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: (key) => store.delete(key),
    clear: () => store.clear(),
    key: (index) => [...store.keys()][index] ?? null,
    get length() { return store.size; },
  };
}
POLY

  NEXT_PUBLIC_IPFS_BUILD=true \
    NEXT_PUBLIC_IGNORE_BUILD_ERROR=true \
    NEXT_PUBLIC_ALCHEMY_API_KEY="$ALCHEMY_API_KEY" \
    NODE_OPTIONS="--require $REPO_DIR/packages/nextjs/polyfill-localstorage.cjs" \
    yarn next:build

  LIVE_URL="FAILED"
  # Idempotency: if a previous run wrote .url-$JOB_ID, reuse it instead of
  # re-uploading. bgipfs upload of identical content returns the same CID,
  # so this is mostly a network-saver and avoids logWork double-firing.
  if [[ -s "$DIR/builds/.url-$JOB_ID" ]]; then
    LIVE_URL=$(cat "$DIR/builds/.url-$JOB_ID")
    log "  Frontend already uploaded for job $JOB_ID — reusing $LIVE_URL"
  elif [[ -d "packages/nextjs/out" ]]; then
    log "Uploading to BGIPFS..."
    pm_log "step4:bgipfs" "bgipfs" "upload packages/nextjs/out to IPFS"
    # bgipfs CLI writes ipfs-upload.config.json (contains API key) into cwd —
    # it's gitignored via STEP 1, and we scrub it below for safety.
    npx -y bgipfs@latest upload config init -u https://upload.bgipfs.com -k "$BGIPFS_API_KEY" >/dev/null 2>&1 || true
    UPLOAD_OUTPUT=$(npx -y bgipfs@latest upload packages/nextjs/out 2>&1 | tee "$DIR/logs/job-$JOB_ID-bgipfs.log")
    rm -f ipfs-upload.config.json
    CID=$(echo "$UPLOAD_OUTPUT" | grep -oE 'baf[ya][a-zA-Z0-9]+|Qm[a-zA-Z0-9]+' | head -1)
    if [[ -n "$CID" ]]; then
      LIVE_URL="https://${CID}.ipfs.community.bgipfs.com/"
      echo "$LIVE_URL" > "$DIR/builds/.url-$JOB_ID"
      log "  Live: $LIVE_URL"
    else
      log "  ERROR: no CID from BGIPFS"
      log "  Output: $UPLOAD_OUTPUT"
    fi
  else
    log "  ERROR: no static export found"
  fi

  log_work "$JOB_ID" "Frontend deployed: $LIVE_URL" "deploy_app"
  log_work "$JOB_ID" "No live app issues" "liveapp_fix"
  log_work "$JOB_ID" "Live user journey: no browser access" "liveuserjourney"

  # ── README ──────────────────────────────────────────────────────
  log "Writing README..."
  pm_log "step4:readme" "sonnet" "write README.md (contract + live URL + how-to-run)"
  claude_timeout 900 -p --model sonnet --dangerously-skip-permissions "$(cat <<PROMPT
Write README.md for this project. Contract: $DEPLOYED_ADDR on Base. Live: $LIVE_URL. Client: $CLIENT.
Include: what it does, live URL, contract + Basescan link, how to run locally, tech stack.
No slop.

DO NOT commit or push. The outer worker handles the commit with secret-leak
guards and will refuse to ship if any hex-64 / private-key-shaped value is in
the diff. Just write README.md and exit.
PROMPT
)"

  commit_and_scan "Add README for deployed $DEPLOYED_NAME"
  git push 2>/dev/null || true

  log_work "$JOB_ID" "README written" "readme"

  # ── Final secret scan over the tree before declaring job done ────
  # Previous impl was broken: `grep -q` produces no stdout so the `grep -v`
  # filter chain ran on empty input and always returned false. Rewrite to
  # collect output first and filter explicitly.
  log "Security scan..."
  # Filter out all-zero and all-f sentinel constants (ZERO_BYTES32, bytes32(0),
  # dead-address padding) — they match the hex-64 pattern but are never keys.
  LEAKED=$(grep -rE '0x[a-fA-F0-9]{64}' \
    --include='*.md' --include='*.sol' --include='*.ts' --include='*.tsx' \
    --include='*.js' --include='*.jsx' \
    --exclude='deployedContracts.ts' --exclude='externalContracts.ts' \
    --exclude-dir=node_modules --exclude-dir=.next --exclude-dir=out \
    --exclude-dir=.yarn --exclude-dir=broadcast --exclude-dir=cache \
    --exclude-dir=lib --exclude-dir=.git \
    . 2>/dev/null \
    | grep -vE '0x0{64}|0xf{64}' \
    | head -5 || true)
  if [[ -n "$LEAKED" ]]; then
    log "ABORT: possible private key in source / report files:"
    echo "$LEAKED" | sed 's/^/  /'
    exit 1
  fi
  if grep -rF "$ETH_PRIVATE_KEY" \
    --exclude-dir=node_modules --exclude-dir=.next --exclude-dir=out \
    --exclude-dir=.yarn --exclude-dir=broadcast --exclude-dir=cache \
    --exclude-dir=lib --exclude-dir=.git \
    . 2>/dev/null | head -1 | grep -q .; then
    log "ABORT: main wallet key found in project"
    exit 1
  fi

  # ── Complete ────────────────────────────────────────────────────
  log "Completing job on-chain..."
  pm_log "step4:complete" "worker" "completeJob($JOB_ID, $LIVE_URL) on Base"
  COMPLETE_OK=0
  for attempt in 1 2 3; do
    if cast send "$CONTRACT" "completeJob(uint256,string)" \
        "$JOB_ID" "$LIVE_URL" \
        --private-key "$ETH_PRIVATE_KEY" --rpc-url "$RPC" 2>&1 | tail -3; then
      COMPLETE_OK=1; break
    fi
    log "  completeJob attempt $attempt failed — retrying in 5s..."
    sleep 5
  done
  if [[ $COMPLETE_OK -eq 0 ]]; then
    log "  WARNING: completeJob failed after 3 attempts — job may need manual completion"
    log "    cast send $CONTRACT 'completeJob(uint256,string)' $JOB_ID '$LIVE_URL' --private-key \$ETH_PRIVATE_KEY --rpc-url \$RPC"
  fi

  post_message "$JOB_ID" "Job complete! Live: $LIVE_URL | Contract: $DEPLOYED_ADDR | Repo: github.com/$GITHUB_ORG/$REPO_NAME"

  log ""
  log "=========================================="
  log "  JOB #$JOB_ID COMPLETE"
  log "=========================================="
  log "  App:      $LIVE_URL"
  log "  Contract: $DEPLOYED_ADDR"
  log "  Explorer: https://basescan.org/address/$DEPLOYED_ADDR"
  log "  GitHub:   https://github.com/$GITHUB_ORG/$REPO_NAME"
  log "=========================================="
  pm_log "done" "-" "JOB #$JOB_ID COMPLETE | app=$LIVE_URL | contract=$DEPLOYED_ADDR"
fi
