# PR Review Demo — Step by Step

You'll run a relaxAI agent inside an isolated Relax sandbox. It lists the open
pull requests in a GitHub repo, reads each diff, posts a review comment, and
then you delete the whole machine with one command.

**Why this needs a sandbox:** the agent runs an LLM with shell access against
untrusted code. The sandbox has no public ports and its network egress is
restricted, so the code under review can't reach anything it shouldn't.

---

## What you need

- This directory
- `curl`, `jq`, `git` installed
- A Relax API key (sandbox API + model)
- A GitHub token (PAT) with access to the repo you'll review

---

## Step 1 — Configure

```bash
cp .env.example .env
```

Set these in `.env`:

| Key | What it is |
|---|---|
| `api_key` | Your Relax key. Used for the sandbox API **and** the model. |
| `github_token` | GitHub PAT. Needs **pull-requests write** on the repo to comment. |
| `target_repo` | The repo to review, `owner/repo`. |
| `dry_run` | `1` prints the review instead of posting. Flip to `0` to post live. |

Leave the sandbox defaults as-is unless you need a different size or lifetime.

---

## Step 2 — Provision the sandbox (~1–2 min)

```bash
./deploy.sh
```

Creates the sandbox, installs the agent toolchain, uploads the prompt, and
leaves the sandbox running. When it finishes it prints a **Verify** block you
can copy-paste.

---

## Step 3 — Verify it's alive

```bash
./deploy.sh verify
```

Expect: a Node version, a `gh` version, an agent version, the injected env
(`ANTHROPIC_BASE_URL`, `TARGET_REPO`, `DRY_RUN`, keys shown as `set`), and a
short reply from the model. If the model line returns text, the sandbox can
reach the Relax API and the key works.

---

## Step 4 — Run the review

```bash
./deploy.sh run
```

This starts the agent session, waits for it to finish (5-minute cap), then
prints `completion.txt`, the agent's output, and the last review body it wrote
to `review.md`. In dry-run mode you'll see the tally plus the review it would
have posted.

---

## Step 5 — Go live

Edit `.env`:

```
dry_run=0
```

Then destroy and re-deploy (env is injected at sandbox creation):

```bash
./destroy.sh
./deploy.sh
./deploy.sh run
```

Now open a pull request — there should be a new comment with the review and a
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

- A relaxAI agent session ran against the Relax API, in a sandbox it doesn't
  host.
- It reviewed **untrusted code** inside a contained sandbox, egress limited to
  GitHub, package registries, and the model.
- The whole machine disappeared with **one command**.

---

## Troubleshooting

- **`./deploy.sh` fails during install with a network/DNS error** — the
  `limited` allowlist is missing a host. Set `networking_type=unrestricted` in
  `.env` and re-run.
- **`./deploy.sh run` finishes but prints nothing** — check `./deploy.sh logs`
  and `completion.txt`; the model call usually fails first if the key is wrong.
- **GitHub returns 403 when commenting** — your PAT needs pull-requests write on
  that repo; you can't comment on repos you don't have access to.
- **Nothing is found to review** — `target_repo` must be `owner/repo` and the
  repo must have open PRs.
- **Deploy fails with "target_repo not set"** — fill in `.env` before deploying;
  the agent's env is injected when the sandbox is created.
