#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# deploy.sh — run a Claude Code PR-review agent inside a Relax sandbox.
#
#   ./deploy.sh            provision the sandbox + agent setup (leaves it running)
#   ./deploy.sh run        run the PR-review session now and print the output
#   ./deploy.sh logs       print the last Claude Code output
#   ./deploy.sh status     show sandbox status + last completion record
#   ./deploy.sh verify     check the agent setup, injected env, and model access
#
# Deploy flow:
#   1. Create sandbox (POST /v1/sandboxes) with the agent env injected
#   2. Wait for status "running", then for /execute to accept commands
#   3. Upload bootstrap.sh + prompt.txt
#   4. Install gh + Claude Code (daemonized — heavy npm installs 503 streaming)
#   5. Record the sandbox id to .sandbox-id for run/logs/destroy
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
STATE_FILE="$SCRIPT_DIR/.sandbox-id"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example -> .env and fill it in." >&2
  exit 1
fi
set -a; . "$ENV_FILE"; set +a

: "${endpoint:?endpoint not set in .env}"
: "${api_key:?api_key not set in .env}"

BASE="https://${endpoint}/v1"
AUTH="Authorization: Bearer ${api_key}"
RETRY="--retry 3 --retry-delay 2 --retry-all-errors"

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
sync_exec() {
  # Sync /execute. Prints the raw JSON response. Requires $ID.
  # Bounded so a wedged sandbox can never hang the script indefinitely.
  curl $RETRY --max-time 60 -fsS -X POST "$BASE/sandboxes/$ID/execute" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg cmd "$1" '{command: $cmd}')"
}

sync_stdout() {
  echo "$1" | jq -r .stdout 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//'
}

download() {
  # download <remote-path> — prints file contents from the sandbox.
  curl $RETRY --max-time 60 -fsS -H "$AUTH" \
    "$BASE/sandboxes/$ID/download?path=$1" 2>/dev/null | tr -d '\r'
}

require_sandbox() {
  [ -f "$STATE_FILE" ] || { echo "ERROR: $STATE_FILE not found. Run ./deploy.sh first." >&2; exit 1; }
  ID="$(cat "$STATE_FILE")"
}

cleanup_on_failure() {
  if [ -n "${ID:-}" ]; then
    echo "[cleanup] deleting sandbox $ID"
    curl $RETRY --max-time 30 -fsS -X DELETE -H "$AUTH" "$BASE/sandboxes/$ID" -o /dev/null || true
  fi
  rm -f "$STATE_FILE"
}

# -----------------------------------------------------------------------------
# deploy
# -----------------------------------------------------------------------------
do_deploy() {
  : "${target_repo:?target_repo not set in .env}"
  : "${github_token:?github_token not set in .env}"

  # Auto-delete the sandbox on any early exit; cleared once the agent setup is up.
  trap cleanup_on_failure EXIT

  echo "[create] name=${sandbox_name:-relaxai-pr-review} template=${sandbox_template:-cloud-runtime-template} networking=${networking_type:-limited}"

  local CREATE_BODY
  CREATE_BODY=$(jq -nc \
    --arg name "${sandbox_name:-relaxai-pr-review}" \
    --arg template "${sandbox_template:-cloud-runtime-template}" \
    --arg cpu "${cpu:-2}" \
    --arg memory "${memory:-4Gi}" \
    --arg storage "${storage:-5Gi}" \
    --arg key "$api_key" \
    --arg baseurl "https://${endpoint}" \
    --arg model "${model_id:-DeepSeek-V41-Flash}" \
    --arg apitimeout "${api_timeout_ms:-300000}" \
    --arg ccver "${claude_code_version:-2.1.146}" \
    --arg gh "$github_token" \
    --arg repo "$target_repo" \
    --arg dry "${dry_run:-1}" \
    --arg nettype "${networking_type:-limited}" \
    --arg hosts "${allowed_hosts:-}" \
    --arg timeout "${sandbox_timeout:-}" \
    '{
      name: $name,
      template: $template,
      resources: {cpu: $cpu, memory: $memory, storage: $storage, storage_type: "persistent"},
      env: {
        ANTHROPIC_API_KEY: $key,
        ANTHROPIC_BASE_URL: $baseurl,
        API_TIMEOUT_MS: $apitimeout,
        ANTHROPIC_DEFAULT_HAIKU_MODEL: $model,
        ANTHROPIC_DEFAULT_SONNET_MODEL: $model,
        ANTHROPIC_DEFAULT_OPUS_MODEL: $model,
        CLAUDE_CODE_DEFAULT_MODEL: $model,
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
        CLAUDE_CODE_DISABLE_ANALYTICS: "1",
        MAX_THINKING_TOKENS: "0",
        CLAUDE_CODE_VERSION: $ccver,
        GH_TOKEN: $gh,
        TARGET_REPO: $repo,
        DRY_RUN: $dry
      }
    }
    + (if $timeout == "" then {} else {timeout: $timeout} end)
    + (if $nettype == "limited" then
         {networking: ({type: "limited", allow_package_managers: true}
            + (if $hosts == "" then {} else {allowed_hosts: ($hosts | split(","))} end))}
       else {networking: {type: "unrestricted"}} end)')

  local RESP
  RESP=$(curl $RETRY -fsS -X POST "$BASE/sandboxes" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$CREATE_BODY")
  ID=$(echo "$RESP" | jq -r '.id // .name')
  echo "[create] id=$ID"

  # 2. Wait for status "running"
  local STATUS=""
  for i in $(seq 1 30); do
    STATUS=$(curl $RETRY --max-time 30 -fsS -H "$AUTH" "$BASE/sandboxes/$ID" 2>/dev/null | jq -r '.status // ""' || true)
    case "$STATUS" in
      running|Running) break ;;
    esac
    echo "[poll $i] status=${STATUS:-?}"
    sleep 3
  done
  echo "[ready]"

  # 3. Wait until /execute accepts commands
  for i in $(seq 1 20); do
    RESP=$(sync_exec 'echo ready' 2>/dev/null || true)
    [ "$(sync_stdout "$RESP")" = "ready" ] && break
    echo "[wait-exec $i]"
    sleep 3
  done

  # 4. Upload the bootstrap script and the prompt
  echo "[upload] bootstrap.sh -> /workspace/bootstrap.sh"
  curl $RETRY --max-time 60 -fsS -X POST "$BASE/sandboxes/$ID/upload" \
    -H "$AUTH" -F "path=/workspace/bootstrap.sh" -F "file=@$SCRIPT_DIR/bootstrap.sh" -o /dev/null

  echo "[upload] prompt.txt -> /workspace/prompt.txt"
  curl $RETRY --max-time 60 -fsS -X POST "$BASE/sandboxes/$ID/upload" \
    -H "$AUTH" -F "path=/workspace/prompt.txt" -F "file=@$SCRIPT_DIR/prompt.txt" -o /dev/null

  # 5. Install gh + Claude Code (daemonized; streaming /execute 503s on heavy work)
  echo "[install] gh + claude-code@${claude_code_version:-2.1.146} (daemonized; ~1-2 min)"
  RESP=$(sync_exec '[ -f /tmp/install.started ] && { echo started-already; exit 0; }; touch /tmp/install.started; rm -f /tmp/install.exit /tmp/install.log; ( bash /workspace/bootstrap.sh > /tmp/install.log 2>&1; echo $? > /tmp/install.exit ) & disown; echo started' || true)
  local KS
  KS=$(sync_stdout "$RESP")
  [[ "$KS" =~ ^started ]] || echo "[install] kickoff returned: ${KS:-<no response>}"

  local INSTALL_DONE=0 S
  for i in $(seq 1 90); do
    RESP=$(sync_exec '[ -f /tmp/install.exit ] && echo "done:$(cat /tmp/install.exit)" || echo running' 2>/dev/null || true)
    S=$(sync_stdout "$RESP")
    if [[ "$S" == done:* ]]; then
      echo "[install] $S"
      [ "$S" = "done:0" ] && INSTALL_DONE=1
      break
    fi
    [ $((i % 6)) -eq 0 ] && echo "[install poll $i/90]"
    sleep 5
  done

  if [ "$INSTALL_DONE" -ne 1 ]; then
    echo "[install] failed; last 30 lines of /tmp/install.log:"
    download /tmp/install.log 2>/dev/null | tail -30 || true
    echo "[hint] if this is a network/DNS error, the allowed_hosts list may be missing a"
    echo "       host — set networking_type=unrestricted in .env and re-run."
    exit 1
  fi

  # Agent setup is up — do not delete the sandbox on exit.
  trap - EXIT
  echo "$ID" > "$STATE_FILE"

  echo
  echo "==================================================================="
  echo "Sandbox is ready: $ID"
  echo "State file: $STATE_FILE"
  echo
  if [ -n "${sandbox_timeout:-}" ]; then echo "Expires in: $sandbox_timeout (or run ./destroy.sh)"; fi
  echo "Target repo: ${target_repo}   dry_run=${dry_run:-1}"
  echo
  echo "Verify the agent setup:"
  echo "  ./deploy.sh verify"
  echo
  echo "Run the review:"
  echo "  ./deploy.sh run"
  echo
  echo "Destroy:"
  echo "  ./destroy.sh"
  echo "==================================================================="
}

# -----------------------------------------------------------------------------
# operate the running agent
# -----------------------------------------------------------------------------
do_run() {
  require_sandbox
  local t="${claude_run_timeout:-300}"

  # The session writes straight to claude-output.log; we poll that file below and
  # print new bytes as they appear, so the operator sees output while it runs.
  # (The sandbox /execute waits for the whole process group, so the request is
  # fired in the background and never awaited directly.)
  # Model / base URL / repo / dry-run are passed at RUN time (not only baked at
  # sandbox creation), so changing them in .env takes effect on the next `run`
  # without a re-deploy. The API key still comes from the sandbox env (so it
  # never appears on a command line).
  local model="${model_id:-DeepSeek-V4-Pro}"
  local base="${ANTHROPIC_BASE_URL:-https://${endpoint}}"
  local repo="${target_repo:-}"
  local dry="${dry_run:-1}"
  local envprefix
  envprefix="$(jq -nr --arg m "$model" --arg b "$base" --arg r "$repo" --arg d "$dry" \
    '"CLAUDE_CODE_DEFAULT_MODEL="+($m|@sh)
     +" ANTHROPIC_DEFAULT_HAIKU_MODEL="+($m|@sh)
     +" ANTHROPIC_DEFAULT_SONNET_MODEL="+($m|@sh)
     +" ANTHROPIC_DEFAULT_OPUS_MODEL="+($m|@sh)
     +" ANTHROPIC_BASE_URL="+($b|@sh)
     +" TARGET_REPO="+($r|@sh)
     +" DRY_RUN="+($d|@sh)')"

  local inner
  inner='cd /workspace; rm -f /workspace/completion.txt /workspace/claude-output.log; '
  inner+="$envprefix timeout --kill-after=10 $t claude --print --dangerously-skip-permissions -p \"\$(cat /workspace/prompt.txt)\" > /workspace/claude-output.log 2>&1; "
  inner+='RC=$?; printf "exit_code=%s\ncompleted_at=%s\n" "$RC" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /workspace/completion.txt'

  echo "[run] running Claude Code session (model $model, timeout ${t}s)…"

  curl $RETRY --max-time $(( t + 60 )) -fsS -X POST "$BASE/sandboxes/$ID/execute" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg cmd "$inner" '{command:$cmd}')" >/dev/null 2>&1 &
  local reqpid=$!

  # Wait for the session to finish. The sandbox /execute waits on the process
  # group, so the request runs in the background and we poll for completion.
  local waited=0 step=5 limit=$(( t + 90 ))
  while [ "$waited" -lt "$limit" ]; do
    if [ "$(sync_stdout "$(sync_exec '[ -f /workspace/completion.txt ] && echo done || echo running' 2>/dev/null || true)")" = done ]; then
      break
    fi
    kill -0 "$reqpid" 2>/dev/null || break
    sleep "$step"; waited=$((waited + step))
    [ $((waited % 30)) -eq 0 ] && echo "[run] waiting (${waited}s)"
  done
  wait "$reqpid" 2>/dev/null || true

  # Print the report once. Prefer the session log (the agent's final message:
  # tally + review); fall back to the review file(s) if it ended up empty.
  echo
  local body files f
  body="$(download /workspace/claude-output.log 2>/dev/null || true)"
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
  else
    files="$(sync_stdout "$(sync_exec 'ls -1 /workspace/review*.md 2>/dev/null' || true)")"
    if [ -n "$files" ]; then
      echo "[run] (session log empty — showing the review file(s))"
      for f in $files; do echo "---- $f ----"; download "$f" 2>/dev/null; echo; done
    else
      echo "[run] no output captured"
    fi
  fi

  echo
  echo "[run] ---- completion.txt ----"
  download /workspace/completion.txt 2>/dev/null || echo "(not completed)"
}

do_logs() {
  require_sandbox
  download /workspace/claude-output.log 2>/dev/null | tail -80 || echo "(no output yet)"
}

do_status() {
  require_sandbox
  echo "[status] sandbox $ID"
  curl $RETRY --max-time 30 -fsS -H "$AUTH" "$BASE/sandboxes/$ID" 2>/dev/null | jq '{id, name, status, created_at, timeout}' || true
  echo "--- completion.txt ---"
  download /workspace/completion.txt 2>/dev/null || echo "(no run yet)"
}

do_verify() {
  require_sandbox
  echo "[verify] sandbox $ID"

  # Use the same run-time values do_run uses, so this checks the model that a
  # `run` would actually talk to (not just whatever was baked at creation).
  local model="${model_id:-DeepSeek-V4-Pro}"
  local base="${ANTHROPIC_BASE_URL:-https://${endpoint}}"

  echo "--- agent setup (expect node v22, gh, claude) ---"
  sync_stdout "$(sync_exec 'node --version; gh --version | head -1; claude --version')"
  echo "--- injected env ---"
  sync_stdout "$(sync_exec 'printf "ANTHROPIC_BASE_URL=%s\n" "${ANTHROPIC_BASE_URL:-MISSING}"; printf "CLAUDE_CODE_DEFAULT_MODEL=%s\n" "${CLAUDE_CODE_DEFAULT_MODEL:-MISSING}"; printf "TARGET_REPO=%s\n" "${TARGET_REPO:-MISSING}"; printf "DRY_RUN=%s\n" "${DRY_RUN:-MISSING}"; printf "ANTHROPIC_API_KEY=%s\n" "$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo set || echo MISSING)"; printf "GH_TOKEN=%s\n" "$([ -n "${GH_TOKEN:-}" ] && echo set || echo MISSING)"')"

  echo "--- model reachable: $model @ $base ---"
  # Capture the HTTP status and raw body so a bad model id or an auth failure is
  # reported explicitly, and exit non-zero — never a silent blank line.
  local envprefix probe raw rc
  envprefix="$(jq -nr --arg m "$model" --arg b "$base" \
    '"CLAUDE_CODE_DEFAULT_MODEL="+($m|@sh)+" ANTHROPIC_BASE_URL="+($b|@sh)')"
  probe="$envprefix"' code=$(curl -sS -m 30 -o /tmp/model.json -w "%{http_code}" -X POST "$ANTHROPIC_BASE_URL/v1/messages" -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d "{\"model\":\"$CLAUDE_CODE_DEFAULT_MODEL\",\"max_tokens\":512,\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}]}"); text=$(jq -r "[.content[]? | select(.type==\"text\") | .text] | join(\"\")" /tmp/model.json 2>/dev/null); if [ "$code" = "200" ] && [ -n "$text" ]; then echo "$text"; else echo "FAILED (http $code) for model $CLAUDE_CODE_DEFAULT_MODEL"; head -c 400 /tmp/model.json; echo; exit 1; fi'

  raw="$(sync_exec "$probe" 2>/dev/null || true)"
  if [ -z "$raw" ]; then
    echo "FAILED — no response from /execute"
    rc=1
  else
    rc="$(printf '%s' "$raw" | jq -r '.exit_code // 1' 2>/dev/null || echo 1)"
    printf '%s' "$raw" | jq -r '.stdout // empty' 2>/dev/null | tr -d '\r'
  fi

  if [ "${rc:-1}" != "0" ]; then
    echo
    echo "[verify] FAILED"
    exit 1
  fi
  echo
  echo "[verify] OK"
}

case "${1:-deploy}" in
  deploy) do_deploy ;;
  run)    do_run ;;
  logs)   do_logs ;;
  status) do_status ;;
  verify) do_verify ;;
  *) echo "usage: $0 [deploy|run|logs|status|verify]" >&2; exit 1 ;;
esac
