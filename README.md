# relaxAI Sandbox — PR Review Agent

Runs a single relaxAI agent session against the Relax API inside an ephemeral
**Relax sandbox**. The agent lists the open pull requests in a GitHub repo,
reviews each diff, and posts its findings back as a PR comment. One sandbox,
one task, then you delete it.

This replaces the earlier Civo VM + Terraform version. There is no Terraform,
no SSH, and no VM bootstrap: the Relax `/sandboxes` API provisions the machine
and the sandbox itself handles isolation and network egress.

## How it works

1. `deploy.sh` creates a sandbox via `POST /v1/sandboxes` (beta), injecting the
   agent env (`ANTHROPIC_*`, `GH_TOKEN`, `TARGET_REPO`, `DRY_RUN`).
2. It uploads `bootstrap.sh` + `prompt.txt` and installs the agent toolchain.
3. `./deploy.sh run` executes the agent session in the sandbox; output goes to
   `/workspace/claude-output.log` and `/workspace/completion.txt`.
4. `./deploy.sh logs|status|verify` inspect it; `./destroy.sh` deletes it.

## Prerequisites

- `curl`, `jq`, `git`
- A Relax API key (`rak_...`)
- A GitHub PAT with pull-requests read+write on the target repo

## Quick start

```bash
cp .env.example .env      # fill in api_key, github_token, target_repo
./deploy.sh               # create sandbox + install toolchain
./deploy.sh verify        # check toolchain, env, and model access
./deploy.sh run           # run the review session
./destroy.sh              # delete the sandbox
```

See [`demo-guide.md`](demo-guide.md) for the full step-by-step walkthrough.

## Commands

| Command | What it does |
|---|---|
| `./deploy.sh` | Create the sandbox and install the toolchain (leaves it running). |
| `./deploy.sh run` | Run the PR-review session and print the output. |
| `./deploy.sh logs` | Print the last agent output. |
| `./deploy.sh status` | Sandbox status + last completion record. |
| `./deploy.sh verify` | Toolchain, injected env, and model reachability. |
| `./destroy.sh [id]` | Delete the sandbox (from `.sandbox-id`, or an explicit id). |

## Config

All configuration lives in `.env` (see `.env.example`). The important knobs:

- **`endpoint`** — sandboxes/model host, defaults to `api.beta.relax.ai`.
- **`model_id`** — the model the agent uses (defaults to `DeepSeek-V4-Pro`).
- **`target_repo`** / **`github_token`** / **`dry_run`** — the review target.
- **`networking_type`** / **`allowed_hosts`** — egress policy. `limited` is the
  containment story.
- **`sandbox_timeout`** — sandbox lifetime.

The env is injected when the sandbox is created, so changing `.env` requires
`./destroy.sh && ./deploy.sh`.

The prompt lives in `prompt.txt` and is uploaded at deploy time.

## Layout

```
bootstrap.sh   installs the agent toolchain inside the sandbox
deploy.sh      create / run / logs / status / verify
destroy.sh     delete the sandbox
prompt.txt     the review instructions given to the agent
demo-guide.md  step-by-step demo walkthrough
```

## Notes

- `bootstrap.sh` intentionally does **not** create users, set up iptables, or
  shred cloud-init secrets — those were Civo-specific and are now the sandbox's
  responsibility.
- `.env` and `.sandbox-id` are gitignored — never commit them.
