# PR Review Demo — Step by Step

You'll run a relaxAI agent inside an isolated Relax sandbox. It lists the open
pull requests in a GitHub repo, reads each diff, posts a review comment, and
then you delete the whole machine with one command.

**Why this needs a sandbox:** the agent runs an LLM with shell access against
untrusted code. The sandbox has no public ports and its network egress is
restricted, so the code under review can't reach anything it shouldn't.

---

## Prerequisites

Two things to sign up for, plus a repo to review:

| You need | What it's for | Notes |
|---|---|---|
| **A Relax API key** | Authenticates the sandbox API **and** is the key the agent uses to call the model | One key does both. Looks like `rak_…` |
| **A GitHub personal access token (PAT)** | Lets the agent read PR diffs and post review comments | Needs **read and write on pull requests** for the repos you want reviewed. Classic token: the `repo` scope. Fine-grained token: *Contents: read* + *Pull requests: read and write* |
| **A target repo** | The repository whose open PRs get reviewed | `owner/repo`, e.g. `acme/website`. It should have at least one **open** pull request |

On your machine you also need `curl`, `jq`, and `git`.

---

## Step 1 — Configure

```bash
cp .env.example .env
```

Set these in `.env`:

| Key | What it is |
|---|---|
| `api_key` | Your Relax key (sandbox API + model). |
| `github_token` | Your GitHub PAT — needs pull-requests write on the target repo. |
| `target_repo` | The repo to review, `owner/repo`. |
| `dry_run` | `1` prints the review instead of posting. `0` posts it live. |

Leave the sandbox defaults as-is unless you need a different size or lifetime.

---

## Step 2 — Provision the sandbox (~1–2 min)

```bash
./deploy.sh
```

Creates the sandbox, installs what the agent needs inside it (Node, the GitHub
CLI, Claude Code), uploads the prompt (the instructions for the PR reviewer agent), and leaves the sandbox running. When it
finishes it prints a **Verify** block you can copy-paste.

---

## Step 3 — Verify it's alive

```bash
./deploy.sh verify
```

Expect: a Node version, a `gh` version, an agent version, the injected env
(`ANTHROPIC_BASE_URL`, `TARGET_REPO`, `DRY_RUN`, keys shown as `set`), and a
short reply from the model. If the model responds with "Hello!", the sandbox can
reach the Relax API and your key works. If it can't, the command says so —
it prints the HTTP status and the error, and exits non-zero.

---

## Step 4 — Run the review

```bash
./deploy.sh run
```

Concretely, `deploy.sh` sends **one command** into the sandbox:

```
claude --print -p "$(cat /workspace/prompt.txt)"
```

That runs a **Claude Code** session (connected to the relaxAI API) as a normal process *inside the sandbox*, with shell access and your
GitHub token in its environment. It's given the instructions from `prompt.txt` (at root of this repo) and nothing else, and works through them start-to-finish without asking for confirmation (`--print` means non-interactive):

1. `gh pr list` → the **open pull requests** in `target_repo`;
2. `gh pr diff <n>` → each PR's **diff**, which it reads and reasons about;
3. it writes a review per PR to `/workspace/review-PR-<number>.md` — summary,
   correctness/style notes, and a verdict;
4. it delivers that file: prints it when `dry_run=1`, or posts it as a comment
   on the PR (`gh pr comment --body-file`) when `dry_run=0` (Step 5)

The model calls go out to the relaxAI API over `$endpoint`. Everything else — the
`gh` commands, the file writes — happens inside the sandbox; your laptop only
starts the process and prints what it produced. 

The key: **Nothing runs on your laptop**

`deploy.sh` waits for that process to exit (5-minute cap, with a `waiting`
heartbeat), then prints the outcome once: the tally plus the review file(s).

---

## Step 5 — Go live

Edit `.env`:

```
dry_run=0
```
Which means the agent will go ahead and upload its report to the PR.

`dry_run`, the model, and `target_repo` are applied when the session runs, so
there's no need to re-deploy — just:

```bash
./deploy.sh run
```

Now open the pull request — there should be a new comment with the review and a
verdict.

---

## Step 6 — Inspect and iterate

```bash
./deploy.sh logs      # last agent output
./deploy.sh status    # sandbox status + last completion record
```

`prompt.txt` is uploaded at deploy time, so after editing it re-run
`./deploy.sh` (or upload it again) before `./deploy.sh run`.

---

## Step 7 — Tear down

```bash
./destroy.sh
```

---

## What just happened

- A relaxAI agent session ran against the relaxAI API, in a sandbox it doesn't
  host.
- It reviewed **untrusted code** inside a contained sandbox, egress limited to
  GitHub, package registries, and the model.
- The whole machine disappeared with **one command**.
- Nothing ran on your local machine

---

## Troubleshooting

- **`./deploy.sh` fails during install with a network/DNS error** — the
  `limited` allowlist is missing a host. Set `networking_type=unrestricted` in
  `.env` and re-run.
- **`verify` reports `FAILED (http 404) ... does not exist`** — the model id
  isn't available on that host. Check `model_id` in `.env` against the models
  listed by `GET https://$endpoint/v1/models`.
- **`./deploy.sh run` finishes but prints nothing** — check `./deploy.sh logs`
  and `completion.txt`; the model call usually fails first if the key is wrong.
- **GitHub returns 403 when commenting** — your PAT needs pull-requests write on
  that repo; you can't comment on repos you don't have access to.
- **Nothing is found to review** — `target_repo` must be `owner/repo` and the
  repo must have open PRs.
- **Deploy fails with "target_repo not set"** — fill in `.env` before deploying;
  the agent's env is injected when the sandbox is created.
