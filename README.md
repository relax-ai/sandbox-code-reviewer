# Workshop guide: an AI code reviewer in a relaxAI sandbox

In this workshop you'll create your own relaxAI sandbox (a disposable cloud
machine) and have an AI agent review three pull requests inside it. The agent
doesn't just read the code: it installs it, runs the tests and starts the
server, then tells you what it found, with the output to prove it.

**You need:** a laptop with a terminal, and the **relaxAI API key** your host
gives you. No accounts or installs beyond what's below. 

Head to `https://tinyurl.com/nav-key-26` for your relaxAI Beta API key for this workshop.

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

These are the only tools you need on your laptop: everything else (the code
under review, its dependencies, the AI agent) will run in the sandbox.

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

This is all you download: a short script, `demo.sh`, which drives the relaxAI
sandbox API with plain `curl` calls, and [prompt.txt](prompt.txt), the agent's
instructions. The app being reviewed isn't here: the agent fetches it inside
the sandbox.

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

This one key does two jobs: it lets `demo.sh` create and control your sandbox
through the relaxAI API, and it's passed into the sandbox so the agent can use
an AI model served by relaxAI.


## Step 4: Create your sandbox (2 min)

```bash
./demo.sh up
```

This makes one API call (`POST /v1/sandboxes`) to create your own sandbox:

- **A small cloud machine:** Ubuntu 22.04 with Node 22, git and curl, 2 CPUs,
  4 GiB of memory and 5 GiB of disk. It gets its own name, like
  `relaxai-workshop-3fa9c2`, and deletes itself after 4 hours if you forget.
- **Limited internet access:** it can only reach an allowlist of hosts: the
  relaxAI API (for the AI model), GitHub (to fetch the PRs) and package
  registries such as npm. Everything else is blocked.
- **The AI agent:** the script then uploads [prompt.txt](prompt.txt) and
  installs Claude Code inside the sandbox, set up to use a model served by
  relaxAI with your key.

Nothing is installed on your laptop. Wait for:

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
- **network policy:** the hosts your sandbox is **allowed** to reach (the
  relaxAI API, GitHub and package registries), and that **every other host is
  denied**. The green check underneath confirms it: an allowed host was
  reached and a denied one was blocked.

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
| **#2** Add CSV price export | The PR says it "only serves files from `data/`". The agent asks for `?file=../../../../etc/os-release` and gets a system file back: the endpoint can read **any file on the machine**. On your laptop, that could be your SSH keys or cloud credentials; in the sandbox there's nothing of yours to find. |
| **#3** Track installs with a postinstall ping | `npm install` now secretly calls `example.com`. The agent sees the call fail and reports that the sandbox's egress policy blocked it. Step 7 proves it was the sandbox. |

**Each PR shows a different reason to use a sandbox:**

- **#1:** the agent ran commands it chose itself, as root, and none of them
  touched your machine.
- **#2:** the code could read files it shouldn't, and in the sandbox there's
  nothing of yours to find.
- **#3:** the code tried to send data out, and the network policy blocked it.

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

This shows the sandbox's resource and memory limits. Code that goes out of control is
stopped at the sandbox's memory limit, instead of slowing down or freezing your laptop.

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
/api/export?file=prices.csv (a bash loop with curl is fine). Report requests
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
