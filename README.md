# Workshop guide: an AI code reviewer in a relaxAI sandbox

In this workshop you'll create your own relaxAI sandbox (a disposable cloud
machine) and have an AI agent review three pull requests inside it. The agent
doesn't just read the code: it installs it, runs the tests and starts the
server, then tells you what it found, with the output to prove it.

**You need:** a laptop with a terminal, and the **relaxAI API key** your host
gives you. No accounts or installs beyond what's below. 

---

## Step 1: Open a terminal and check your tools (2 min)

- **Mac:** open **Terminal** (press ⌘ Space, type *Terminal*).
- **Linux:** open your usual terminal.
- **Windows:** open **Ubuntu (WSL)** if you have it. If you don't, pair up with
  a neighbour on Mac or Linux: setting up WSL needs a restart.

Run:

```bash
curl --version | head -1; git --version; jq --version
```

You should see three version lines. If one is missing:

| Missing | Mac | Linux / WSL |
|---|---|---|
| `git` | Run `git --version` again and click **Install** in the pop-up. | `sudo apt install -y git` |
| `jq` | `brew install jq` (or ask your host) | `sudo apt install -y jq` |

## Step 2: Get the workshop code (1 min)

```bash
git clone https://github.com/relax-ai/sandbox-code-reviewer.git
cd sandbox-code-reviewer
```

## Step 3: Add your API key (1 min)

```bash
cp .env.example .env
```

Open `.env` in any editor (for example `nano .env`, or `open -e .env` on a Mac)
and paste your key after `api_key=`, with no spaces:

```ini
api_key=rak_your_key_here
```

Save and close (in nano: **Ctrl+O**, **Enter**, **Ctrl+X**). Leave everything
else as it is.

> Keep the key to yourself: don't paste it in chat or commit it. `.env` is
> already excluded from git.

## Step 4: Create your sandbox (2 min)

```bash
./demo.sh up
```

This makes one API call to create a sandbox with limited internet access,
then installs the AI agent inside it. Wait for:

```
Sandbox ready: <id>  (egress: limited)
```

## Step 5: Check it works (1 min)

```bash
./demo.sh verify
```

Look for three things:

- **tools:** a Node, git and Claude Code version.
- **model:** `OK: Hello!` (or another greeting). The agent can reach the AI model.
- **egress policy:** `api.github.com` is **REACHED** and `example.com` is
  **BLOCKED**. Your sandbox can only talk to an allowlist of hosts.

## Step 6: Let the agent review the PRs (10 min)

The PRs are in a small stock-quote app:
<https://github.com/bennorris123/sandbox-workshop-ticker/pulls>. Open the link
and read PR #1 before you start: can you spot the problem just by reading?

**First, read the agent's instructions.** Everything the agent does comes from
one plain-text file, [prompt.txt](prompt.txt), in the folder you cloned. Open it
in any editor, or in the terminal:

```bash
cat prompt.txt
```

Notice that it tells the agent to *run* each PR, not just read it: install it,
run the tests, start the server and try unusual inputs, then back every claim
with real output.

**This does not run on your local machine, it runs in a throwaway relaxAI sandbox**

Now start the first review:

```bash
./demo.sh review 1
```

While the agent works you'll see one line (in cyan) for each command it runs,
then its report: a verdict, a one-line summary, up to three findings and the
evidence for them. Compare the commands with `prompt.txt`: can you match each
one to an instruction? Reviews are only printed on your screen, not posted to
GitHub.

> **Notice:** the agent chose every one of those commands itself and ran them
> as root, with no one approving them. Would you let it do that on your laptop,
> next to your SSH keys and cloud credentials? In the sandbox, the worst case
> is a machine you delete.

Now review the other two PRs:

```bash
./demo.sh review 2
./demo.sh review 3
```

Each review takes about a minute. To see everything the agent did, including
its reasoning and each command's output, run:

```bash
./demo.sh logs
```

<details>
<summary><b>What the agent should find</b> (open after your reviews finish)</summary>

| PR | Finding |
|---|---|
| **#1** Support fractional discount percentages | The description says "all tests pass". The agent runs `npm test` and one fails: rounding changed for half-cent values. |
| **#2** Add bulk quotes endpoint | Calling `/api/quotes` without `symbols` throws a `TypeError` and **takes the whole server down**. Easy to miss in the diff; obvious once you run it. |
| **#3** Track installs with a postinstall ping | `npm install` now secretly calls `example.com`. The agent sees the call fail and reports that the sandbox's egress policy blocked it. Step 7 proves it was the sandbox. |

**PR #1 and #2 show why the agent should *run* the code. PR #3 shows why that
running belongs in a sandbox:** the code itself tried to do something you didn't
expect, and the sandbox stopped it.

Models vary, so your agent may word things differently or find something extra.
If it misses one, run `./demo.sh logs`: what did it run, and what didn't it try?

</details>

## Step 7: Same code, two network policies (3 min)

Did the sandbox really block PR #3's request? Prove it:

```bash
./demo.sh egress
```

This runs `npm install` for PR #3 in two sandboxes:

1. In **your sandbox**, with egress **limited**:
   `analytics: could not reach example.com`.
2. Press **Enter**. The script creates a **second sandbox whose allowlist also
   includes `example.com`** (this takes under a minute) and runs exactly the
   same install: `analytics: install event sent (http 200)`.
3. The second sandbox is deleted automatically. Yours is never changed:
   `example.com` was only allowed in the temporary sandbox, so yours still
   blocks it.

Same code, same command, one extra host on the allowlist, different result:
the network policy is chosen by whoever creates the sandbox, not by the code
inside it.

## Step 8: See the sandbox's limits (2 min)

```bash
./demo.sh limits
```

- **Network:** allowlisted hosts (GitHub, npm) are reachable; others aren't.
  `example.com` is still blocked here: this is your sandbox, which Step 7
  didn't change.
- **Memory:** a process allocates memory until it reaches the sandbox's limit
  and is stopped (`exit 137`). The sandbox itself keeps running.

## Stretch task: make the sandbox do something new (10–20 min)

Done early? Change what runs in your sandbox. Pick any ideas below, in any
order, and compare results with your neighbour.

**How it works:** [prompt.txt](prompt.txt) is the agent's instructions, and
`./demo.sh review` uploads a fresh copy every time it runs, so edits take effect
immediately. Each idea below adds a few lines to the end of it. Nothing is ever
pushed to GitHub, so experiment freely. To undo all your edits:

```bash
git checkout prompt.txt
```

### Change the agent's job

Paste one of these into your terminal, then run the `review` command under it.

**1. Write the test that should have existed.** Can the agent catch the bug
with a failing test?

```bash
cat >> prompt.txt <<'EOF'
EXTRA TASK: for the PR you review, add a new test file in test/ that fails
because of the problem you found. Show the npm test output with your test failing.
EOF
./demo.sh review 1
```

**2. Fix it.** The agent edits its own copy of the code in the sandbox and
proves the fix works.

```bash
cat >> prompt.txt <<'EOF'
EXTRA TASK: after reviewing, fix the problem. Re-run the commands that showed
the problem and show they now pass, then show your fix with git diff.
EOF
./demo.sh review 2
```

**3. Try to break it.** How many ways can the agent find to upset the API?

```bash
cat >> prompt.txt <<'EOF'
EXTRA TASK: call every endpoint with at least 10 unusual inputs (empty, negative,
huge, wrong case, symbols, emoji). Show a table: request, HTTP status, and whether
the server was still running afterwards.
EOF
./demo.sh review 2
```

**4. Race the endpoints.** A quick load test, run entirely in the sandbox.

```bash
cat >> prompt.txt <<'EOF'
EXTRA TASK: start the server and time 500 requests to /api/prices, then 500 to
/api/quotes?symbols=ACME,GLOBEX (a bash loop with curl is fine). Report requests
per second for each.
EOF
./demo.sh review 2
```

**5. Meet the firewall.** Ask the agent to explore its own network limits.

```bash
cat >> prompt.txt <<'EOF'
EXTRA TASK: before reviewing, use curl to try https://api.github.com,
https://registry.npmjs.org and https://www.wikipedia.org. Explain which worked,
which didn't, and why you think that is.
EOF
./demo.sh review 3
```

**6. Your own idea.** Some starters: review the PR as a strict security auditor,
explain the change to a non-programmer, write the review as a haiku, or suggest
a better name for every function the PR touches. Write it in plain English after
`EXTRA TASK:`.

Each idea you paste adds to the prompt, so they stack up. Run
`git checkout prompt.txt` between ideas if you want the agent to focus on just one.

### Change the sandbox itself

These change settings in `.env`. A new setting needs a new sandbox, so
recreate it (about 2 minutes):

```bash
./demo.sh down && ./demo.sh up
```

**7. Open the firewall to one more site.** In `.env`, replace the
`allowed_hosts=` line with this (the default list, plus Wikipedia at the end):

```ini
allowed_hosts=api.beta.relax.ai,github.com,api.github.com,codeload.github.com,objects.githubusercontent.com,raw.githubusercontent.com,www.wikipedia.org
```

Recreate the sandbox, then run `./demo.sh limits network`: Wikipedia is now
**REACHED**. Then try idea 5 again and see whether the agent notices the change.

**8. Shrink the machine.** In `.env`, set `memory=1Gi`, recreate the sandbox and
run `./demo.sh limits memory`. Where does the process get stopped now? Does a
review still work on the smaller machine?

**9. Swap the model (no new sandbox needed).** List the models your key can use:

```bash
set -a; . ./.env; set +a
curl -s "https://$endpoint/v1/models" -H "Authorization: Bearer $api_key" | jq -r '.data[].id'
```

Set `model_id=` in `.env` to a different one and run the same review again.
Which model found more? Which was faster?

**Tip:** `./demo.sh logs` replays your last session in full, which is handy for
comparing runs side by side with a neighbour.

## Step 9: Delete your sandbox (1 min)

```bash
./demo.sh down
```

The whole machine, and everything the agent installed and ran, is gone.
**Please don't skip this:** sandboxes keep running (and costing) until deleted.
