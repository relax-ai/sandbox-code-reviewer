#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# demo.sh — the relaxAI sandbox workshop.
#
#   ./demo.sh up                create the sandbox + install the agent (~2 min)
#   ./demo.sh verify            check tools, model access and the network policy
#   ./demo.sh review [PR]       agent clones, installs, tests, runs and reviews
#   ./demo.sh egress            same install, then again with example.com allowed
#   ./demo.sh limits [which]    network | memory (default: both)
#   ./demo.sh logs              replay the last agent session in full
#   ./demo.sh status            sandbox status + last completion record
#   ./demo.sh down              delete the sandbox
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.sandbox-id"
[ -f "$SCRIPT_DIR/.env" ] || { echo "ERROR: .env not found. cp .env.example .env and fill it in." >&2; exit 1; }
set -a; . "$SCRIPT_DIR/.env"; set +a

: "${endpoint:?endpoint not set in .env}"
: "${api_key:?api_key not set in .env}"

# endpoint may be a bare host (https assumed) or include a scheme, e.g. http://localhost:8080
case "$endpoint" in *://*) ORIGIN="${endpoint%/}" ;; *) ORIGIN="https://${endpoint}" ;; esac
API_HOST="$(printf '%s' "$ORIGIN" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"
BASE="$ORIGIN/v1"
AUTH="Authorization: Bearer ${api_key}"
RETRY=(--retry 3 --retry-delay 2 --retry-all-errors)
MODEL="${model_id:-DeepSeek-V41-Flash}"
# Only what the demo needs: the relaxAI API, GitHub (the demo repo) and the npm
# registry (bootstrap.sh installs Claude Code from it). Every other host,
# including other package registries, is denied.
ALLOWED="${allowed_hosts:-$API_HOST,github.com,api.github.com,codeload.github.com,objects.githubusercontent.com,raw.githubusercontent.com,registry.npmjs.org}"
# Shared in-sandbox helper: prints REACHED or BLOCKED for a URL.
PROBE='probe(){ c=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "$1"); [ "$c" = 000 ] && echo "BLOCKED  $1" || echo "REACHED  $1 (http $c)"; }; '

B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
say() { printf '%s\n' "${B}$*${N}"; }

# -----------------------------------------------------------------------------
# sandbox API helpers
# -----------------------------------------------------------------------------
api() { # api METHOD PATH [JSON]  (uses $ID in PATH if you put it there)
  local args=(-X "$1" "$BASE$2" -H "$AUTH" -H "Content-Type: application/json")
  [ $# -ge 3 ] && args+=(-d "$3")
  curl "${RETRY[@]}" --max-time 60 -fsS "${args[@]}"
}

exec_raw() { api POST "/sandboxes/$ID/execute" "$(jq -nc --arg c "$1" '{command:$c}')"; }
exec_out() { exec_raw "$1" 2>/dev/null | jq -r '.stdout // empty' 2>/dev/null | tr -d '\r' || true; }
# One quick try, no retries, for polling: a slow call counts as "not yet"
# instead of stalling the script for minutes.
exec_quick() {
  curl --max-time 10 -fsS -X POST "$BASE/sandboxes/$ID/execute" -H "$AUTH" \
    -H "Content-Type: application/json" -d "$(jq -nc --arg c "$1" '{command:$c}')" 2>/dev/null \
    | jq -r '.stdout // empty' 2>/dev/null || true
}
exec_show() { # run a command and show stdout, stderr and exit code
  local resp; resp="$(exec_raw "$1" 2>/dev/null || true)"
  [ -n "$resp" ] || { echo "${R}(no response from the sandbox: is it still alive?)${N}"; return 1; }
  printf '%s' "$resp" | jq -r '.stdout // ""' | tr -d '\r'
  local err; err="$(printf '%s' "$resp" | jq -r '.stderr // ""' | tr -d '\r')"
  [ -n "$err" ] && printf '%s\n' "${D}${err}${N}"
  echo "${D}exit_code=$(printf '%s' "$resp" | jq -r '.exit_code')${N}"
}

download() { curl "${RETRY[@]}" --max-time 60 -fsS -H "$AUTH" "$BASE/sandboxes/$ID/download?path=$1" 2>/dev/null | tr -d '\r'; }
upload()   { curl "${RETRY[@]}" --max-time 60 -fsS -X POST "$BASE/sandboxes/$ID/upload" -H "$AUTH" -F "path=$2" -F "file=@$1" -o /dev/null; }

networking_json() { # networking_json limited|unrestricted
  if [ "$1" = limited ]; then
    jq -nc --arg h "$ALLOWED" '{type:"limited", allow_package_managers:false, allowed_hosts:($h|split(","))}'
  else
    echo '{"type":"unrestricted"}'
  fi
}

require_sandbox() {
  [ -f "$STATE_FILE" ] || { echo "ERROR: no sandbox yet. Run ./demo.sh up first." >&2; exit 1; }
  ID="$(cat "$STATE_FILE")"
}

# create_sandbox NAME NETWORKING — prints the id once /execute accepts commands
create_sandbox() {
  local body id status
  # Names aren't unique on the platform, so add a random suffix: every
  # attendee's sandbox then has its own name in listings and dashboards.
  local name; name="$1-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  body=$(jq -nc \
    --arg name "$name" --arg template "${sandbox_template:-cloud-runtime-template}" \
    --arg cpu "${cpu:-2}" --arg mem "${memory:-4Gi}" --arg disk "${storage:-5Gi}" \
    --arg timeout "${sandbox_timeout:-}" --argjson net "$(networking_json "$2")" \
    --arg key "$api_key" --arg baseurl "$ORIGIN" --arg model "$MODEL" \
    --arg ccver "${claude_code_version:-2.1.146}" --arg repo "${target_repo:-}" \
    '{name:$name, template:$template, networking:$net,
      resources:{cpu:$cpu, memory:$mem, storage:$disk, storage_type:"persistent"},
      env:{ANTHROPIC_API_KEY:$key, ANTHROPIC_BASE_URL:$baseurl, API_TIMEOUT_MS:"300000",
           ANTHROPIC_MODEL:$model, CLAUDE_CODE_DEFAULT_MODEL:$model,
           ANTHROPIC_DEFAULT_OPUS_MODEL:$model, ANTHROPIC_DEFAULT_SONNET_MODEL:$model,
           ANTHROPIC_DEFAULT_HAIKU_MODEL:$model,
           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:"1", MAX_THINKING_TOKENS:"0",
           IS_SANDBOX:"1", CLAUDE_CODE_VERSION:$ccver,
           TARGET_REPO:$repo}}
     + (if $timeout == "" then {} else {timeout:$timeout} end)')

  id=$(api POST /sandboxes "$body" | jq -r '.id // empty')
  [ -n "$id" ] || { echo "ERROR: sandbox create returned no id" >&2; return 1; }
  echo "[create] $name id=$id networking=$2" >&2

  for i in $(seq 1 40); do
    status=$(api GET "/sandboxes/$id" 2>/dev/null | jq -r '.status // ""' || true)
    case "$status" in running|Running) break ;; esac
    echo "[poll $i] status=${status:-?}" >&2; sleep 3
  done
  # /execute can 503 for a few seconds after "running"
  for i in $(seq 1 20); do
    [ "$(ID=$id exec_out 'echo ready')" = ready ] && break
    echo "[wait-exec $i]" >&2; sleep 3
  done
  echo "$id"
}

# -----------------------------------------------------------------------------
# up / verify / down
# -----------------------------------------------------------------------------
do_up() {
  : "${target_repo:?target_repo not set in .env}"
  [ -f "$STATE_FILE" ] && { echo "A sandbox already exists ($(cat "$STATE_FILE")). Run ./demo.sh down first." >&2; exit 1; }

  ID="$(create_sandbox "${sandbox_name:-relaxai-workshop}" limited)"
  trap 'echo "[cleanup] deleting $ID"; api DELETE "/sandboxes/$ID" >/dev/null || true' EXIT

  upload "$SCRIPT_DIR/bootstrap.sh" /workspace/bootstrap.sh
  upload "$SCRIPT_DIR/prompt.txt" /workspace/prompt.txt
  echo "[upload] bootstrap.sh, prompt.txt"

  # Daemonized: heavy installs over one long /execute call are unreliable.
  exec_out 'rm -f /tmp/install.exit; ( bash /workspace/bootstrap.sh > /tmp/install.log 2>&1; echo $? > /tmp/install.exit ) & disown; echo started' >/dev/null
  local s=""
  for i in $(seq 1 90); do
    s="$(exec_out '[ -f /tmp/install.exit ] && cat /tmp/install.exit || echo running')"
    [ "$s" != running ] && [ -n "$s" ] && break
    [ $((i % 6)) -eq 0 ] && echo "[install] still going ($((i * 5))s)"
    sleep 5
  done
  if [ "$s" != 0 ]; then
    echo "[install] failed (exit=${s:-?}). Last lines of /tmp/install.log:"
    download /tmp/install.log | tail -20
    exit 1
  fi

  trap - EXIT
  echo "$ID" > "$STATE_FILE"
  echo
  say "Sandbox ready: $ID  (egress: limited)"
  echo "Next: ./demo.sh verify"
}

do_verify() {
  require_sandbox
  say "--- tools ---"
  exec_out 'node --version; git --version; claude --version'

  say "--- model: $MODEL ---"
  local probe
  probe='code=$(curl -sS -m 30 -o /tmp/m.json -w "%{http_code}" "$ANTHROPIC_BASE_URL/v1/messages" -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d "{\"model\":\"'"$MODEL"'\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}]}"); if [ "$code" = 200 ]; then echo "OK: $(jq -r "[.content[]?|select(.type==\"text\")|.text]|join(\"\")" /tmp/m.json)"; else echo "FAILED (http $code): $(head -c 300 /tmp/m.json)"; fi'
  exec_out "$probe"

  say "--- network policy (limited) ---"
  echo "Allowed:"
  tr ',' '\n' <<<"$ALLOWED" | sed 's/^/  /'
  echo "Denied:"
  echo "  every other host"
  # Prove the policy is in force: one allowed host and one denied host.
  local got
  got="$(exec_out "$PROBE probe https://api.github.com; probe https://example.com")"
  if grep -q 'REACHED  https://api.github.com' <<<"$got" && grep -q 'BLOCKED  https://example.com' <<<"$got"; then
    echo "${G}Check: api.github.com reachable, example.com blocked. The policy is in force.${N}"
  else
    echo "${R}Check failed, the policy isn't behaving as listed:${N}"; printf '%s\n' "$got" | sed 's/^/  /'
  fi
}

do_down() {
  require_sandbox
  api DELETE "/sandboxes/$ID" >/dev/null && echo "[down] deleted $ID"
  rm -f "$STATE_FILE"
}

do_status() {
  require_sandbox
  api GET "/sandboxes/$ID" | jq '{id, name, status, creationTime, networking}' || true
  echo "--- completion.txt ---"
  download /workspace/completion.txt || echo "(no run yet)"
}

# -----------------------------------------------------------------------------
# review — run the agent and render what it does, live
# -----------------------------------------------------------------------------
render() { # render compact|full  — stream-json lines in, readable output out
  # compact (review): one line per command the agent runs, then only its final
  #                   report. Its narration ("Let me check...") is left out.
  # full    (logs):   the whole transcript, including narration and output.
  jq -Rr --unbuffered --arg mode "${1:-compact}" '
    . as $line | (try fromjson catch {type: "raw"}) |
    if .type == "raw" then ($line | select(length > 0) | "\u001b[2m\(.)\u001b[0m")
    elif .type == "assistant" then
      .message.content[]? |
      if .type == "tool_use" and .name == "Bash" then
        "\u001b[36m  $ \(.input.command | split("\n")[0] | .[0:110])\u001b[0m"
      elif .type == "tool_use" and $mode == "full" then
        "\u001b[2m  [\(.name)] \(.input.file_path // .input.pattern // "")\u001b[0m"
      elif .type == "text" and $mode == "full" and (.text | length) > 0 then "\n\(.text)\n"
      else empty end
    elif .type == "user" and $mode == "full" then
      .message.content[]? | select(.type == "tool_result") |
      (.content | if type == "array" then map(.text? // "") | join("\n") else (. // "" | tostring) end)
      | split("\n") | map(select(length > 0)) | .[0:4]
      | map("\u001b[2m      \(.[0:150])\u001b[0m") | join("\n") | select(length > 0)
    elif .type == "result" then
      (if $mode == "compact" or .is_error then "\n\(.result // "")\n" else "" end)
      + "\u001b[2m[agent] finished in \(((.duration_ms // 0) / 1000) | floor)s, \(.num_turns // "?") turns\u001b[0m"
    else empty end'
}

do_review() {
  require_sandbox
  local pr="${1:-}" t="${claude_run_timeout:-600}" envp inner
  envp="$(jq -nr --arg m "$MODEL" --arg r "${target_repo:-}" --arg p "$pr" \
    '"ANTHROPIC_MODEL="+($m|@sh)+" CLAUDE_CODE_DEFAULT_MODEL="+($m|@sh)
     +" ANTHROPIC_DEFAULT_OPUS_MODEL="+($m|@sh)+" ANTHROPIC_DEFAULT_SONNET_MODEL="+($m|@sh)
     +" ANTHROPIC_DEFAULT_HAIKU_MODEL="+($m|@sh)
     +" TARGET_REPO="+($r|@sh)+" PR_NUMBER="+($p|@sh)')"

  inner='cd /workspace; rm -f completion.txt agent.jsonl review-PR-*.md; '
  inner+="$envp timeout --kill-after=10 $t claude --print --verbose --output-format stream-json --dangerously-skip-permissions -p \"\$(cat /workspace/prompt.txt)\" < /dev/null > /workspace/agent.jsonl 2>&1; "
  inner+='printf "exit_code=%s\ncompleted_at=%s\n" "$?" "$(date -u +%FT%TZ)" > /workspace/completion.txt'

  upload "$SCRIPT_DIR/prompt.txt" /workspace/prompt.txt   # so prompt edits apply without a redeploy
  say "[review] ${target_repo} ${pr:+PR #$pr }(model $MODEL)"
  # /execute holds the connection until the process exits, so fire it in the
  # background and follow the agent's transcript file instead.
  curl "${RETRY[@]}" --max-time $((t + 60)) -fsS -X POST "$BASE/sandboxes/$ID/execute" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg c "$inner" '{command:$c}')" >/dev/null 2>&1 &
  local req=$! seen=0 total waited=0 tmp
  tmp="$(mktemp)"

  while [ "$waited" -lt $((t + 90)) ]; do
    sleep 3; waited=$((waited + 3))
    download /workspace/agent.jsonl > "$tmp" || true
    total=$(wc -l < "$tmp" | tr -d ' ')
    if [ "$total" -gt "$seen" ]; then sed -n "$((seen + 1)),${total}p" "$tmp" | render compact; seen=$total; fi
    [ -n "$(download /workspace/completion.txt)" ] && break
    kill -0 "$req" 2>/dev/null || { sleep 3; [ -n "$(download /workspace/completion.txt)" ] && break; }
  done
  download /workspace/agent.jsonl > "$tmp" || true
  total=$(wc -l < "$tmp" | tr -d ' ')
  [ "$total" -gt "$seen" ] && sed -n "$((seen + 1)),${total}p" "$tmp" | render compact
  wait "$req" 2>/dev/null || true
  rm -f "$tmp"
  echo "${D}$(download /workspace/completion.txt | tr '\n' ' ')${N}"
}

do_logs() {
  require_sandbox
  download /workspace/agent.jsonl | render full
}

# -----------------------------------------------------------------------------
# egress — same install in two sandboxes: the default allowlist, then one
#          that also allows example.com
# -----------------------------------------------------------------------------
# run_install SANDBOX_ID — clone the egress branch and npm install it, as two
# separate commands so a failure names the step. Each has its own time limit,
# inside the API's ~30s limit for one command, so nothing can hang.
run_install() {
  local sid="$1" step rc
  step="$(ID="$sid" exec_show "rm -rf /tmp/egress && timeout 25 git clone -q --depth 1 -b '$EGRESS_BRANCH' https://github.com/${target_repo}.git /tmp/egress 2>&1" || true)"
  rc="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$step" | sed -n 's/^exit_code=//p')"
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$step" | grep -v 'exit_code=' || true
    echo "[failed] git clone didn't finish: $( [ "$rc" = 124 ] && echo "timed out after 25s" || echo "exit code ${rc:-none}")"
    return
  fi
  step="$(ID="$sid" exec_show "cd /tmp/egress && timeout 20 npm install --no-audit --no-fund 2>&1" || true)"
  rc="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$step" | sed -n 's/^exit_code=//p')"
  printf '%s\n' "$step" | grep -v 'exit_code=' || true
  [ "$rc" = 0 ] || echo "[failed] npm install didn't finish: $( [ "$rc" = 124 ] && echo "timed out after 20s" || echo "exit code ${rc:-none}")"
}

# verdict ROUND OUTPUT — say what the output shows, naming the failed step if any
verdict() {
  local round="$1" out="$2"
  if grep -q 'install event sent' <<<"$out"; then
    [ "$round" = 1 ] && echo "${R}The request got out while egress was limited. Check allowed_hosts before the workshop.${N}" \
                     || echo "${G}Got through:${N} same code, same command, but this sandbox's allowlist includes example.com."
  elif grep -q 'could not reach' <<<"$out"; then
    [ "$round" = 1 ] && echo "${G}Blocked:${N} the install step tried to call example.com, which isn't on the allowlist." \
                     || echo "${R}Still blocked, even with example.com on the allowlist. Tell your host.${N}"
  else
    echo "${R}Couldn't compare: $(grep -o '\[failed\].*' <<<"$out" | sed 's/^\[failed\] //' || echo "the sandbox didn't respond").${N}"
    return 1
  fi
}

do_egress() {
  require_sandbox
  EGRESS_BRANCH="${egress_branch:-chore/install-analytics}"
  local out

  say "== Round 1: npm install of '$EGRESS_BRANCH' in your sandbox (egress LIMITED)"
  out="$(run_install "$ID")"; grep -v '^\[failed\]' <<<"$out" || true; echo
  verdict 1 "$out" || return 1
  read -rp "Press Enter to create a second sandbox that also allows example.com, and run the same command… "

  # A short-lived second sandbox with the same limited policy plus example.com
  # on its allowlist. (Not "unrestricted": on api.beta.relax.ai that mode leaves
  # sandboxes with no network at all.) Your own sandbox is never changed. Node
  # and git are in the base image, so it needs no install step. It's deleted
  # however this function exits.
  BURNER="$(cpu=1 memory=1Gi ALLOWED="$ALLOWED,example.com" create_sandbox "${sandbox_name:-relaxai-workshop}-egress" limited)"
  trap 'api DELETE "/sandboxes/$BURNER" >/dev/null 2>&1 && echo "[egress] temporary sandbox deleted"' EXIT

  # A brand-new sandbox's network can take a few seconds to come up after it
  # reports "running". Wait (visibly) until it can reach GitHub.
  printf '[egress] waiting for the new sandbox'"'"'s network'
  for _ in $(seq 1 10); do
    ID="$BURNER" exec_quick 'curl -s -m 3 -o /dev/null https://github.com && echo up' | grep -q up && break
    printf '.'; sleep 2
  done
  echo

  say "== Round 2: same command, in a new sandbox whose allowlist includes example.com"
  out="$(run_install "$BURNER")"; grep -v '^\[failed\]' <<<"$out" || true; echo
  verdict 2 "$out" || true
  trap - EXIT
  api DELETE "/sandboxes/$BURNER" >/dev/null 2>&1 && echo "[egress] temporary sandbox deleted"
}

# -----------------------------------------------------------------------------
# limits — show the sandbox's network and memory boundaries
# -----------------------------------------------------------------------------
do_limits() {
  require_sandbox
  local which="${1:-all}"
  if [ "$which" = all ] || [ "$which" = network ]; then
    say "== Network: only allowlisted hosts are reachable"
    exec_show "$PROBE echo 'on the default allowlist:'; probe https://api.github.com; probe https://registry.npmjs.org; echo; echo 'not on the default allowlist:'; probe https://example.com; probe https://www.wikipedia.org; probe https://pypi.org"
    echo
  fi
  if [ "$which" = all ] || [ "$which" = memory ]; then
    say "== Memory: a process that keeps allocating is stopped at the sandbox's limit"
    # The subshell (with "exit $?" so it isn't optimised away) keeps the
    # shell's own "Killed" notice out of the output.
    exec_show 'echo "memory limit: $(cat /sys/fs/cgroup/memory.max 2>/dev/null | awk '"'"'$1=="max"{print "no limit"; next} {printf "%g GiB\n", $1/1073741824}'"'"')"; ( node -e "const a=[]; for(;;){ a.push(Buffer.alloc(256*1024*1024, 1)); console.log((a.length/4)+\" GiB\") }" > /tmp/mem.log 2>&1; exit $? ) 2>/dev/null; rc=$?; tail -2 /tmp/mem.log; echo "node exit: $rc (137 = stopped by the memory limit)"; echo "sandbox still running: $(hostname)"'
  fi
}

case "${1:-}" in
  up)       do_up ;;
  verify)   do_verify ;;
  review)   do_review "${2:-}" ;;
  egress)   do_egress ;;
  limits)   do_limits "${2:-}" ;;
  logs)     do_logs ;;
  status)   do_status ;;
  down)     do_down ;;
  *) sed -n '7,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
